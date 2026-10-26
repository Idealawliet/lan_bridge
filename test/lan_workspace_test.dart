import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_input/lan_input.dart';
import 'package:lan_bridge/core/bridge_controller.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/lan_workspace.dart';
import 'package:lan_bridge/core/secure_transport.dart';

class FakeDiscovery extends LanDiscovery {
  @override
  Future<void> start({int port = LanDiscovery.discoveryPort}) async {}
}

class FakeNative extends LanInput {
  final bus = StreamController<Map<String, dynamic>>.broadcast();
  final injected = <Map<String, dynamic>>[];
  int starts = 0, stops = 0, releases = 0;
  bool remote = false;
  @override
  Stream<Map<String, dynamic>> get events => bus.stream;
  @override
  Future<InputStatus> getStatus() async => const InputStatus(
      supported: true,
      accessibility: true,
      inputMonitoring: true,
      screen: {'x': 0, 'y': 0, 'width': 1920, 'height': 1080});
  @override
  Future<void> startCapture() async {
    starts++;
  }

  @override
  Future<void> stopCapture() async {
    stops++;
    remote = false;
  }

  @override
  Future<void> setRemoteCapture(bool enabled) async {
    remote = enabled;
  }

  @override
  Future<void> heartbeat() async {}
  @override
  Future<void> releaseAll() async {
    releases++;
  }

  @override
  Future<void> inject(Map<String, dynamic> event) async {
    injected.add(event);
  }

