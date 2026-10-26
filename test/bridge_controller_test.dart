import 'dart:async';
import 'dart:io';
import 'package:lan_bridge/core/app_version.dart';
import 'package:lan_bridge/core/desktop_settings.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:lan_bridge/core/bridge_controller.dart';
import 'package:lan_bridge/core/secure_transport.dart';
import 'package:lan_bridge/core/screen_layout.dart';
import 'package:lan_input/lan_input.dart';

void main() {
  for (final peerVersion in ['0.0.1', null]) {
    test(
        'refuses mismatched or missing software version $peerVersion before control',
        () async {
      final input = _FakeInput(1920, 1080);
      final target =
          BridgeController(input: input, enableSharing: false, port: 0);
      await target.setRole(BridgeRole.target);
      await target.listen();
      final peer = await connectSecurePeer(
          host: '127.0.0.1', port: target.port, pairingKey: target.pairingKey);
      final subscription = peer.messages.listen((_) {});
      addTearDown(() async {
        await subscription.cancel();
        await peer.close();
        await target.disconnect();
        target.dispose();
        await input.close();
      });
      await peer.send({
        'type': 'hello',
        'version': 7,
        if (peerVersion != null) 'appVersion': peerVersion,
        'role': 'source',
        'side': 'right',
        'offset': 0.0,
        'screen': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}
      });
      await _until(() => target.phase == ConnectionPhase.idle);
      expect(target.error, contains('版本不一致'));
      expect(target.connected, isFalse);
      expect(input.injected, isEmpty);
    });
  }
  test('heartbeat measures round trip and resets signal on disconnect',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    await _until(
        () => pair.source.latencyMs != null && pair.target.latencyMs != null);
    expect(pair.source.latencyMs, greaterThanOrEqualTo(0));
    expect(pair.source.signalBars, inInclusiveRange(1, 4));
    expect(pair.source.jitterMs, greaterThanOrEqualTo(0));
    await pair.source.disconnect();
    expect(pair.source.latencyMs, isNull);
    expect(pair.source.signalBars, isNull);
    expect(pair.source.jitterMs, 0);
  });

  test(
      'inactive target hides cursor and restores it on enter, leave and disconnect',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    expect(pair.targetInput.cursorVisible, isFalse);
    pair.sourceInput.move(1919, 500);
    await _until(() => pair.target.remoteActive);
    expect(pair.targetInput.cursorVisible, isTrue);
    pair.sourceInput.move(1000, 500, dx: -100);
    await _until(() => !pair.target.remoteActive);
    expect(pair.targetInput.cursorVisible, isFalse);
    await pair.target.disconnect();
    expect(pair.targetInput.cursorVisible, isTrue);
    await _until(() => !pair.source.connected);
    expect(pair.sourceInput.remote, isFalse);
  });

  test(
      'slow native injection coalesces network motion while retaining key barriers',
      () async {
    final input = _FakeInput(1920, 1080);
    final target =
        BridgeController(input: input, enableSharing: false, port: 0);
    await target.setRole(BridgeRole.target);
    await target.listen();
    final peer = await connectSecurePeer(
        host: '127.0.0.1', port: target.port, pairingKey: target.pairingKey);
    final subscription = peer.messages.listen((_) {});
    final gate = Completer<void>();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await subscription.cancel();
      await peer.close();
      await target.disconnect();
      target.dispose();
      await input.close();
    });
    await peer.send({
      'type': 'hello',
      'version': 7,
      'appVersion': appVersion,
      'role': 'source',
      'side': 'right',
      'offset': 0.0,
      'screen': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}
    });
    await _until(() => target.connected);
    await peer.send({'type': 'enter', 'x': 500.0, 'y': 500.0});
    await _until(() => target.remoteActive);
    input.injectGate = gate;
    input.injectStarted = Completer<void>();
    final initialCount = input.injected.length;
    Future<void> move(int x) => peer.send({
          'type': 'input',
          'event': {'type': 'move', 'x': x.toDouble(), 'y': 500.0}
        });
    await move(500);
    await input.injectStarted!.future;
    for (var x = 501; x <= 600; x++) {
      await move(x);
    }
    await peer.send({
      'type': 'input',
      'event': {'type': 'key', 'usage': 4, 'down': true}
    });
    for (var x = 601; x <= 650; x++) {
      await move(x);
    }
    await peer.send({
      'type': 'input',
      'event': {'type': 'key', 'usage': 4, 'down': false}
    });
    await Future<void>.delayed(const Duration(milliseconds: 80));
    gate.complete();
    await _until(() => input.injected
        .any((event) => event['type'] == 'key' && event['down'] == false));
    final events = input.injected.skip(initialCount).toList();
    final moves = events.where((event) => event['type'] == 'move').toList();
    expect(moves.length, lessThanOrEqualTo(4));
    expect(moves.last['x'], 650.0);
    expect(events.map((event) => event['type']),
        ['move', 'move', 'key', 'move', 'key']);
    expect(events[1]['x'], 600.0);
    expect(events[2]['down'], isTrue);
    expect(events.last['down'], isFalse);
    expect(target.connected, isTrue);
    debugPrint(
        'MOTION_BACKLOG: received_samples=151 injected_moves=${moves.length} keys_ordered=true');
  });

  final resolutionPairs = [
    (
      const ScreenRect(-3840, -300, 3840, 2160),
      const ScreenRect(100, 50, 1920, 1080)
    ),
    (
      const ScreenRect(0, 0, 1920, 1080),
      const ScreenRect(-3840, 0, 3840, 2160)
    ),
    (
      const ScreenRect(0, 0, 7680, 4320),
      const ScreenRect(0, -1080, 1920, 1080)
    ),
    (
      const ScreenRect(0, 0, 1512, 982),
      const ScreenRect(-2560, 100, 2560, 1440)
    ),
    (const ScreenRect(0, 0, 1080, 1920), const ScreenRect(200, 0, 3440, 1440)),
  ];
  for (final (source, target) in resolutionPairs) {
    for (final side in PeerSide.values) {
      test(
          'mixed resolution ${source.width}x${source.height} -> ${target.width}x${target.height} $side preserves seam fraction and return',
          () async {
        final pair = await _Controllers.open(
            side: side, sourceRect: source, targetRect: target);
        addTearDown(pair.close);
        const f = .37;
        final layout = ScreenArrangement(side, 0);
        final entry = switch (side) {
          PeerSide.left => (x: source.x, y: source.atY(f)),
          PeerSide.right => (x: source.x + source.width - 1, y: source.atY(f)),
          PeerSide.top => (x: source.x + f * (source.width - 1), y: source.y),
          PeerSide.bottom => (
              x: source.x + f * (source.width - 1),
              y: source.y + source.height - 1
            ),
        };
        pair.sourceInput.emit({
          'type': 'move',
          'captured': false,
          'x': entry.x,
          'y': entry.y,
          'dx': 0,
          'dy': 0
        });
        await _until(() => pair.target.remoteActive);
        final mapped = pair.targetInput.injected.first;
        expect(
            layout.tangent(
                target, mapped['x'] as double, mapped['y'] as double),
            closeTo(f, 1e-9));
        pair.sourceInput.emit({
          'type': 'move',
          'captured': true,
          'x': 0,
          'y': 0,
          'dx': side == PeerSide.left
              ? 20
              : side == PeerSide.right
                  ? -20
                  : 0,
          'dy': side == PeerSide.top
              ? 20
              : side == PeerSide.bottom
                  ? -20
                  : 0
        });
        await _until(() => !pair.target.remoteActive);
        final back = pair.sourceInput.warps.last;
        expect(layout.tangent(source, back[0], back[1]), closeTo(f, 1e-9));
      });
    }
  }
  test('4K relative motion scales to 1080p without a speed jump', () async {
    final pair = await _Controllers.open(
        sourceRect: const ScreenRect(0, 0, 3840, 2160),
        targetRect: const ScreenRect(0, 0, 1920, 1080));
    addTearDown(pair.close);
    pair.sourceInput.move(3839, 1079.5);
    await _until(() => pair.target.remoteActive);
    pair.sourceInput.emit({
      'type': 'move',
      'captured': true,
      'x': 1920,
      'y': 1080,
      'dx': 100,
      'dy': 100
    });
    await _until(() => pair.targetInput.injected.length == 2);
    expect(pair.targetInput.injected.last['x'],
        closeTo(1 + 100 * 1919 / 3839, 1e-9));
    expect(pair.targetInput.injected.last['y'],
        closeTo(539.5 + 100 * 1079 / 2159, 1e-9));
  });
  test(
      'diagonal return maps the seam intersection instead of the overshot endpoint',
      () async {
    final pair = await _Controllers.open(
        sourceRect: const ScreenRect(0, 0, 3840, 2160),
        targetRect: const ScreenRect(0, 0, 1920, 1080));
    addTearDown(pair.close);
    pair.sourceInput.move(3839, 1079.5);
    await _until(() => pair.target.remoteActive);
    pair.sourceInput.emit({
      'type': 'move',
      'captured': true,
      'x': 1920,
      'y': 1080,
      'dx': -100,
      'dy': 100
    });
    await _until(() => !pair.target.remoteActive);
    final mappedDy = 100 * 1079 / 2159;
    final t = 1 / (100 * 1919 / 3839);
    final expected = (539.5 + mappedDy * t) / 1079 * 2159;
    expect(pair.sourceInput.warps.last[1], closeTo(expected, 1e-6));
  });

  test('local samples arriving after entry cannot jump the remote pointer',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    pair.sourceInput.emit({
      'type': 'move',
      'captured': false,
      'x': 1919,
      'y': 500,
      'dx': 1,
      'dy': 0
    });
    await _until(() => pair.target.remoteActive);
    pair.sourceInput.emit({
      'type': 'move',
      'captured': false,
      'x': 1919,
      'y': 500,
      'dx': 500,
      'dy': 0
    });
    pair.sourceInput.emit({
      'type': 'move',
      'captured': true,
      'x': 960,
      'y': 540,
      'dx': 3,
      'dy': 0
    });
    await _until(() => pair.targetInput.injected.length >= 2);
    expect(pair.targetInput.injected.last['x'],
        closeTo(1 + 3 * 2559 / 1919, 1e-6));
  });

  test(
      'role, network mode and arrangement survive restarting without storing pairing keys',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('lan-controller-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final saved = Completer<void>();
    final settings = _SavedSettings(directory, saved);
    final input = _FakeInput(1920, 1080);
    final first = BridgeController(
        input: input,
        enableSharing: false,
        settings: settings,
        startup: LoginStartup(operatingSystem: 'linux'));
    await first.initialize();
    await first.setRole(BridgeRole.target);
    first.setConnectionMode(ConnectionMode.client);
    first.setArrangement(PeerSide.bottom, -.4);
    first.pairingKey = 'never persist this';
    await saved.future;
    final second = BridgeController(
        input: input,
        enableSharing: false,
        settings: settings,
        startup: LoginStartup(operatingSystem: 'linux'));
    await second.initialize();
    expect(second.role, BridgeRole.target);
    expect(second.connectionMode, ConnectionMode.client);
    expect(second.side, PeerSide.bottom);
    expect(second.screenOffset, -.4);
    expect(second.pairingKey, isEmpty);
    expect((await settings.load()).keys, isNot(contains('pairingKey')));
    first.dispose();
    second.dispose();
    await input.close();
  });
  for (final side in [PeerSide.top, PeerSide.bottom]) {
    test('$side with offset crosses only shared edges and returns', () async {
      final pair = await _Controllers.open(side: side, offset: 0.25);
      addTearDown(pair.close);
      expect(pair.target.screenOffset, 0.25);
      final y = side == PeerSide.top ? 0.0 : 1079.0;
      pair.sourceInput.move(100, y);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(pair.sourceInput.enableAttempts, 0);
      pair.sourceInput.move(959.5, y);
      await _until(() => pair.target.remoteActive);
      expect(pair.targetInput.injected.first['x'], closeTo(639.75, .001));
      expect(pair.targetInput.injected.first['y'],
          side == PeerSide.top ? 1438.0 : 1.0);
      pair.sourceInput.move(900, 500, dx: 0, dy: side == PeerSide.top ? 4 : -4);
      await _until(() => !pair.target.remoteActive);
      expect(pair.sourceInput.warps.last[0], closeTo(959.5, .001));
      expect(
          pair.sourceInput.warps.last[1], side == PeerSide.top ? 12.0 : 1067.0);
    });
  }
  test('keyboard source can listen as server while target connects as client',
      () async {
    final pair = await _Controllers.open(sourceIsServer: true);
    addTearDown(pair.close);
    expect(pair.source.connectionMode, ConnectionMode.server);
    expect(pair.target.connectionMode, ConnectionMode.client);
    pair.sourceInput.move(1919, 539.5);
    await _until(() => pair.target.remoteActive);
    pair.sourceInput.emit({'type': 'key', 'usage': 4, 'down': true});
    await _until(
        () => pair.targetInput.injected.any((e) => e['type'] == 'key'));
    pair.source.setConnectionMode(ConnectionMode.client);
    pair.source.setArrangement(PeerSide.top, .5);
    expect(pair.source.connectionMode, ConnectionMode.server);
    expect(pair.source.side, PeerSide.right);
    await pair.source.disconnect();
    await pair.source.setRole(BridgeRole.target);
    pair.source.setConnectionMode(ConnectionMode.client);
    expect(pair.source.role, BridgeRole.target);
    expect(pair.source.connectionMode, ConnectionMode.client);
  });

  test('left layout synchronizes and returns through the opposite edge',
      () async {
    final pair = await _Controllers.open(side: PeerSide.left);
    addTearDown(pair.close);
    expect(pair.target.side, PeerSide.left);
    pair.sourceInput.move(0, 539.5);
    await _until(() => pair.target.remoteActive);
    expect(pair.targetInput.injected.first['x'], 2558.0);
    pair.sourceInput.move(960, 540, dx: 4);
    await _until(() => !pair.target.remoteActive);
    expect(pair.sourceInput.warps.last, [12.0, 539.5]);
  });

  test('paired controllers cross, send input, and return with keys released',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    // Retina pointer coordinates may end on half points at the display edge.
    pair.sourceInput.move(1919.5, 539.5);
    await _until(() => pair.target.remoteActive);
    expect(pair.sourceInput.remote, isTrue);
    expect(pair.targetInput.injected.first,
        {'type': 'move', 'x': 1.0, 'y': 719.5});
    pair.sourceInput.emit({'type': 'key', 'usage': 4, 'down': true});
    pair.sourceInput.emit({'type': 'button', 'button': 1, 'down': true});
    pair.sourceInput.emit({'type': 'scroll', 'dx': 0.0, 'dy': 1.0});
    await _until(() => pair.targetInput.injected.length == 4);
    pair.sourceInput.move(960, 540, dx: -8);
    await _until(() => !pair.target.remoteActive);
    expect(pair.sourceInput.remote, isFalse);
    expect(pair.sourceInput.warps.last, [1907.0, 539.5]);
    expect(pair.targetInput.releases, greaterThan(0));
    expect(pair.source.connected, isTrue);
    expect(pair.target.connected, isTrue);
  });

  test('held inputs block crossing without disconnecting; next move retries',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    pair.sourceInput.inputBusy = true;
    pair.sourceInput.move(1919, 500);
    await _until(() => pair.sourceInput.enableAttempts == 1);
    expect(pair.source.remoteActive, isFalse);
    expect(pair.source.connected, isTrue);
    pair.sourceInput.inputBusy = false;
    pair.sourceInput.move(1919, 510);
    await _until(() => pair.target.remoteActive);
    expect(pair.sourceInput.remote, isTrue);
  });

  test('emergency on target disconnects both peers and releases input',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    pair.sourceInput.move(1919, 500);
    await _until(() => pair.target.remoteActive);
    pair.targetInput.emit({'type': 'emergency'});
    await _until(() =>
        pair.source.phase == ConnectionPhase.idle &&
        pair.target.phase == ConnectionPhase.idle);
    expect(pair.sourceInput.remote, isFalse);
    expect(pair.targetInput.releases, greaterThan(0));
    expect(pair.source.pairingKey, isEmpty);
    expect(pair.target.pairingKey, isEmpty);
  });

  test('disconnect during native crossing cannot leave input suppressed',
      () async {
    final pair = await _Controllers.open();
    addTearDown(pair.close);
    final gate = Completer<void>();
    pair.sourceInput.enableGate = gate;
    pair.sourceInput.move(1919, 500);
    await _until(() => pair.sourceInput.enableAttempts == 1);
    await pair.source.disconnect();
    gate.complete();
    await _until(() => pair.sourceInput.disableCalls >= 2);
    expect(pair.sourceInput.remote, isFalse);
    expect(pair.source.remoteActive, isFalse);
    expect(pair.source.phase, ConnectionPhase.idle);
  });

  test('target refuses authenticated input before entering its screen',
      () async {
    final input = _FakeInput(1920, 1080);
    final target =
        BridgeController(enableSharing: false, input: input, port: 0);
    await target.setRole(BridgeRole.target);
    await target.listen();
    final peer = await connectSecurePeer(
        host: '127.0.0.1', pairingKey: target.pairingKey, port: target.port);
    final subscription = peer.messages.listen((_) {});
    addTearDown(() async {
      await subscription.cancel();
      await peer.close();
      await target.disconnect();
      target.dispose();
      await input.close();
    });
    await peer.send({
      'type': 'hello',
      'version': 7,
      'appVersion': appVersion,
      'role': 'source',
      'side': 'right',
      'offset': 0.0,
      'screen': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}
    });
    await _until(() => target.connected);
    await peer.send({
      'type': 'input',
      'event': {'type': 'key', 'usage': 4, 'down': true}
    });
    await _until(() => target.phase == ConnectionPhase.idle);
    expect(input.injected, isEmpty);
    expect(target.error, contains('无效的输入状态'));
  });

  test('silent authenticated peer times out and releases held input', () async {
    final input = _FakeInput(1920, 1080);
    final target =
        BridgeController(enableSharing: false, input: input, port: 0);
    await target.setRole(BridgeRole.target);
    await target.listen();
    final peer = await connectSecurePeer(
        host: '127.0.0.1', pairingKey: target.pairingKey, port: target.port);
    final subscription = peer.messages.listen((_) {});
    addTearDown(() async {
      await subscription.cancel();
      await peer.close();
      await target.disconnect();
      target.dispose();
      await input.close();
    });
    await peer.send({
      'type': 'hello',
      'version': 7,
      'appVersion': appVersion,
      'role': 'source',
      'side': 'right',
      'offset': 0.0,
      'screen': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}
    });
    await _until(() => target.connected);
    await peer.send({'type': 'enter', 'x': 1, 'y': 500});
    await peer.send({
      'type': 'input',
      'event': {'type': 'key', 'usage': 225, 'down': true}
    });
    await _until(() => input.injected.length == 2);
    await _until(() => target.phase == ConnectionPhase.idle);
    expect(input.releases, greaterThan(0));
    expect(target.remoteActive, isFalse);
    expect(target.error, contains('心跳超时'));
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for controller state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Controllers {
  _Controllers(this.source, this.target, this.sourceInput, this.targetInput);
  final BridgeController source, target;
  final _FakeInput sourceInput, targetInput;
  static Future<_Controllers> open(
      {PeerSide side = PeerSide.right,
      double offset = 0,
      bool sourceIsServer = false,
      ScreenRect sourceRect = const ScreenRect(0, 0, 1920, 1080),
      ScreenRect targetRect = const ScreenRect(0, 0, 2560, 1440)}) async {
    final sourceInput = _FakeInput(sourceRect.width, sourceRect.height,
            x: sourceRect.x, y: sourceRect.y),
        targetInput = _FakeInput(targetRect.width, targetRect.height,
            x: targetRect.x, y: targetRect.y);
    late BridgeController source, target;
    if (sourceIsServer) {
      source =
          BridgeController(enableSharing: false, input: sourceInput, port: 0);
      source.setConnectionMode(ConnectionMode.server);
      source.setArrangement(side, offset);
      await source.listen();
      expect(source.listening, isTrue, reason: source.error);
      target = BridgeController(
          enableSharing: false, input: targetInput, port: source.port);
      await target.setRole(BridgeRole.target);
      target.setConnectionMode(ConnectionMode.client);
      await target.connect('127.0.0.1', source.pairingKey);
      await _until(() => source.connected);
    } else {
      target =
          BridgeController(enableSharing: false, input: targetInput, port: 0);
      await target.setRole(BridgeRole.target);
      await target.listen();
      expect(target.listening, isTrue, reason: target.error);
      source = BridgeController(
          enableSharing: false, input: sourceInput, port: target.port);
      source.setArrangement(side, offset);
      await source.connect('127.0.0.1', target.pairingKey);
      await _until(() => target.connected);
    }
    expect(source.connected, isTrue, reason: source.error);
    return _Controllers(source, target, sourceInput, targetInput);
  }

  Future<void> close() async {
    await source.disconnect();
    await target.disconnect();
    source.dispose();
    target.dispose();
    await sourceInput.close();
    await targetInput.close();
  }
}

class _FakeInput extends LanInput {
  bool cursorVisible = true;
  @override
  Future<void> setCursorVisible(bool visible) async {
    cursorVisible = visible;
  }

  _FakeInput(this.width, this.height, {this.x = 0, this.y = 0});
  final double width, height, x, y;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final injected = <Map<String, dynamic>>[];
  final warps = <List<double>>[];
  bool remote = false, inputBusy = false;
  int releases = 0, enableAttempts = 0, disableCalls = 0;
  Completer<void>? enableGate, injectGate, injectStarted;
  void emit(Map<String, dynamic> event) => _events.add(event);
  void move(double x, double y, {double dx = 1, double dy = 0}) =>
      emit({'type': 'move', 'x': x, 'y': y, 'dx': dx, 'dy': dy});
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<InputStatus> getStatus() async => InputStatus(
      supported: true,
      accessibility: true,
      inputMonitoring: true,
      screen: {'x': x, 'y': y, 'width': width, 'height': height});
  @override
  Future<void> startCapture() async {}
  @override
  Future<void> stopCapture() async {
    remote = false;
  }

  @override
  Future<void> heartbeat() async {}
  @override
  Future<void> setRemoteCapture(bool enabled) async {
    if (enabled) {
      enableAttempts++;
      if (inputBusy) throw PlatformException(code: 'input_busy');
      await enableGate?.future;
    } else {
      disableCalls++;
    }
    remote = enabled;
  }

  @override
  Future<void> inject(Map<String, dynamic> event) async {
    if (event['type'] == 'move' && injectGate != null) {
      if (injectStarted != null && !injectStarted!.isCompleted) {
        injectStarted!.complete();
      }
      await injectGate!.future;
    }
    injected.add(event);
  }

  @override
  Future<void> warp(double x, double y) async {
    warps.add([x, y]);
  }

  @override
  Future<void> releaseAll() async {
    releases++;
  }

  Future<void> close() => _events.close();
}

class _SavedSettings extends DesktopSettings {
  _SavedSettings(Directory directory, this.saved)
      : super(directory: () async => directory);
  final Completer<void> saved;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    await super.save(data);
    if (data['offset'] == -.4 && !saved.isCompleted) saved.complete();
  }
}
