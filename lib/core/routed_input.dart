import 'dart:async';
import 'package:lan_input/lan_input.dart';
import 'package:flutter/services.dart';
import 'input_event_queue.dart';

typedef _RouteContext = ({int generation, int focus, int suspension});

/// Multiple encrypted sessions share one OS input hook. Only the focused
/// session may manipulate input or observe ordinary native events.
class InputRouter {
  InputRouter(this.native);
  final LanInput native;
  final Map<String, RoutedInput> channels = {};
  final Set<String> _capturing = {};
  String? _focused;
  int _focusVersion = 0, _generation = 0, _suspensionVersion = 0;
  String? get focused => _focused;
  set focused(String? value) {
    if (_focused != value) {
      _focused = value;
      _focusVersion++;
    }
  }

  bool _suspended = false;
  bool get suspended => _suspended;
  set suspended(bool value) {
    if (_suspended != value) {
      _suspended = value;
      _suspensionVersion++;
    }
  }

  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void> Function(Map<String, dynamic>)? beforeEvent;
  late final _queue = InputEventQueue<_RouteContext>(
      consume: _deliver,
      onError: (error, stack, context) {
        if (context.generation == _generation) _lost();
      });
  void _lost() {
    _generation++;
    _queue.clear();
    for (final channel in channels.values) {
      channel.emit({'type': 'captureLost'});
    }
  }

  Future<void> _deliver(
      Map<String, dynamic> event, _RouteContext context) async {
    if (suspended ||
        context.generation != _generation ||
        context.focus != _focusVersion ||
        context.suspension != _suspensionVersion) {
      return;
    }
    await beforeEvent?.call(event);
    if (!suspended &&
        context.generation == _generation &&
        ((context.focus == _focusVersion &&
                context.suspension == _suspensionVersion) ||
            (event['type'] == 'move' && context.focus != _focusVersion))) {
      channels[focused]?.emit(event);
    }
  }

  RoutedInput channel(String id) =>
      channels.putIfAbsent(id, () => RoutedInput(this, id));
  Future<void> start(String id) async {
    if (!_capturing.add(id) || _capturing.length > 1) return;
    _generation++;
    _subscription = native.events.listen((event) {
      if (event['type'] == 'emergency' || event['type'] == 'captureLost') {
        _generation++;
        for (final channel in channels.values) {
          channel.emit(event);
        }
        return;
      }
      if (suspended) return;
      _queue.add(event, (
        generation: _generation,
        focus: _focusVersion,
        suspension: _suspensionVersion
      ));
    }, onError: (Object _) {
      _lost();
    });
    try {
      await native.startCapture();
    } catch (_) {
      _capturing.remove(id);
      await _subscription?.cancel();
      _subscription = null;
      try {
        await native.stopCapture();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> stop(String id) async {
    if (!_capturing.remove(id)) return;
    if (_capturing.isEmpty) {
      _generation++;
      final subscription = _subscription;
      _subscription = null;
      try {
        await native.stopCapture();
      } finally {
        await subscription?.cancel();
      }
    }
  }

  Future<void> removeChannel(String id) async {
    if (_capturing.contains(id)) throw StateError('输入会话仍在捕获');
    final channel = channels.remove(id);
    if (focused == id) focused = null;
    await channel?._events.close();
  }

  Future<void> close() async {
    _generation++;
    await _subscription?.cancel();
    _subscription = null;
    _queue.clear();
    await _queue.idle;
    for (final channel in channels.values) {
      await channel._events.close();
    }
    channels.clear();
    _capturing.clear();
  }
}

class RoutedInput extends LanInput {
  RoutedInput(this.router, this.id);
  final InputRouter router;
  final String id;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  bool get active => router.focused == id;
  void emit(Map<String, dynamic> event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<InputStatus> getStatus() => router.native.getStatus();
  @override
  Future<void> requestPermissions() => router.native.requestPermissions();
  @override
  Future<void> startCapture() => router.start(id);
  @override
  Future<void> stopCapture() => router.stop(id);
  @override
  Future<void> setRemoteCapture(bool enabled) async {
    if (!active) {
      if (enabled) {
        throw PlatformException(code: 'input_busy', message: '客户端未获焦点');
      }
      return;
    }
    await router.native.setRemoteCapture(enabled);
  }

  @override
  Future<void> setCursorVisible(bool visible) async {
    if (active) await router.native.setCursorVisible(visible);
  }

  @override
  Future<void> heartbeat() async {
    await router.native.heartbeat();
  }

  @override
  Future<void> inject(Map<String, dynamic> event) async {
    if (active) await router.native.inject(event);
  }

  @override
  Future<void> warp(double x, double y) async {
    if (active) await router.native.warp(x, y);
  }

  @override
  Future<void> releaseAll() async {
    if (active) await router.native.releaseAll();
  }

  @override
  Future<int> clipboardRevision() => router.native.clipboardRevision();
  @override
  Future<bool> clipboardHasFiles() => router.native.clipboardHasFiles();
  @override
  Future<void> configureFileEdge(bool enabled, bool left) async {
    if (active) await router.native.configureFileEdge(enabled, left);
  }

  @override
  Future<void> configureFileEdgeLayout(
      bool enabled, String edge, double start, double end) async {
    if (active) {
      await router.native.configureFileEdgeLayout(enabled, edge, start, end);
    }
  }

  @override
  Future<void> prepareFileDrag() async {
    if (!active) throw StateError('客户端未获焦点');
    await router.native.prepareFileDrag();
  }

  @override
  Future<void> cancelLocalDrag() async {
    if (active) await router.native.cancelLocalDrag();
  }

  @override
  Future<void> beginFileDrag(List<String> paths) async {
    if (!active) throw StateError('请先选择此客户端');
    await router.native.beginFileDrag(paths);
  }

  @override
  Future<void> cancelFileDrag() async {
    if (active) await router.native.cancelFileDrag();
  }
}
