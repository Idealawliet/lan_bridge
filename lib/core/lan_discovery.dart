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
      required this.seen});
  final String id, name, platform, host;
  final int port;
  final bool busy;
  final DateTime seen;
}

/// Discovery is untrusted metadata only. It never carries credentials.
class LanDiscovery extends ChangeNotifier {
  static const discoveryPort = 24873;
  static final group = InternetAddress('239.255.248.72');
  final String id = generatePairingKey();
  final Map<String, LanDevice> devices = {};
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
    if (data != null) _send({'op': 'client', 'id': id, ...data}, address, port);
  }

  void _pulse(int port) {
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
    }
    expire(DateTime.now());
  }

  void ingest(Map<String, dynamic> m, String host, DateTime now) {
    if (_closed || m['op'] != 'client' || m['id'] == id) return;
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
    devices[deviceId] = LanDevice(
        id: deviceId,
        name: name,
        platform: platform,
        host: host,
        port: port,
        busy: m['busy'] as bool,
        seen: now);
    notifyListeners();
  }

  void expire(DateTime now) {
    final before = devices.length;
    devices.removeWhere((_, device) =>
        now.difference(device.seen) > const Duration(seconds: 7));
    if (before != devices.length) notifyListeners();
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
  }
}
