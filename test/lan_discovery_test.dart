import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/secure_transport.dart';

void main() {
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
  test(
      'two real multicast sockets discover advertised clients without sharing keys',
      () async {
    final server = LanDiscovery(), client = LanDiscovery();
    addTearDown(server.close);
    addTearDown(client.close);
    client.advertisement = () => {
          'name': 'discovery test',
          'platform': 'test',
          'port': 24872,
          'busy': false
        };
    await server.start(port: 34873);
    await client.start(port: 34873);
    final end = DateTime.now().add(const Duration(seconds: 7));
    while (!server.devices.containsKey(client.id) &&
        DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(server.devices[client.id]?.name, 'discovery test');
    expect(server.devices[client.id]?.port, 24872);
  });
}
