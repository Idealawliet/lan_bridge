import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/desktop_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lan_bridge/lifecycle_test');
  const codec = StandardMethodCodec();
  test('explicit update exit uses native quit instead of hiding the window',
      () async {
    String? method;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      method = call.method;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await DesktopLifecycle(() async {}, channel: channel).quit();
    expect(method, 'quit');
  });
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

  test('status publishes control ownership and measured signal to native host',
      () async {
    MethodCall? received;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final lifecycle = DesktopLifecycle(() async {}, channel: channel);
    await lifecycle.updateStatus(
        control: '正在控制本机', signal: '延迟 12 ms · 抖动 2 ms', bars: 4);
    expect(received?.method, 'updateStatus');
    expect(received?.arguments,
        {'control': '正在控制本机', 'signal': '延迟 12 ms · 抖动 2 ms', 'bars': 4});
  });

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
