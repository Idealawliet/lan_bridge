import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:lan_bridge/core/bridge_controller.dart';
import 'package:lan_bridge/core/lan_workspace.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/secure_transport.dart';
import 'lan_workspace_test.dart' as support;
import 'clipboard_sync_test.dart' show MemoryClipboard;
import 'package:lan_bridge/sharing/clipboard_sync.dart';

class GateNative extends support.FakeNative {
  Completer<void>? gate;
  bool entering = false, physicalHeld = false;
  @override
  Future<void> configureFileEdgeLayout(
      bool enabled, String edge, double start, double end) async {}
  @override
  Future<void> setRemoteCapture(bool enabled) async {
    if (enabled && physicalHeld) throw PlatformException(code: 'input_busy');
    if (enabled && gate != null) {
      entering = true;
      await gate!.future;
    }
    await super.setRemoteCapture(enabled);
  }
}

class Fixture {
  final native = GateNative();
  late final local = BridgeController(input: native, enableSharing: false);
  late final workspace = LanWorkspace(local,
      input: native, discovery: support.FakeDiscovery(), enableSharing: false);
  final clients = <BridgeController>[],
      inputs = <support.FakeNative>[],
      ids = <String>[];
  Future<void> open() async {
    await workspace.startServer();
    for (var i = 0; i < 3; i++) {
      final input = support.FakeNative();
      inputs.add(input);
      final client =
          BridgeController(input: input, enableSharing: false, port: 0);
      clients.add(client);
      await client.setRole(BridgeRole.target);
      await client.listen();
      final id = generatePairingKey();
      ids.add(id);
      await workspace.add(
          LanDevice(
              id: id,
              name: 'stress-$i',
              platform: 'test',
              host: '127.0.0.1',
              port: client.port,
              busy: false,
              seen: DateTime.now()),
          client.pairingKey,
          [PeerSide.right, PeerSide.left, PeerSide.top][i]);
      expect(workspace.error, isNull);
    }
  }

  Future<void> close() async {
    if (native.gate != null && !native.gate!.isCompleted) {
      native.gate!.complete();
    }
    await workspace.close();
    local.dispose();
    for (final c in clients) {
      await c.disconnect();
      c.dispose();
    }
    for (final i in inputs) {
      await i.bus.close();
    }
    await native.bus.close();
  }
}

