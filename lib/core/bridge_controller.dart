import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:lan_input/lan_input.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../sharing/file_transfer.dart';
import '../sharing/clipboard_sync.dart';

import 'screen_layout.dart';
import 'desktop_settings.dart';
import 'secure_transport.dart';
import 'input_event_queue.dart';
export 'screen_layout.dart' show PeerSide, PeerSideGeometry;

enum BridgeRole { source, target }

enum ConnectionMode { client, server }

enum ConnectionPhase { idle, listening, connecting, connected }

class BridgeController extends ChangeNotifier {
  BridgeController(
      {LanInput? input,
      int port = defaultSecurePort,
      this.enableSharing = true,
      DesktopSettings? settings,
      LoginStartup? startup,
      ClipboardAccess? clipboardAccess})
      : _input = input ?? LanInput(),
        _clipboardAccess = clipboardAccess,
        _port = port,
        _settings = settings ?? DesktopSettings(),
        _preferencesAvailable =
            settings != null || Platform.isWindows || Platform.isMacOS,
        _startup = startup ?? LoginStartup();
  final LanInput _input;
  final ClipboardAccess? _clipboardAccess;
  final DesktopSettings _settings;
  final bool _preferencesAvailable;
  final LoginStartup _startup;
  Future<void> _settingsQueue = Future.value();
  ConnectionMode get connectionMode =>
      role == BridgeRole.source ? ConnectionMode.server : ConnectionMode.client;
  double screenOffset = 0;
  ScreenArrangement get arrangement => ScreenArrangement(side, screenOffset);
  bool loginStartup = false, startupBusy = false;
  String? settingsError;
  bool _preferencesLoaded = false;
  void _saveSettings() {
    if (!_preferencesLoaded) return;
    final data = <String, dynamic>{
      'role': role.name,
      'connectionMode': connectionMode.name,
      'side': side.name,
      'offset': screenOffset
    };
    _settingsQueue =
        _settingsQueue.then((_) => _settings.save(data)).catchError((Object e) {
      settingsError = '设置保存失败：$e';
      _notify();
    });
  }

  void setConnectionMode(ConnectionMode value) {
    if (phase != ConnectionPhase.idle) return;
    role =
        value == ConnectionMode.server ? BridgeRole.source : BridgeRole.target;
    _saveSettings();
    _notify();
  }

  void setArrangement(PeerSide value, double offset) {
    if (phase != ConnectionPhase.idle || !offset.isFinite) return;
    side = value;
    screenOffset = offset.clamp(-0.9, 0.9);
    _saveSettings();
    _notify();
  }

  Future<void> setLoginStartup(bool value) async {
    if (startupBusy) return;
    startupBusy = true;
    settingsError = null;
    _notify();
    try {
      await _startup.setEnabled(value);
      loginStartup = await _startup.enabled();
    } catch (e) {
      settingsError = '自启设置失败：$e';
    } finally {
      startupBusy = false;
      _notify();
    }
  }

