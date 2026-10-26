import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/desktop_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lan_bridge/lifecycle_test');
  const codec = StandardMethodCodec();
  Future<Object?> invoke(String method) async {
    final reply = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            channel.name, codec.encodeMethodCall(MethodCall(method)), (data) {
      try {
        reply.complete(data == null ? null : codec.decodeEnvelope(data));
      } catch (e) {
        reply.completeError(e);
      }
    });
    return reply.future;
  }

  test('native quit waits for service cleanup and coalesces repeated requests',
      () async {
    final gate = Completer<void>();
    var calls = 0;
    final lifecycle = DesktopLifecycle(() async {
      calls++;
      await gate.future;
    }, channel: channel)
      ..install();
    addTearDown(lifecycle.dispose);
    final a = invoke('prepareQuit'), b = invoke('prepareQuit');
    var finished = false;
    final result = Future.wait([a, b]).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(finished, isFalse);
    gate.complete();
    await result;
    expect(finished, isTrue);
  });
  test('failed cleanup reports error and allows a later exit retry', () async {
    var calls = 0;
    final lifecycle = DesktopLifecycle(() async {
      if (++calls == 1) throw StateError('busy');
    }, channel: channel)
      ..install();
    addTearDown(lifecycle.dispose);
    await expectLater(invoke('prepareQuit'), throwsA(isA<PlatformException>()));
    await invoke('prepareQuit');
    expect(calls, 2);
  });
}