void main() {
  test(
      'held keys release on the old peer and block a new capture until physically released',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.open();
    f.native.move(1919, 500);
    await support.until(() => f.clients[0].remoteActive);
    f.native.bus.add({'type': 'key', 'usage': 4, 'down': true});
    await support
        .until(() => f.inputs[0].injected.any((e) => e['type'] == 'key'));
    f.native.physicalHeld = true;
    final releases = f.inputs[0].releases;
    await f.workspace.focus(f.ids[1]);
    expect(f.inputs[0].releases, greaterThan(releases));
    expect(f.clients[0].remoteActive, isFalse);
    f.native.move(0, 500);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(f.clients[1].remoteActive, isFalse);
    expect(f.clients.every((c) => c.connected), isTrue);
    f.native.physicalHeld = false;
    f.native.move(0, 500);
    await support.until(() => f.clients[1].remoteActive);
    expect(f.inputs[1].injected.where((e) => e['type'] == 'key'), isEmpty);
  });

  test(
      '60 switches with 90000 motion samples keep releases and coordinates ordered',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.open();
    final latency = <int>[];
    final elapsed = Stopwatch()..start();
    for (var cycle = 0; cycle < 60; cycle++) {
      final index = cycle % 3;
      final timer = Stopwatch()..start();
      await f.workspace.focus(f.ids[index]);
      // The previous target has acknowledged releasing its input before a
      // new target can receive the next keydown.
      for (var other = 0; other < 3; other++) {
        if (other != index) expect(f.clients[other].remoteActive, isFalse);
      }
      if (index == 0) {
        f.native.move(1919, 500);
      } else if (index == 1) {
        f.native.move(0, 500);
      } else {
        f.native.move(900, 0);
      }
      await support.until(() => f.clients[index].remoteActive);
      latency.add(timer.elapsedMicroseconds);
      final events = f.inputs[index].injected;
      final start = events.length;
      f.native.bus.add({'type': 'key', 'usage': 4, 'down': true});
      f.native.bus.add({'type': 'button', 'button': 1, 'down': true});
      for (var i = 0; i < 1500; i++) {
        f.native.move(960, 540,
            dx: index == 0
                ? 0.1
                : index == 1
                    ? -0.1
                    : 0,
            dy: index == 2 ? -0.1 : 0);
      }
      f.native.bus.add({'type': 'key', 'usage': 4, 'down': false});
      f.native.bus.add({'type': 'button', 'button': 1, 'down': false});
      await support.until(() => events
          .skip(start)
          .any((e) => e['type'] == 'button' && e['down'] == false));
      final keys = events.skip(start).where((e) => e['type'] == 'key').toList();
      expect(keys.map((e) => e['down']), [true, false]);
      final lastMove = events.skip(start).lastWhere((e) => e['type'] == 'move');
      if (index == 0) expect(lastMove['x'], closeTo(151, 1e-6));
      if (index == 1) expect(lastMove['x'], closeTo(1768, 1e-6));
      if (index == 2) expect(lastMove['y'], closeTo(928, 1e-6));
      expect(f.clients.every((c) => c.connected), isTrue);
    }
    latency.sort();
    debugPrint(
        'SWITCH_STRESS: cycles=60 samples=90000 elapsed_ms=${elapsed.elapsedMilliseconds} '
        'p50_us=${latency[30]} p95_us=${latency[57]} max_us=${latency.last}');
    expect(f.native.starts, 1);
  });

  test('keyboard release is not blocked by a slow remote clipboard write',
      () async {
    final sourceInput = GateNative(), targetInput = GateNative();
    final ca = MemoryClipboard(), cb = SlowClipboard();
    final target =
        BridgeController(input: targetInput, clipboardAccess: cb, port: 0);
    await target.setRole(BridgeRole.target);
    await target.listen();
    final source = BridgeController(
        input: sourceInput, clipboardAccess: ca, port: target.port);
    addTearDown(() async {
      if (!cb.writeGate!.isCompleted) cb.writeGate!.complete();
      await source.disconnect();
      await target.disconnect();
      source.dispose();
      target.dispose();
      await sourceInput.bus.close();
      await targetInput.bus.close();
    });
    await source.connect('127.0.0.1', target.pairingKey);
    await support.until(() => target.connected);
    sourceInput.move(1919, 500);
    await support.until(() => target.remoteActive);
    sourceInput.bus.add({'type': 'key', 'usage': 4, 'down': true});
    await support
        .until(() => targetInput.injected.any((e) => e['type'] == 'key'));
    await source.clipboard!.poll();
    ca.copy('clipboard while typing');
    final copy = source.clipboard!.poll();
    await support.until(() => cb.writing);
    sourceInput.bus.add({'type': 'key', 'usage': 4, 'down': false});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final released = targetInput.injected
        .any((e) => e['type'] == 'key' && e['down'] == false);
    cb.writeGate!.complete();
    await copy;
    expect(released, isTrue);
    expect(target.connected, isTrue);
  });

  test(
      'switch during in-flight crossing cannot reactivate or type into old peer',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.open();
    f.native.gate = Completer<void>();
    f.native.move(1919, 500);
    await support.until(() => f.native.entering);
    f.native.bus.add({'type': 'key', 'usage': 4, 'down': true});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final switching = f.workspace.focus(f.ids[1]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    f.native.gate!.complete();
    await switching;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(f.workspace.active!.device.id, f.ids[1]);
    expect(f.clients[0].remoteActive, isFalse);
    expect(f.inputs[0].injected.where((e) => e['type'] == 'key'), isEmpty);
  });
  test(
      'return and immediately cross into a different peer without a global delay',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.open();
    await f.workspace.focus(f.ids[1]);
    f.native.move(0, 500);
    await support.until(() => f.clients[1].remoteActive);
    f.native.move(900, 500, dx: 5);
    await support.until(() => !f.clients[1].remoteActive);
    f.native.move(900, 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(f.clients[2].remoteActive, isTrue);
  });
}

class SlowClipboard extends MemoryClipboard {
  SlowClipboard() {
    writeGate = Completer<void>();
  }
  bool writing = false;
  @override
  Future<void> write(ClipboardContent value) async {
    writing = true;
    await super.write(value);
  }
}
