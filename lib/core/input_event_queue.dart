import 'dart:async';
import 'dart:collection';

class _InputItem<T> {
  _InputItem(this.event, this.context);
  Map<String, dynamic> event;
  final T context;
}

/// Preserves keys/buttons/scroll as ordering barriers. Only adjacent mouse
/// samples from the same session are merged, retaining total relative motion
/// and the newest absolute position. Optional source pacing bounds packet rate;
/// the default consumer starts immediately.
class InputEventQueue<T> {
  InputEventQueue(
      {required this.consume,
      required this.onError,
      this.limit = 512,
      this.mergeMoves,
      this.motionInterval = Duration.zero});
  final Future<void> Function(Map<String, dynamic>, T) consume;
  final FutureOr<void> Function(Object, StackTrace, T) onError;
  final int limit;
  final Map<String, dynamic>? Function(
      Map<String, dynamic>, Map<String, dynamic>)? mergeMoves;
  final Duration motionInterval;
  final _clock = Stopwatch()..start();
  int _lastMove = -1000000;
  final _items = ListQueue<_InputItem<T>>();
  Completer<void>? _idle;
  int merged = 0, peakDepth = 0;
  Future<void> get idle => _idle?.future ?? Future<void>.value();
  void clear() => _items.clear();

  void add(Map<String, dynamic> event, T context) {
    if (_items.isNotEmpty &&
        _items.last.context == context &&
        mergeMoves != null) {
      final mergedEvent = mergeMoves!(_items.last.event, event);
      if (mergedEvent != null) {
        _items.last.event = mergedEvent;
        merged++;
        return;
      }
    }
    if (mergeMoves == null &&
        _items.isNotEmpty &&
        _items.last.context == context &&
        _items.last.event['type'] == 'move' &&
        _items.last.event['captured'] == event['captured'] &&
        event['type'] == 'move') {
      final previous = _items.last.event;
      final dx = event['dx'] ?? 0, dy = event['dy'] ?? 0;
      final oldDx = previous['dx'] ?? 0, oldDy = previous['dy'] ?? 0;
      if (dx is num &&
          dy is num &&
          oldDx is num &&
          oldDy is num &&
          dx.isFinite &&
          dy.isFinite &&
          oldDx.isFinite &&
          oldDy.isFinite &&
          // Reversals must retain their path: crossing a screen seam or
          // clamping at an edge depends on intermediate positions.
          !(dx > 0 && oldDx < 0 || dx < 0 && oldDx > 0) &&
          !(dy > 0 && oldDy < 0 || dy < 0 && oldDy > 0)) {
        _items.last.event = {...event, 'dx': oldDx + dx, 'dy': oldDy + dy};
        merged++;
        return;
      }
    }
    if (_items.length >= limit) {
      _items.clear();
      // A queued error is handled by the same consumer loop, so teardown
      // cannot race a second drain loop.
      _items.add(_InputItem({'type': '_overflow'}, context));
    } else {
      _items.add(_InputItem(Map<String, dynamic>.of(event), context));
    }
    if (_items.length > peakDepth) peakDepth = _items.length;
    if (_idle == null) {
      _idle = Completer<void>();
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    final completion = _idle!;
    try {
      while (_items.isNotEmpty) {
        if (_items.first.event['type'] == 'move' &&
            motionInterval > Duration.zero) {
          final remaining = motionInterval.inMicroseconds -
              (_clock.elapsedMicroseconds - _lastMove);
          if (remaining > 0) {
            await Future<void>.delayed(Duration(microseconds: remaining));
          }
          if (_items.isEmpty) continue;
        }
        final item = _items.removeFirst();
        try {
          if (item.event['type'] == 'move') {
            _lastMove = _clock.elapsedMicroseconds;
          }
          if (item.event['type'] == '_overflow') throw StateError('输入事件积压');
          await consume(item.event, item.context);
        } catch (error, stack) {
          _items.removeWhere((pending) => pending.context == item.context);
          await onError(error, stack, item.context);
        }
      }
    } finally {
      _idle = null;
      completion.complete();
    }
  }
}
