import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/input_event_queue.dart';

void main() {
  test('edge dwell expiration remains ordered between mouse samples', () async {
    final gate = Completer<void>();
    final events = <Map<String, dynamic>>[];
    final queue = InputEventQueue<int>(
        consume: (event, _) async {
          if (events.isEmpty) await gate.future;
          events.add(event);
        },
        onError: (error, _, __) => fail('$error'));
    queue.add({'type': 'key', 'usage': 4, 'down': true}, 0);
    queue.add({'type': 'move', 'x': 1919, 'dx': 1, 'dy': 0}, 0);
    queue.add({'type': 'edgeDwell', '_dwellToken': 7, 'x': 1919}, 0);
    queue.add({'type': 'move', 'x': 1800, 'dx': -119, 'dy': 0}, 0);
    gate.complete();
    await queue.idle;
    expect(events.map((event) => event['type']),
        ['key', 'move', 'edgeDwell', 'move']);
    expect(events[2]['_dwellToken'], 7);
  });
  test('capture mode transition is a mouse coalescing barrier', () async {
    final gate = Completer<void>();
    final events = <Map<String, dynamic>>[];
    final queue = InputEventQueue<int>(
        consume: (e, c) async {
          await gate.future;
          events.add(e);
        },
        onError: (e, s, c) => fail('$e'));
    queue.add({'type': 'move', 'captured': false, 'dx': 1, 'dy': 0}, 0);
    queue.add({'type': 'move', 'captured': false, 'dx': 500, 'dy': 0}, 0);
    queue.add({'type': 'move', 'captured': true, 'dx': 3, 'dy': 0}, 0);
    gate.complete();
    await queue.idle;
    expect(events.length, 3);
    expect(events.last['dx'], 3);
  });

  test('5000Hz motion burst is merged without losing distance or key barriers',
      () async {
    final gate = Completer<void>();
    final events = <Map<String, dynamic>>[], errors = <Object>[];
    final queue = InputEventQueue<int>(consume: (e, context) async {
      if (events.isEmpty) await gate.future;
      events.add(e);
    }, onError: (e, s, context) {
      errors.add(e);
    });
    queue.add({'type': 'move', 'x': 0, 'y': 0, 'dx': 0, 'dy': 0}, 1);
    for (var i = 1; i <= 5000; i++) {
      queue.add({'type': 'move', 'x': i, 'y': i / 2, 'dx': 1, 'dy': .5}, 1);
    }
    queue.add({'type': 'key', 'usage': 4, 'down': true}, 1);
    for (var i = 1; i <= 100; i++) {
      queue.add(
          {'type': 'move', 'x': 5000 + i * 2, 'y': 2500, 'dx': 2, 'dy': 0}, 1);
    }
    queue.add({'type': 'key', 'usage': 4, 'down': false}, 1);
    gate.complete();
    await queue.idle;
    expect(errors, isEmpty);
    expect(
        events.map((e) => e['type']), ['move', 'move', 'key', 'move', 'key']);
    expect(events[1]['dx'], 5000);
    expect(events[1]['dy'], 2500);
    expect(events[1]['x'], 5000);
    expect(events[3]['dx'], 200);
    expect(events[2]['down'], isTrue);
    expect(events.last['down'], isFalse);
    expect(queue.peakDepth, lessThanOrEqualTo(4));
    expect(queue.merged, 5098);
  });
  test('context changes, buttons and scrolling prevent mouse samples merging',
      () async {
    final gate = Completer<void>();
    final events = <Map<String, dynamic>>[];
    final queue = InputEventQueue<int>(
        consume: (e, context) async {
          await gate.future;
          events.add({...e, 'context': context});
        },
        onError: (e, s, context) => fail('$e'));
    queue.add({'type': 'move', 'dx': 1, 'dy': 0}, 0);
    queue.add({'type': 'move', 'dx': 2, 'dy': 0}, 1);
    queue.add({'type': 'button', 'button': 1, 'down': true}, 1);
    queue.add({'type': 'move', 'dx': 3, 'dy': 0}, 1);
    queue.add({'type': 'scroll', 'dx': 0, 'dy': 1}, 1);
    queue.add({'type': 'move', 'dx': 4, 'dy': 0}, 2);
    queue.add({'type': 'button', 'button': 1, 'down': false}, 2);
    gate.complete();
    await queue.idle;
    expect(events.length, 7);
    expect(queue.merged, 0);
    expect(events.last['down'], isFalse);
  });
}