  final bool enableSharing;
  FileTransfer? files;
  ClipboardSync? clipboard;
  bool _dragWaiting = false, _receivingNativeDrag = false;
  final Set<int> _heldButtons = {};
  String? dragStatus;
  Timer? _dragTimeout;
  int _port;
  BridgeRole role = BridgeRole.source;
  PeerSide side = PeerSide.right;
  ConnectionPhase phase = ConnectionPhase.idle;
  bool remoteActive = false;
  bool supported = false;
  bool permissionsGranted = false;
  String pairingKey = '';
  String? error;
  String? peerAddress;
  List<String> localAddresses = [];
  String get platformName => Platform.isWindows
      ? 'Windows'
      : Platform.isMacOS
          ? 'macOS'
          : Platform.operatingSystem;
  String get statusText => switch (phase) {
        ConnectionPhase.idle => '未连接',
        ConnectionPhase.listening => '等待服务端连接',
        ConnectionPhase.connecting => '正在建立安全连接',
        ConnectionPhase.connected => remoteActive ? '正在控制被控电脑' : '已连接 · 键鼠在主机',
      };
  bool get busy => phase == ConnectionPhase.connecting;
  bool get connected => phase == ConnectionPhase.connected;
  bool get listening => phase == ConnectionPhase.listening;
  int get port => _port;
  ScreenRect? _local, _remote;
  SecureListener? _listener;
  SecurePeer? _peer;
  StreamSubscription<SecurePeer>? _accept;
  StreamSubscription<Map<String, dynamic>>? _incoming, _capture;
  Timer? _timer;
  DateTime _lastMessage = DateTime.now();
  DateTime _crossAfter = DateTime.fromMillisecondsSinceEpoch(0);
  double _remoteX = 0, _remoteY = 0;
  Completer<void>? _leaveAck;
  int _leaveSequence = 0;
  int _epoch = 0;
  int _pendingWire = 0;
  bool _disposed = false, _tickRunning = false;
  Future<void>? _disconnectTask;
  Future<void> _wireQueue = Future.value(), _clipboardQueue = Future.value();
  int _pendingClipboard = 0;
  int _inputRevision = 0;
  bool _inputEnabled = true;
  late final _nativeQueue = InputEventQueue<({int epoch, int revision})>(
      consume: (event, context) async {
        if (context.epoch == _epoch &&
            context.revision == _inputRevision &&
            _inputEnabled &&
            connected) {
          await _onNative(event, context.epoch);
        }
      },
      onError: (error, stack, context) =>
          _fail('输入服务已停止：$error', context.epoch),
      limit: 1024);
  Future<void> suspendInput() async {
    _inputEnabled = false;
    _inputRevision++;
    _nativeQueue.clear();
    await _nativeQueue.idle;
  }

