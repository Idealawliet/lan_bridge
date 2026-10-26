import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'secure_transport.dart';

class LanDevice {
  const LanDevice(
      {required this.id,
      required this.name,
      required this.platform,
      required this.host,
      required this.port,
      required this.busy,
      required this.seen,
      this.isServer = false});
  final String id, name, platform, host;
  final int port;
  final bool busy;
  final DateTime seen;
  final bool isServer;
}

class ConnectionRequest {
  ConnectionRequest(this.id, this.device, this.kind, this.created,
      {this.status = 'pending'});
  final String id, kind;
  final LanDevice device;
  final DateTime created;
  String status;
}

/// Discovery is untrusted metadata only. It never carries credentials.
class LanDiscovery extends ChangeNotifier {
  static const discoveryPort = 24873;
  static final group = InternetAddress('239.255.248.72');
  final String id = generatePairingKey();
  final Map<String, LanDevice> devices = {};
  final Map<String, ConnectionRequest> incomingRequests = {},
      outgoingRequests = {};
  int _discoveryPort = discoveryPort;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _timer;
  final List<NetworkInterface> _interfaces = [];
  Map<String, dynamic> Function()? advertisement;
  bool get running => _socket != null;
  bool _closed = false;
  DateTime _lastReply = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> start({int port = discoveryPort}) async {
    if (running) return;
    _closed = false;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
        reuseAddress: true, reusePort: true);
    _socket = socket;
    _discoveryPort = port;
    socket.multicastHops = 1;
    socket.writeEventsEnabled = false;
    try {
      for (final network
          in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        try {
          socket.joinMulticast(group, network);
          _interfaces.add(network);
        } catch (_) {}
      }
      if (_interfaces.isEmpty) socket.joinMulticast(group);
      _subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          final data = packet!;
          if (data.data.length > 1200) continue;
          try {
            final message = jsonDecode(utf8.decode(data.data));
            if (message is! Map ||
                message['app'] != 'lan-bridge' ||
                message['v'] != 1) {
              continue;
            }
            if (message['op'] == 'query') {
              final now = DateTime.now();
              if (now.difference(_lastReply) >=
                  const Duration(milliseconds: 250)) {
                _lastReply = now;
                _announce(data.address, data.port);
              }
            } else {
              ingest(Map<String, dynamic>.from(message), data.address.address,
                  DateTime.now());
            }
          } catch (_) {/* Ignore unrelated or malformed LAN datagrams. */}
        }
      }, onError: (Object _) {});
      _pulse(port);
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pulse(port));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _send(Map<String, dynamic> data, InternetAddress address, int port) {
    final bytes =
        utf8.encode(jsonEncode({'app': 'lan-bridge', 'v': 1, ...data}));
    if (bytes.length > 1200) return;
    try {
      _socket?.send(bytes, address, port);
    } catch (_) {}
  }

  void _announce(InternetAddress address, int port) {
    final data = advertisement?.call();
    if (data != null) _send({'op': 'client', ...data, 'id': id}, address, port);
  }

  void requestConnection(LanDevice device) {
    final data = advertisement?.call();
    if (!running || data == null || device.busy) {
      throw StateError('请先启动服务，并选择可用的设备');
    }
    final kind = data['op'] == 'server' ? 'control' : 'join';
    if ((kind == 'control') == device.isServer) {
      throw StateError('只能向另一角色的设备发送申请');
    }
    outgoingRequests.removeWhere((_, r) => r.device.id == device.id);
    if (outgoingRequests.length >= 32) throw StateError('待处理申请过多');
    final request =
        ConnectionRequest(generatePairingKey(), device, kind, DateTime.now());
    outgoingRequests[request.id] = request;
    _sendRequest(request, data);
    notifyListeners();
  }

  void _sendRequest(ConnectionRequest request, Map<String, dynamic> data) {
    _send({
      ...data,
      'op': 'request',
      'id': id,
      'target': request.device.id,
      'request': request.id,
      'kind': request.kind
    }, InternetAddress(request.device.host), _discoveryPort);
  }

  void respond(ConnectionRequest request, bool accepted) {
    if (incomingRequests[request.id] != request ||
        request.status != 'pending') {
      return;
    }
    request.status = accepted ? 'accepted' : 'rejected';
    _sendResponse(request);
    notifyListeners();
  }

  void _sendResponse(ConnectionRequest request) {
    _send({
      'op': 'response',
      'id': id,
      'target': request.device.id,
      'request': request.id,
      'status': request.status
    }, InternetAddress(request.device.host), _discoveryPort);
  }

  void dismissRequest(String requestId) {
    incomingRequests.remove(requestId);
    outgoingRequests.remove(requestId);
    notifyListeners();
  }

  void _pulse(int port) {
    expire(DateTime.now());
    for (final network
        in _interfaces.isEmpty ? <NetworkInterface?>[null] : _interfaces) {
      if (network != null) {
        try {
          _socket?.setRawOption(RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              network.addresses.first.rawAddress));
        } catch (_) {
          continue;
        }
      }
      _send({'op': 'query'}, group, port);
      _announce(group, port);
      final data = advertisement?.call();
      if (data != null) {
        for (final request in outgoingRequests.values) {
          if (request.status == 'pending') _sendRequest(request, data);
        }
      }
    }
  }

  void ingest(Map<String, dynamic> m, String host, DateTime now) {
    if (_closed || m['id'] == id) return;
    final op = m['op'];
    if (op == 'response') {
      final request = outgoingRequests[m['request']];
      if (m['target'] != id ||
          request == null ||
          request.status != 'pending' ||
          m['id'] != request.device.id ||
          host != request.device.host ||
          !['accepted', 'rejected'].contains(m['status'])) {
        return;
      }
      request.status = m['status'] as String;
      notifyListeners();
      return;
    }
    if (!['client', 'server', 'request'].contains(op)) return;
    if (op == 'request') {
      final requestId = m['request'];
      final server = advertisement?.call()['op'] == 'server';
      final previous = incomingRequests[requestId];
      if (m['target'] == id &&
          previous != null &&
          previous.device.id == m['id'] &&
          previous.device.host == host) {
        if (previous.status != 'pending') _sendResponse(previous);
        return;
      }
      if (m['target'] != id ||
          requestId is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(requestId) ||
          m['kind'] != (server ? 'join' : 'control') ||
          advertisement == null ||
          advertisement!()['busy'] == true ||
          incomingRequests.length >= 32 ||
          incomingRequests.containsKey(requestId)) {
        return;
      }
    }
    final deviceId = m['id'],
        name = m['name'],
        platform = m['platform'],
        port = m['port'];
    if (deviceId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(deviceId) ||
        name is! String ||
        name.isEmpty ||
        name.length > 80 ||
        platform is! String ||
        platform.length > 30 ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        m['busy'] is! bool ||
        InternetAddress.tryParse(host)?.type != InternetAddressType.IPv4) {
      return;
    }
    if (!devices.containsKey(deviceId) && devices.length >= 256) return;
    final device = LanDevice(
        id: deviceId,
        name: name,
        platform: platform,
        host: host,
        port: port,
        busy: m['busy'] as bool,
        seen: now,
        isServer:
            op == 'server' || (op == 'request' && m['kind'] == 'control'));
    if (op == 'request') {
      // Discovery requests never establish trust or carry a PIN. Pairing still
      // requires the existing authenticated transport after user approval.
      incomingRequests[m['request'] as String] = ConnectionRequest(
          m['request'] as String, device, m['kind'] as String, now);
    } else {
      devices[deviceId] = device;
    }
    notifyListeners();
  }

  void expire(DateTime now) {
    final before = devices.length;
    final requestsBefore = incomingRequests.length + outgoingRequests.length;
    devices.removeWhere((_, device) =>
        now.difference(device.seen) > const Duration(seconds: 7));
    incomingRequests.removeWhere(
        (_, r) => now.difference(r.created) > const Duration(minutes: 1));
    outgoingRequests.removeWhere(
        (_, r) => now.difference(r.created) > const Duration(minutes: 1));
    if (before != devices.length ||
        requestsBefore != incomingRequests.length + outgoingRequests.length) {
      notifyListeners();
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _interfaces.clear();
    devices.clear();
    incomingRequests.clear();
    outgoingRequests.clear();
  }
}
