import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lan_bridge/core/secure_transport.dart';

void main() {
  test('pairing secrets contain 256 bits and are freshly generated', () {
    final first = generatePairingKey();
    final second = generatePairingKey();
    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(base64Url.decode(base64Url.normalize(first)), hasLength(32));
    expect(second, isNot(first));
  });

  test('rejects malformed keys before opening a listener or connecting',
      () async {
    await expectLater(SecureListener.bind(pairingKey: '123456', port: 0),
        throwsA(isA<FormatException>()));
    await expectLater(
        connectSecurePeer(host: '127.0.0.1', pairingKey: '123456'),
        throwsA(isA<FormatException>()));
  });

  test('authenticates, encrypts both directions, and preserves queued ordering',
      () async {
    final pair = await _Pair.open();
    addTearDown(pair.close);
    final atServer = StreamIterator(pair.server.messages);
    final atClient = StreamIterator(pair.client.messages);
    addTearDown(atServer.cancel);
    addTearDown(atClient.cancel);

    // First messages are retained even when sent before the consumer subscribes.
    await pair.client.send({'type': 'key', 'usage': 4, 'down': true});
    expect(await atServer.moveNext(), isTrue);
    expect(atServer.current, {'type': 'key', 'usage': 4, 'down': true});
    await pair.server.send({'type': 'return', 'y': 0.5});
    expect(await atClient.moveNext(), isTrue);
    expect(atClient.current, {'type': 'return', 'y': 0.5});

    await Future.wait(
        List.generate(64, (index) => pair.client.send({'index': index})));
    for (var index = 0; index < 64; index++) {
      expect(await atServer.moveNext(), isTrue);
      expect(atServer.current['index'], index);
    }
  });

  test('an accepted peer survives closing its listener', () async {
    final pair = await _Pair.open();
    addTearDown(pair.close);
    await pair.listener.close();
    final message = pair.server.messages.first;
    await pair.client.send({'type': 'ping'});
    expect(await message, {'type': 'ping'});
  });

  test('wrong pairing key cannot create an authenticated peer', () async {
    final listener = await SecureListener.bind(
        pairingKey: generatePairingKey(),
        port: 0,
        address: InternetAddress.loopbackIPv4);
    addTearDown(listener.close);
    final accepted = <SecurePeer>[];
    final subscription = listener.peers.listen(accepted.add);
    addTearDown(subscription.cancel);
    await expectLater(
        connectSecurePeer(
            host: '127.0.0.1',
            port: listener.port,
            pairingKey: generatePairingKey()),
        throwsA(isA<FormatException>()));
    expect(accepted, isEmpty);
  });

  test(
      'a second authenticated controller is refused without disturbing the first',
      () async {
    final pair = await _Pair.open();
    addTearDown(pair.close);
    await expectLater(
        connectSecurePeer(
            host: '127.0.0.1', port: pair.listener.port, pairingKey: pair.key),
        throwsA(anything));
    final message = pair.server.messages.first;
    await pair.client.send({'stillConnected': true});
    expect(await message, {'stillConnected': true});
  });

  test('oversized unauthenticated frame is dropped without a trailing newline',
      () async {
    final listener = await SecureListener.bind(
        pairingKey: generatePairingKey(),
        port: 0,
        address: InternetAddress.loopbackIPv4);
    addTearDown(listener.close);
    final socket = await Socket.connect('127.0.0.1', listener.port);
    addTearDown(socket.destroy);
    final closed = socket.drain<void>();
    socket.add(List.filled(maxSecureFrameBytes + 1, 65));
    await closed.timeout(const Duration(seconds: 2));
  });

  test('idle unauthenticated sockets are closed after the handshake deadline',
      () async {
    final listener = await SecureListener.bind(
        pairingKey: generatePairingKey(),
        port: 0,
        address: InternetAddress.loopbackIPv4);
    addTearDown(listener.close);
    final socket = await Socket.connect('127.0.0.1', listener.port);
    addTearDown(socket.destroy);
    await socket.drain<void>().timeout(const Duration(seconds: 7));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'encrypted packet contains no plaintext and authentication rejects tampering',
      () async {
    final proxy = await _Proxy.open(tamper: true);
    addTearDown(proxy.close);
    final server = await proxy.server;
    final received = StreamIterator(server.messages);
    addTearDown(received.cancel);
    final rejected = expectLater(received.moveNext(), throwsA(anything));
    await proxy.client.send({'text': 'sensitive-keystroke-sample'});
    await rejected;
    expect(proxy.dataFrames, hasLength(1));
    expect(
        proxy.dataFrames.single, isNot(contains('sensitive-keystroke-sample')));
    await server.done;
  });

  test('replayed encrypted frame is rejected before delivering input twice',
      () async {
    final proxy = await _Proxy.open(replay: true);
    addTearDown(proxy.close);
    final server = await proxy.server;
    final received = StreamIterator(server.messages);
    addTearDown(received.cancel);
    await proxy.client.send({'type': 'button', 'button': 1, 'down': true});
    expect(await received.moveNext(), isTrue);
    expect(received.current['type'], 'button');
    await expectLater(received.moveNext(), throwsA(isA<FormatException>()));
    await server.done;
  });
}

class _Pair {
  _Pair(this.key, this.listener, this.client, this.server);
  final String key;
  final SecureListener listener;
  final SecurePeer client;
  final SecurePeer server;

  static Future<_Pair> open() async {
    final key = generatePairingKey();
    final listener = await SecureListener.bind(
        pairingKey: key, port: 0, address: InternetAddress.loopbackIPv4);
    final accepted = listener.peers.first;
    final client = await connectSecurePeer(
        host: '127.0.0.1', pairingKey: key, port: listener.port);
    return _Pair(key, listener, client, await accepted);
  }

  Future<void> close() async {
    await client.close();
    await server.close();
    await listener.close();
  }
}

/// A byte-stream relay with no session keys. It alters/replays only encrypted
/// envelopes to verify authenticated encryption and receive sequence checks.
class _Proxy {
  _Proxy(this.listener, this.relay, this.server, this.tamper, this.replay);
  final SecureListener listener;
  final ServerSocket relay;
  final Future<SecurePeer> server;
  final bool tamper;
  final bool replay;
  final sockets = <Socket>[];
  final dataFrames = <String>[];
  late SecurePeer client;

  static Future<_Proxy> open({bool tamper = false, bool replay = false}) async {
    final key = generatePairingKey();
    final listener = await SecureListener.bind(
        pairingKey: key, port: 0, address: InternetAddress.loopbackIPv4);
    final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _Proxy(listener, relay, listener.peers.first, tamper, replay);
    relay.listen((socket) => unawaited(proxy._forward(socket)));
    proxy.client = await connectSecurePeer(
        host: '127.0.0.1', pairingKey: key, port: relay.port);
    return proxy;
  }

  Future<void> _forward(Socket incoming) async {
    sockets.add(incoming);
    final outgoing = await Socket.connect('127.0.0.1', listener.port);
    sockets.add(outgoing);
    outgoing.listen(incoming.add,
        onDone: incoming.destroy, onError: (Object _) => incoming.destroy());
    incoming
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final packet = jsonDecode(line) as Map<String, dynamic>;
      if (packet['type'] == 'data') {
        dataFrames.add(line);
        if (tamper) {
          packet['tag'] =
              base64Url.encode(List.filled(16, 0)).replaceAll('=', '');
          outgoing.add(utf8.encode('${jsonEncode(packet)}\n'));
          return;
        }
      }
      outgoing.add(utf8.encode('$line\n'));
      if (replay && packet['type'] == 'data') {
        outgoing.add(utf8.encode('$line\n'));
      }
    }, onDone: outgoing.destroy, onError: (Object _) => outgoing.destroy());
  }

  Future<void> close() async {
    await client.close();
    await (await server).close();
    for (final socket in sockets) {
      socket.destroy();
    }
    await relay.close();
    await listener.close();
  }
}
