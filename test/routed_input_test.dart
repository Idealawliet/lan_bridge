import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_input/lan_input.dart';
import 'package:lan_bridge/core/routed_input.dart';

class Native extends LanInput {
  final bus = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => bus.stream;
  @override
  Future<void> startCapture() async {}
  @override
  Future<void> stopCapture() async {}
}

void main() {
  test(
      'mouse burst does not overflow the router or drop its final button release',
      () async {
    final native = Native(), gate = Completer<void>();
    final router = InputRouter(native);
    final channel = router.channel('a');
    final received = <Map<String, dynamic>>[];
    final sub = channel.events.listen(received.add);
    router.focused = 'a';
    router.beforeEvent = (_) => gate.future;
    await channel.startCapture();
    for (var i = 0; i < 6000; i++) {
      native.bus.add({'type': 'move', 'x': i, 'y': 100, 'dx': 1, 'dy': 0});
    }
    native.bus.add({'type': 'button', 'button': 1, 'down': false});
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(received.any((e) => e['type'] == 'captureLost'), isFalse);
    expect(received.last['type'], 'button');
    expect(received.last['down'], isFalse);
    expect(
        received
            .where((e) => e['type'] == 'move')
            .fold<num>(0, (sum, e) => sum + (e['dx'] as num)),
        6000);
    await sub.cancel();
    await channel.stopCapture();
    await router.close();
    await native.bus.close();
  });

  test('queued keys cannot cross a focus change', () async {
    final native = Native(), gate = Completer<void>();
    final router = InputRouter(native);
    final a = router.channel('a'), b = router.channel('b');
    final received = <Map<String, dynamic>>[];
    final sub = b.events.listen(received.add);
    router.focused = 'a';
    router.beforeEvent = (_) => gate.future;
    await a.startCapture();
    native.bus.add({'type': 'key', 'usage': 4, 'down': true});
    await Future<void>.delayed(Duration.zero);
    router.focused = 'b';
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received, isEmpty);
    await sub.cancel();
    await a.stopCapture();
    await router.close();
    await native.bus.close();
  });
  test('emergency invalidates queued input instead of replaying it', () async {
    final native = Native(), gate = Completer<void>();
    final router = InputRouter(native);
    final channel = router.channel('a');
    final received = <Map<String, dynamic>>[];
    final sub = channel.events.listen(received.add);
    router.focused = 'a';
    router.beforeEvent = (_) => gate.future;
    await channel.startCapture();
    native.bus.add({'type': 'key', 'usage': 4, 'down': true});
    await Future<void>.delayed(Duration.zero);
    native.bus.add({'type': 'emergency'});
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received.map((e) => e['type']), ['emergency']);
    await sub.cancel();
    await channel.stopCapture();
    await router.close();
    await native.bus.close();
  });
}