  @override
  Future<void> warp(double x, double y) async {}
  @override
  Future<void> cancelFileDrag() async {}
  @override
  Future<void> configureFileEdge(bool enabled, bool left) async {}
  void move(double x, double y, {double dx = 0, double dy = 0}) =>
      bus.add({'type': 'move', 'x': x, 'y': y, 'dx': dx, 'dy': dy});
}

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('client starts discovery automatically and waits again after disconnect',
      () async {
    final input = FakeNative();
    final local = BridgeController(input: input, port: 0, enableSharing: false);
    final discovery = FakeDiscovery();
    final workspace = LanWorkspace(local,
        input: input, discovery: discovery, enableSharing: false);
    final sourceInput = FakeNative();
    late BridgeController source;
    addTearDown(() async {
      await workspace.close();
      await source.disconnect();
      source.dispose();
      local.dispose();
      await input.bus.close();
      await sourceInput.bus.close();
    });
    await workspace.startClient();
    expect(local.role, BridgeRole.target);
    expect(local.connectionMode, ConnectionMode.client);
    expect(local.listening, isTrue);
    expect(local.pairingKey, matches(RegExp(r'^\d{6}$')));
    expect(discovery.advertisement, isNotNull);
    expect(discovery.advertisement!()['busy'], isFalse);
    source = BridgeController(
        input: sourceInput, port: local.port, enableSharing: false);
    await source.connect('127.0.0.1', local.pairingKey);
    await until(() => local.connected);
    expect(discovery.advertisement!()['busy'], isTrue);
    await source.disconnect();
    await until(() => local.listening && !workspace.busy);
    expect(local.pairingKey, matches(RegExp(r'^\d{6}$')));
    expect(discovery.advertisement!()['busy'], isFalse);
    await workspace.stop();
    expect(local.phase, ConnectionPhase.idle);
    expect(discovery.advertisement, isNull);
  });

  test(
      'three clients remain connected, input is isolated and focus switches by edge',
      () async {
    final native = FakeNative();
    final local = BridgeController(input: native, enableSharing: false);
    final workspace = LanWorkspace(local,
        input: native, discovery: FakeDiscovery(), enableSharing: false);
    final clients = <BridgeController>[];
    final inputs = <FakeNative>[];
    final ids = <String>[];
    addTearDown(() async {
      await workspace.close();
      local.dispose();
      for (final client in clients) {
        await client.disconnect();
        client.dispose();
      }
      for (final input in inputs) {
        await input.bus.close();
      }
      await native.bus.close();
    });
    await workspace.startServer();
    for (var i = 0; i < 3; i++) {
      final input = FakeNative();
      inputs.add(input);
      final target =
          BridgeController(input: input, enableSharing: false, port: 0);
      clients.add(target);
      await target.setRole(BridgeRole.target);
      await target.listen();
      final id = generatePairingKey();
      ids.add(id);
      await workspace.add(
          LanDevice(
              id: id,
              name: 'client $i',
              platform: 'test',
              host: '127.0.0.1',
              port: target.port,
              busy: false,
              seen: DateTime.now()),
          target.pairingKey,
          [PeerSide.right, PeerSide.left, PeerSide.top][i]);
      expect(workspace.error, isNull);
    }
    await workspace.arrange(ids[0], PeerSide.bottom, .25);
    await until(() => clients[0].side == PeerSide.bottom);
    expect(clients[0].screenOffset, .25);
    await workspace.arrange(ids[0], PeerSide.right, 0);
    await until(() => clients[0].side == PeerSide.right);
    expect(native.starts, 1);
    expect(workspace.computers.length, 3);
    expect(clients.every((c) => c.connected), isTrue);
    native.move(1919, 500);
    await until(() => clients[0].remoteActive);
    native.bus.add({'type': 'key', 'usage': 4, 'down': true});
    await until(() => inputs[0].injected.any((e) => e['type'] == 'key'));
    expect(inputs[1].injected, isEmpty);
    expect(inputs[2].injected, isEmpty);
    await workspace.focus(ids[1]);
    await until(() => !clients[0].remoteActive);
    expect(inputs[0].releases, greaterThan(0));
    native.move(0, 500);
    await until(() => clients[1].remoteActive);
    expect(clients.every((c) => c.connected), isTrue);
    // Return to the server, then enter the third client's top seam.
    native.move(900, 500, dx: 5);
    await until(() => !clients[1].remoteActive);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    native.move(900, 0);
    await until(() => clients[2].remoteActive);
    expect(workspace.active!.device.id, ids[2]);
    // Removing an inactive session must not stop the focused hook or peer.
    final stops = native.stops;
    await workspace.remove(ids[0]);
    expect(native.stops, stops);
    expect(clients[2].connected, isTrue);
    expect(native.remote, isTrue);
    await clients[2].disconnect();
    await until(() => !workspace.computers[ids[2]]!.controller.connected);
    expect(clients[1].connected, isTrue);
    await workspace.focus(ids[1]);
    native.move(0, 500);
    await until(() => clients[1].remoteActive);
    native.bus.add({'type': 'emergency'});
    await until(() => clients.skip(1).every((c) => !c.connected));
    expect(native.remote, isFalse);
    await Future.wait([workspace.stop(), workspace.stop()]);
    expect(workspace.running, isFalse);
    expect(workspace.computers, isEmpty);
    expect(workspace.router.channels, isEmpty);
    expect(native.stops, 1);
  });
  test('a bad pairing key never joins or receives input', () async {
    final native = FakeNative(), clientInput = FakeNative();
    final local = BridgeController(input: native, enableSharing: false);
    final client =
        BridgeController(input: clientInput, enableSharing: false, port: 0);
    final workspace = LanWorkspace(local,
        input: native, discovery: FakeDiscovery(), enableSharing: false);
    addTearDown(() async {
      await workspace.close();
      await client.disconnect();
      local.dispose();
      client.dispose();
      await native.bus.close();
      await clientInput.bus.close();
    });
    await client.setRole(BridgeRole.target);
    await client.listen();
    await workspace.startServer();
    await workspace.add(
        LanDevice(
            id: generatePairingKey(),
            name: 'unpaired',
            platform: 'test',
            host: '127.0.0.1',
            port: client.port,
            busy: false,
            seen: DateTime.now()),
        '000000',
        PeerSide.right);
    expect(workspace.computers, isEmpty);
    expect(workspace.router.channels, isEmpty);
    expect(workspace.error, isNotNull);
    expect(client.listening, isTrue);
    expect(clientInput.injected, isEmpty);
  });
}