  void resumeInput() {
    _inputRevision++;
    _inputEnabled = true;
    _crossAfter = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_preferencesAvailable) {
      try {
        final data = await _settings.load();
        role = BridgeRole.values
            .firstWhere((v) => v.name == data['role'], orElse: () => role);
        side = PeerSide.values
            .firstWhere((v) => v.name == data['side'], orElse: () => side);
        final offset = data['offset'];
        if (offset is num && offset.isFinite) {
          screenOffset = offset.toDouble().clamp(-0.9, 0.9);
        }
        loginStartup = await _startup.enabled();
      } catch (e) {
        settingsError = '无法读取桌面设置：$e';
      }
      _preferencesLoaded = true;
    }
    try {
      await _refreshStatus();
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      localAddresses =
          interfaces.expand((i) => i.addresses).map((a) => a.address).toList();
    } catch (e) {
      error = '初始化失败：$e';
    }
    _notify();
  }

  Future<void> _refreshStatus() async {
    final status = await _input.getStatus();
    supported = status.supported;
    permissionsGranted = status.permissionsGranted;
    if (supported) _local = ScreenRect.fromMap(status.screen);
  }

  Future<void> requestPermissions() async {
    try {
      await _input.requestPermissions();
      await _refreshStatus();
      error = null;
    } catch (e) {
      error = '请在系统设置中授予权限后重新打开应用：$e';
    }
    _notify();
  }

  Future<void> setRole(BridgeRole value) async {
    if (phase != ConnectionPhase.idle) return;
    role = value;
    _saveSettings();
    error = null;
    _notify();
  }

  void setSide(PeerSide value) => setArrangement(value, screenOffset);

  bool get sharingBusy =>
      _dragWaiting ||
      _receivingNativeDrag ||
      (files?.sending ?? false) ||
      (files?.receiving ?? false);
  bool matchesLocalEdge(Map<String, dynamic> event) {
    if (!connected ||
        remoteActive ||
        event['type'] != 'move' ||
        _local == null) {
      return false;
    }
    final x = event['x'], y = event['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return false;
    final rect = _local!;
    if (x < rect.x ||
        y < rect.y ||
        x >= rect.x + rect.width ||
        y >= rect.y + rect.height) {
      return false;
    }
    return arrangement.edge(rect, x.toDouble(), y.toDouble()) &&
        arrangement
            .overlaps(arrangement.tangent(rect, x.toDouble(), y.toDouble()));
  }

  Future<void> returnToLocal() async {
    if (sharingBusy) throw StateError('请先完成或取消文件传输');
    if (remoteActive && connected) await _returnLocal(_epoch);
    _heldButtons.clear();
  }

  Future<void> refreshFileEdge() async {
    if (connected && enableSharing) await _configureEdge();
  }

  Future<void> updateArrangement(PeerSide value, double offset) async {
    if (!connected) {
      setArrangement(value, offset);
      return;
    }
    if (role != BridgeRole.source || sharingBusy) {
      throw StateError('请先完成文件传输再调整布局');
    }
    if (!offset.isFinite || offset.abs() > .9) {
      throw const FormatException('无效屏幕偏移');
    }
    final resume = _inputEnabled;
    final epoch = _epoch;
    await suspendInput();
    try {
      await returnToLocal();
      if (epoch != _epoch || !connected) return;
      await _peer
          ?.send({'type': 'layout', 'side': value.name, 'offset': offset});
      side = value;
      screenOffset = offset;
      await refreshFileEdge();
      _saveSettings();
      _notify();
    } finally {
      if (resume && epoch == _epoch) resumeInput();
    }
  }

  Future<void> _checkReady() async {
    await _refreshStatus();
    if (!supported) throw StateError('请使用 Windows 或 macOS 客户端');
    if (!permissionsGranted) throw StateError('请先授予辅助功能和输入监控权限');
  }

  Future<void> listen({bool discoveredClient = false}) async {
    if (phase != ConnectionPhase.idle) {
      return;
    }
    error = null;
    phase = ConnectionPhase.connecting;
    _notify();
    final epoch = ++_epoch;
    try {
      await _checkReady();
      if (epoch != _epoch) return;
      pairingKey = generatePairingPin();
      final listener =
          await SecureListener.bind(pairingKey: pairingKey, port: port);
      if (epoch != _epoch) {
        await listener.close();
        return;
      }
      _listener = listener;
      _port = listener.port;
      phase = ConnectionPhase.listening;
      _accept = listener.peers.listen((peer) {
        if (epoch != _epoch || _peer != null) {
          unawaited(peer.close());
          return;
        }
        unawaited(_attach(peer, epoch));
      }, onError: (Object e) => _fail('监听失败：$e', epoch));
      _notify();
    } catch (e) {
      await _fail('无法开始等待连接：$e', epoch);
    }
  }

  Future<void> connect(String host, String key) async {
    if (phase != ConnectionPhase.idle) {
      return;
    }
    error = null;
    phase = ConnectionPhase.connecting;
    _notify();
    final epoch = ++_epoch;
    try {
      await _checkReady();
      if (epoch != _epoch) return;
      if (host.trim().isEmpty || host.trim() == '0.0.0.0') {
        throw const FormatException('请输入对端实际的局域网 IP 地址');
      }
      final peer = await connectSecurePeer(
          host: host.trim(), pairingKey: key.trim(), port: port);
      if (epoch != _epoch) {
        await peer.close();
        return;
      }
      await _attach(peer, epoch);
    } catch (e) {
      await _fail('连接失败：$e', epoch);
    }
  }

  Future<void> _attach(SecurePeer peer, int epoch) async {
    _peer = peer;
    peerAddress = peer.remoteAddress;
    phase = ConnectionPhase.connecting;
    _notify();
    final hello = Completer<void>();
    try {
      await _listener?.close();
      _listener = null;
      if (epoch != _epoch) return;
      _lastMessage = DateTime.now();
      _wireQueue = Future.value();
      _clipboardQueue = Future.value();
      _pendingClipboard = 0;
      _nativeQueue.clear();
      _inputRevision++;
      _pendingWire = 0;
      if (enableSharing) {
        Future<void> send(Map<String, dynamic> message) async {
          if (epoch != _epoch) throw StateError('连接已断开');
          await peer.send(message);
        }

        files = FileTransfer(
            send: send,
            receiveDirectory: () async {
              final directory = await getDownloadsDirectory();
              if (directory == null) throw StateError('无法找到下载目录');
              return Directory(p.join(directory.path, 'LAN Bridge'));
            },
            onDragReceived: (paths, y) async {
              if (epoch != _epoch) return;
              try {
                await _receiveDragFiles(paths, y);
              } catch (e) {
                error = '无法启动系统拖放：$e';
                if (epoch == _epoch) await _cancelDrag();
              }
            })
          ..addListener(_notify);
        clipboard = ClipboardSync(
            send: send,
            access: _clipboardAccess ??
                SystemClipboard(
                    _input.clipboardRevision, _input.clipboardHasFiles))
          ..addListener(_notify);
      }
      _incoming = peer.messages.listen((message) {
        if (epoch != _epoch) return;
        _lastMessage = DateTime.now();
        // OS clipboard reads/writes can block independently of keyboard input.
        // Preserve clipboard ordering without delaying key releases or leave.
        if (hello.isCompleted && message['type'] == 'clipboard') {
          if (++_pendingClipboard > 1024) {
            unawaited(_fail('剪贴板消息积压', epoch));
            return;
          }
          _clipboardQueue = _clipboardQueue
              .then<void>((_) async {
                if (epoch == _epoch) await _receive(message, epoch);
              })
              .catchError((Object e) => _fail('剪贴板协议错误：$e', epoch))
              .whenComplete(() {
                if (epoch == _epoch) _pendingClipboard--;
              });
          return;
        }
        if (++_pendingWire > 1024) {
          unawaited(_fail('输入积压，已安全断开连接', epoch));
          return;
        }
        _wireQueue = _wireQueue.then((_) async {
          if (epoch != _epoch) return;
          if (!hello.isCompleted) {
            if (message['type'] != 'hello' ||
                message['version'] != 6 ||
                message['role'] !=
                    (role == BridgeRole.source ? 'target' : 'source') ||
                message['screen'] is! Map) {
              throw const FormatException('两端角色或协议不匹配');
            }
            _remote = ScreenRect.fromMap(
                Map<String, dynamic>.from(message['screen'] as Map));
            if (role == BridgeRole.target) {
              final sideName = message['side'];
              if (!PeerSide.values.any((v) => v.name == sideName)) {
                throw const FormatException('无效的屏幕排列');
              }
              side = PeerSide.values.firstWhere((v) => v.name == sideName);
              final offset = message['offset'];
              if (offset is! num || !offset.isFinite || offset.abs() > 0.9) {
                throw const FormatException('无效屏幕偏移');
              }
              screenOffset = offset.toDouble();
            }
            hello.complete();
          } else {
            await _receive(message, epoch);
          }
        }).catchError((Object e) async {
          if (!hello.isCompleted) hello.completeError(e);
          await _fail('会话已停止：$e', epoch);
        }).whenComplete(() {
          if (epoch == _epoch) _pendingWire--;
        });
      }, onError: (Object e) {
        if (!hello.isCompleted) hello.completeError(e);
        unawaited(_fail(
            e is SocketException
                ? '与 ${peer.remoteAddress} 的连接被对端关闭，键鼠已恢复。请确认两端均使用新版客户端并重新配对。'
                : '连接已中断：$e',
            epoch));
      }, onDone: () {
        if (!hello.isCompleted) hello.completeError(StateError('对方关闭了连接'));
        unawaited(_fail('对方已断开连接，键鼠已恢复本机', epoch));
      });
      // Install the timeout handler before any async setup can fail the hello.
      final handshake = hello.future.timeout(const Duration(seconds: 5));
      // Observe early errors until the explicit await below attaches.
      unawaited(handshake.then<void>((_) {}, onError: (Object _) {}));
      _capture = _input.events.listen((event) {
        if (epoch != _epoch) return;
        if (event['type'] == 'emergency' || event['type'] == 'captureLost') {
          unawaited(_fail('已紧急断开，键鼠恢复本机', epoch));
          return;
        }
        if (role == BridgeRole.source && !_inputEnabled) return;
        if (connected &&
            enableSharing &&
            (event['type'] as String? ?? '').startsWith('fileDrag')) {
          unawaited(_nativeDragEvent(event, epoch).catchError((Object e) async {
            if (epoch != _epoch) return;
            error = '系统拖放失败：$e';
            await _cancelDrag();
            _notify();
          }));
          return;
        }
        if (!connected || role != BridgeRole.source) return;
        if (!_inputEnabled) return;
        _nativeQueue.add(event, (epoch: epoch, revision: _inputRevision));
      }, onError: (Object e) => _fail('输入捕获失败：$e', epoch));
      await _input.startCapture();
      if (epoch != _epoch) {
        await _input.stopCapture();
        return;
      }
      await _input.heartbeat();
      _timer = Timer.periodic(
          const Duration(milliseconds: 500), (_) => _tick(epoch));
      await peer.send({
        'type': 'hello',
        'version': 6,
        'role': role.name,
        'side': side.name,
        'offset': screenOffset,
        'screen': _local!.toMap()
      });
      await handshake;
      if (epoch != _epoch) return;
      phase = ConnectionPhase.connected;
      if (enableSharing) {
        await _configureEdge();
        unawaited(clipboard!.start());
      }
      pairingKey =
          ''; // The bearer secret is no longer displayed after pairing.
      _notify();
    } catch (e) {
      await _fail('建立会话失败：$e', epoch);
    }
  }

  Future<void> _tick(int epoch) async {
    if (_tickRunning || epoch != _epoch) return;
    _tickRunning = true;
    try {
      if (DateTime.now().difference(_lastMessage) >
          const Duration(seconds: 3)) {
        throw const SocketException('心跳超时');
      }
      await _input.heartbeat();
      if (connected) await _peer?.send({'type': 'heartbeat'});
    } catch (e) {
      await _fail('连接失去响应，已恢复本机：$e', epoch);
    } finally {
      _tickRunning = false;
    }
  }

  Future<void> _onNative(Map<String, dynamic> event, int epoch) async {
    final local = _local!, remote = _remote!;
    // Never interpret pre-capture absolute samples as remote relative motion,
    // or remote samples queued before a return as a new local crossing.
    if (event['type'] == 'move' &&
        event['captured'] is bool &&
        event['captured'] != remoteActive) {
      return;
    }
    if (event['type'] == 'button') {
      if (event['down'] == true) {
        _heldButtons.add(event['button'] as int);
      } else {
        _heldButtons.remove(event['button']);
      }
    }
    if (_dragWaiting) {
      if (event['type'] == 'button' &&
          event['button'] == 1 &&
          event['down'] == false) {
        await _cancelDrag();
      }
      return;
    }
    if (!remoteActive) {
      if (event['type'] != 'move' || DateTime.now().isBefore(_crossAfter)) {
        return;
      }
      final x = _number(event, 'x'), y = _number(event, 'y');
      if (x < local.x ||
          x >= local.x + local.width ||
          y < local.y ||
          y >= local.y + local.height) {
        return;
      }
      final fraction = arrangement.tangent(local, x, y);
      if (!arrangement.edge(local, x, y) || !arrangement.overlaps(fraction)) {
        return;
      }
      try {
        await _input.setRemoteCapture(true);
      } on PlatformException catch (e) {
        if (e.code == 'input_busy') return;
        rethrow;
      }
      if (epoch != _epoch) {
        await _input.setRemoteCapture(false);
        return;
      }
      final entry = arrangement.point(remote, fraction - screenOffset);
      _remoteX = entry.x;
      _remoteY = entry.y;
      remoteActive = true;
      await _peer?.send({'type': 'enter', 'x': _remoteX, 'y': _remoteY});
      _notify();
      return;
    }
    if (event['type'] == 'move') {
      final delta =
          local.mapDeltaTo(remote, _number(event, 'dx'), _number(event, 'dy'));
      final nextX = _remoteX + delta.dx;
      final nextY = _remoteY + delta.dy;
      final intersection = arrangement.returnIntersection(
          remote, _remoteX, _remoteY, delta.dx, delta.dy);
      final fraction =
          arrangement.tangent(remote, intersection.x, intersection.y);
      if (arrangement.edge(remote, nextX, nextY, reverse: true) &&
          arrangement.overlaps(fraction, reverse: true) &&
          !(enableSharing && _heldButtons.contains(1))) {
        _remoteX = intersection.x;
        _remoteY = intersection.y;
        await _returnLocal(epoch);
        return;
      }
      _remoteX = remote.clampX(nextX);
      _remoteY = remote.clampY(nextY);
      await _peer?.send({
        'type': 'input',
        'event': {'type': 'move', 'x': _remoteX, 'y': _remoteY}
      });
    } else if (['key', 'button', 'scroll'].contains(event['type'])) {
      await _peer?.send({'type': 'input', 'event': _validatedInput(event)});
    }
  }

  Future<void> _returnLocal(int epoch) async {
    await _input.setRemoteCapture(false);
    if (epoch != _epoch) return;
    remoteActive = false;
    _crossAfter = DateTime.now().add(const Duration(milliseconds: 350));
    final point = arrangement.point(_local!,
        arrangement.tangent(_remote!, _remoteX, _remoteY) + screenOffset,
        returning: true);
    await _input.warp(point.x, point.y);
    final acknowledgement = Completer<void>();
    _leaveAck = acknowledgement;
    final sequence = ++_leaveSequence;
    final released = acknowledgement.future.timeout(const Duration(seconds: 1));
    unawaited(released.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _peer?.send({'type': 'leave', 'id': sequence});
      await released;
    } finally {
      if (identical(_leaveAck, acknowledgement)) _leaveAck = null;
    }
    _notify();
  }

  Future<void> _receive(Map<String, dynamic> message, int epoch) async {
    if (message['type'] == 'left' && role == BridgeRole.source) {
      if (message['id'] == _leaveSequence &&
          _leaveAck != null &&
          !_leaveAck!.isCompleted) {
        _leaveAck!.complete();
      }
      return;
    }
    if (message['type'] == 'layout') {
      final name = message['side'], offset = message['offset'];
      if (role != BridgeRole.target ||
          remoteActive ||
          sharingBusy ||
          !PeerSide.values.any((v) => v.name == name) ||
          offset is! num ||
          !offset.isFinite ||
          offset.abs() > .9) {
        throw const FormatException('无效布局更新');
      }
      side = PeerSide.values.firstWhere((v) => v.name == name);
      screenOffset = offset.toDouble();
      await refreshFileEdge();
      _notify();
      return;
    }
    if (message['type'] == 'heartbeat') return;
    if (message['type'] == 'share' && files != null) {
      if (message['op'] == 'offer' && message['drag'] == true) {
        _dragWaiting = true;
        _watchDrag();
      }
      await files!.receive(message);
      return;
    }
    if (message['type'] == 'clipboard' && clipboard != null) {
      await clipboard!.receive(message);
      return;
    }
    if (message['type'] == 'drag_reverse' &&
        role == BridgeRole.source &&
        enableSharing) {
      if (!_heldButtons.contains(1)) {
        await _cancelDrag();
        return;
      }
      _dragWaiting = true;
      _watchDrag();
      dragStatus = '正在从另一端取回拖放文件，请保持按住鼠标';
      _notify();
      return;
    }
    if (message['type'] == 'drag_ready' && enableSharing) {
      _dragWaiting = false;
      _dragTimeout?.cancel();
      await _configureEdge();
      dragStatus = '文件已就绪，拖到目标目录后松开';
      _notify();
      return;
    }
    if (message['type'] == 'drag_cancel' && enableSharing) {
      await _cancelDrag(notifyPeer: false);
      return;
    }
    if (message['type'] == 'drag_finished' && enableSharing) {
      _dragWaiting = false;
      _dragTimeout?.cancel();
      await _configureEdge();
      return;
    }
    if (role != BridgeRole.target) throw const FormatException('收到不允许的控制消息');
    switch (message['type']) {
      case 'enter':
        if (remoteActive) throw const FormatException('重复的跨屏请求');
        await _input.inject({
          'type': 'move',
          'x': _local!.clampX(_number(message, 'x')),
          'y': _local!.clampY(_number(message, 'y'))
        });
        if (epoch != _epoch) return;
        remoteActive = true;
        _notify();
      case 'input':
        if (!remoteActive || message['event'] is! Map) {
          throw const FormatException('无效的输入状态');
        }
        final event =
            _validatedInput(Map<String, dynamic>.from(message['event'] as Map));
        if (event['type'] == 'move') {
          event['x'] = _local!.clampX(event['x'] as double);
          event['y'] = _local!.clampY(event['y'] as double);
        }
        await _input.inject(event);
      case 'leave':
        if (message['id'] is! int) throw const FormatException('无效返回确认编号');
        await _input.releaseAll();
        if (epoch != _epoch) return;
        remoteActive = false;
        await _peer?.send({'type': 'left', 'id': message['id']});
        _notify();
      default:
        throw const FormatException('未知控制消息');
    }
  }

  static double _number(Map<String, dynamic> map, String name) {
    final value = map[name];
    if (value is! num || !value.toDouble().isFinite || value.abs() > 1000000) {
      throw const FormatException('无效的输入数值');
    }
    return value.toDouble();
  }

  static Map<String, dynamic> _validatedInput(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'move' || type == 'scroll') {
      final a = type == 'move' ? 'x' : 'dx', b = type == 'move' ? 'y' : 'dy';
      return {'type': type, a: _number(event, a), b: _number(event, b)};
    }
    if (type == 'key' || type == 'button') {
      final field = type == 'key' ? 'usage' : 'button';
      final id = event[field];
      if (event['down'] is! bool ||
          id is! int ||
          id < 1 ||
          id > (type == 'key' ? 231 : 5)) {
        throw const FormatException('无效的按键');
      }
      return {'type': type, field: id, 'down': event['down']};
    }
    throw const FormatException('无效的输入类型');
  }

  Future<void> emergencyReturn() async {
    await disconnect();
    error = '已紧急断开，键鼠恢复本机';
    _notify();
  }

  Future<void> _configureEdge() {
    final edge = role == BridgeRole.source ? side : side.opposite;
    final offset = role == BridgeRole.source ? screenOffset : -screenOffset;
    return _input.configureFileEdgeLayout(
        true, edge.name, offset.clamp(0.0, 1.0), (1 + offset).clamp(0.0, 1.0));
  }

  void _watchDrag() {
    _dragTimeout?.cancel();
    _dragTimeout = Timer(const Duration(minutes: 10), () {
      unawaited(_cancelDrag());
    });
  }

  Future<void> _nativeDragEvent(Map<String, dynamic> event, int epoch) async {
    if ((event['type'] == 'fileDragReady' ||
            event['type'] == 'fileDragEnded') &&
        !_receivingNativeDrag) {
      return;
    }
    if (event['type'] == 'fileDragReady') {
      _dragWaiting = false;
      _dragTimeout?.cancel();
      await _peer?.send({'type': 'drag_ready'});
      dragStatus = '文件已就绪，拖到目标目录后松开';
      _notify();
      return;
    }
    if (event['type'] == 'fileDragEnded') {
      _receivingNativeDrag = false;
      _dragWaiting = false;
      await _input.releaseAll();
      await _configureEdge();
      await _peer?.send({'type': 'drag_finished'});
      dragStatus =
          event['cancelled'] == true ? '系统拖放已取消，已收到的副本保留在下载目录' : '系统拖放完成';
      _notify();
      return;
    }
    if (event['type'] != 'fileDrag' ||
        files == null ||
        files!.sending ||
        _dragWaiting ||
        _receivingNativeDrag) {
      return;
    }
    if (role == BridgeRole.source && remoteActive ||
        role == BridgeRole.target && !remoteActive) {
      return;
    }
    final paths = (event['paths'] as List).cast<String>();
    final transfer = files!;
    _dragWaiting = true;
    _watchDrag();
    dragStatus = '正在准备跨屏拖放，请保持按住鼠标';
    _notify();
    final fraction =
        arrangement.tangent(_local!, _number(event, 'x'), _number(event, 'y'));
    if (!arrangement.overlaps(fraction, reverse: role == BridgeRole.target)) {
      _dragWaiting = false;
      _dragTimeout?.cancel();
      await _configureEdge();
      return;
    }
    await _input.configureFileEdge(false, false);
    if (role == BridgeRole.source) {
      _heldButtons.add(1);
      await _input.prepareFileDrag();
      remoteActive = true;
      final entry = arrangement.point(_remote!, fraction - screenOffset);
      _remoteX = entry.x;
      _remoteY = entry.y;
    } else {
      await _peer?.send({'type': 'drag_reverse'});
      await _input.cancelLocalDrag();
      await _input.releaseAll();
      remoteActive = false;
    }
    try {
      if (epoch != _epoch) return;
      await transfer.sendPaths(paths,
          drag: true,
          y: fraction +
              (role == BridgeRole.source ? -screenOffset : screenOffset));
    } catch (_) {
      if (epoch == _epoch) await _cancelDrag();
    }
  }

  Future<void> _receiveDragFiles(List<String> paths, double fraction) async {
    if (!connected || !_dragWaiting) return;
    await _input.configureFileEdge(false, false);
    if (role == BridgeRole.source) {
      await _input.setRemoteCapture(false);
      remoteActive = false;
      _heldButtons.clear();
      final point = arrangement.point(_local!, fraction, returning: true);
      await _input.warp(point.x, point.y);
    } else {
      remoteActive = true;
      final point = arrangement.point(_local!, fraction);
      await _input.warp(point.x, point.y);
    }
    _receivingNativeDrag = true;
    await _input.beginFileDrag(paths);
    _notify();
  }

  Future<void> _cancelDrag({bool notifyPeer = true}) async {
    _dragTimeout?.cancel();
    _dragWaiting = false;
    _receivingNativeDrag = false;
    if (enableSharing) {
      await _input.cancelFileDrag();
      await _input.setRemoteCapture(false);
      await _input.releaseAll();
      remoteActive = false;
      _heldButtons.clear();
      await files?.cancel();
      if (connected) {
        await _configureEdge();
        if (notifyPeer) await _peer?.send({'type': 'drag_cancel'});
      }
    }
    dragStatus = '跨屏拖放已取消';
    _notify();
  }

  Future<void> _fail(String message, int epoch) async {
    if (epoch != _epoch || _disposed) return;
    await disconnect();
    error = message;
    _notify();
  }

  Future<void> disconnect() {
    if (_disconnectTask != null) return _disconnectTask!;
    final task = _doDisconnect();
    _disconnectTask = task;
    return task.whenComplete(() {
      _disconnectTask = null;
    });
  }

  Future<void> _doDisconnect() async {
    ++_epoch;
    _inputRevision++;
    _nativeQueue.clear();
    if (_leaveAck != null && !_leaveAck!.isCompleted) {
      _leaveAck!.completeError(StateError('连接已断开'));
    }
    _leaveAck = null;
    _timer?.cancel();
    _dragTimeout?.cancel();
    _dragWaiting = false;
    _receivingNativeDrag = false;
    _heldButtons.clear();
    final fileTransfer = files;
    files = null;
    final clipboardSync = clipboard;
    clipboard = null;
    fileTransfer?.removeListener(_notify);
    clipboardSync?.removeListener(_notify);
    clipboardSync?.close();
    _timer = null;
    final peer = _peer;
    _peer = null;
    final listener = _listener;
    _listener = null;
    final capture = _capture;
    _capture = null;
    final incoming = _incoming;
    _incoming = null;
    final accept = _accept;
    _accept = null;
    remoteActive = false;
    phase = ConnectionPhase.connecting;
    pairingKey = '';
    peerAddress = null;
    // Restore native input before waiting on any network teardown.
    if (supported) {
      try {
        await _input.setRemoteCapture(false);
      } catch (_) {}
      try {
        await _input.releaseAll();
      } catch (_) {}
      try {
        await _input.stopCapture();
      } catch (_) {}
    }
    await capture?.cancel();
    await incoming?.cancel();
    await accept?.cancel();
    await peer?.close();
    await listener?.close();
    await fileTransfer?.close();
    await clipboardSync?.settled;
    phase = ConnectionPhase.idle;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
