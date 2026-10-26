import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/secure_transport.dart';

class _StartedDiscovery extends LanDiscovery {
  @override
  bool get running => true;
}

void main() {
  test(
      'outbound requests enforce opposite roles, busy state and deduplicate retries',
      () async {
    final discovery = _StartedDiscovery();
    addTearDown(discovery.close);
    discovery.advertisement = () => {
          'op': 'server',
          'name': 'host',
          'platform': 'test',
          'port': 24872,
          'busy': false
        };
    LanDevice peer({bool server = false, bool busy = false}) => LanDevice(
        id: 'same-peer',
        name: 'peer',
        platform: 'test',
        host: '192.168.1.2',
        port: 24872,
        busy: busy,
        seen: DateTime.now(),
        isServer: server);
    expect(() => discovery.requestConnection(peer(server: true)),
        throwsStateError);
    expect(
        () => discovery.requestConnection(peer(busy: true)), throwsStateError);
    discovery.requestConnection(peer());
    expect(discovery.outgoingRequests.values.single.kind, 'control');
    discovery.requestConnection(peer());
    expect(discovery.outgoingRequests.length, 1);
    discovery.advertisement = () =>
        {'name': 'client', 'platform': 'test', 'port': 24872, 'busy': false};
    discovery.requestConnection(peer(server: true));
    expect(discovery.outgoingRequests.values.single.kind, 'join');
    expect(() => discovery.requestConnection(peer()), throwsStateError);
  });

  test('role discovery and targeted requests require approval and expire',
      () async {
    final server = LanDiscovery(), client = LanDiscovery();
    addTearDown(server.close);
    addTearDown(client.close);
    server.advertisement = () => {'op': 'server', 'busy': false};
    client.advertisement = () => {'busy': false};
    final now = DateTime.now();
    final metadata = <String, dynamic>{
      'id': server.id,
      'name': 'server',
      'platform': 'test',
      'port': 24872,
      'busy': false
    };
    client.ingest({...metadata, 'op': 'server'}, '192.168.1.2', now);
    expect(client.devices[server.id]!.isServer, isTrue);
    final requestId = generatePairingKey();
    final request = {
      ...metadata,
      'op': 'request',
      'target': client.id,
      'request': requestId,
      'kind': 'control'
    };
    client.ingest(
        {...request, 'target': generatePairingKey()}, '192.168.1.2', now);
    client.ingest({...request, 'kind': 'join'}, '192.168.1.2', now);
    expect(client.incomingRequests, isEmpty);
    client.ingest(request, '192.168.1.2', now);
    expect(client.incomingRequests[requestId]!.status, 'pending');
    client.respond(client.incomingRequests[requestId]!, true);
    expect(client.incomingRequests[requestId]!.status, 'accepted');
    client.ingest(request, '192.168.1.2', now);
    expect(client.incomingRequests.length, 1);
    server.ingest({
      ...metadata,
      'id': client.id,
      'op': 'request',
      'kind': 'join',
      'target': server.id,
      'request': generatePairingKey()
    }, '192.168.1.3', now);
    expect(server.incomingRequests.values.single.kind, 'join');
    server.respond(server.incomingRequests.values.single, false);
    expect(server.incomingRequests.values.single.status, 'rejected');
    client.expire(now.add(const Duration(seconds: 61)));
    expect(client.incomingRequests, isEmpty);
  });

  test(
      'responses must match the outstanding request, target and source address',
      () async {
    final discovery = LanDiscovery();
    addTearDown(discovery.close);
    final now = DateTime.now();
    final device = LanDevice(
        id: generatePairingKey(),
        name: 'peer',
        platform: 'test',
        host: '192.168.1.2',
        port: 24872,
        busy: false,
        seen: now);
    final request =
        ConnectionRequest(generatePairingKey(), device, 'control', now);
    discovery.outgoingRequests[request.id] = request;
    final response = {
      'op': 'response',
      'id': device.id,
      'request': request.id,
      'target': discovery.id,
      'status': 'accepted'
    };
    discovery.ingest(response, '192.168.1.3', now);
    discovery.ingest(
        {...response, 'target': generatePairingKey()}, device.host, now);
    expect(request.status, 'pending');
    discovery.ingest(response, device.host, now);
    expect(request.status, 'accepted');
    discovery.ingest({...response, 'status': 'rejected'}, device.host, now);
    expect(request.status, 'accepted');
    discovery.expire(now.add(const Duration(seconds: 61)));
    expect(discovery.outgoingRequests, isEmpty);
  });

  test(
      'deduplicates device IDs, updates addresses, expires offline clients and bounds input',
      () async {
    final discovery = LanDiscovery();
    addTearDown(discovery.close);
    final now = DateTime.now();
    final id = generatePairingKey();
    final frame = <String, dynamic>{
      'op': 'client',
      'id': id,
      'name': '电脑 A',
      'platform': 'windows',
      'port': 24872,
      'busy': false
    };
    discovery.ingest(frame, '192.168.1.2', now);
    discovery.ingest({...frame, 'busy': true}, '192.168.1.3',
        now.add(const Duration(seconds: 1)));
    expect(discovery.devices.length, 1);
    expect(discovery.devices[id]!.host, '192.168.1.3');
    expect(discovery.devices[id]!.busy, isTrue);
    discovery.ingest({...frame, 'id': discovery.id}, '192.168.1.4', now);
    discovery.ingest(
        {...frame, 'id': generatePairingKey(), 'port': 0}, '192.168.1.4', now);
    discovery.ingest({...frame, 'id': generatePairingKey(), 'name': 'x' * 81},
        '192.168.1.4', now);
    expect(discovery.devices.length, 1);
    discovery.expire(now.add(const Duration(seconds: 9)));
    expect(discovery.devices, isEmpty);
    for (var i = 0; i < 300; i++) {
      discovery
          .ingest({...frame, 'id': generatePairingKey()}, '192.168.1.2', now);
    }
    expect(discovery.devices.length, 256);
  });
  test('two real multicast sockets discover both roles without sharing PINs',
      () async {
    final server = LanDiscovery(), client = LanDiscovery();
    addTearDown(server.close);
    addTearDown(client.close);
    server.advertisement = () => {
          'op': 'server',
          'name': 'host discovery test',
          'platform': 'test',
          'port': 24872,
          'busy': false,
        };
    client.advertisement = () => {
          'name': 'discovery test',
          'platform': 'test',
          'port': 24872,
          'busy': false
        };
    await server.start(port: 34873);
    await client.start(port: 34873);
    final end = DateTime.now().add(const Duration(seconds: 7));
    while ((!server.devices.containsKey(client.id) ||
            !client.devices.containsKey(server.id)) &&
        DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(server.devices[client.id]?.name, 'discovery test');
    expect(server.devices[client.id]?.port, 24872);
    expect(client.devices[server.id]?.isServer, isTrue);
  });
}
