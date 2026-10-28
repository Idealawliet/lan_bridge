import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const defaultSecurePort = 24872;
const maxSecureFrameBytes = 16384;
const _maxPlaintextBytes = 10240;
const _handshakeTimeout = Duration(seconds: 5);
const _writeTimeout = Duration(seconds: 5);
const _maxSequence = 0x1fffffffffffff;
final _random = Random.secure();
final _hmac = Hmac.sha256();
final _cipher = AesGcm.with256bits();

/// Random discovery identifier; never use this value as a pairing credential.
String generatePairingKey() => _encode(_randomBytes(32));

/// A fresh six-digit pairing PIN, including leading zeroes.
String generatePairingPin() =>
    _random.nextInt(1000000).toString().padLeft(6, '0');

/// One authenticated, encrypted TCP session. Messages have exactly one listener.
/// Input is never written to the socket until both peers prove the pairing key.
class SecurePeer {
  SecurePeer._(this._channel, this._sendKey, this._receiveKey,
      {void Function()? onClosed})
      : _onClosed = onClosed {
    _messages = StreamController<Map<String, dynamic>>(
      onListen: () {
        if (!_consumerReady.isCompleted) _consumerReady.complete();
      },
      onPause: () => _resume ??= Completer<void>(),
      onResume: () {
        _resume?.complete();
        _resume = null;
      },
      onCancel: close,
    );
    unawaited(_read());
  }

  final _FrameChannel _channel;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final void Function()? _onClosed;
  late final StreamController<Map<String, dynamic>> _messages;
  final _consumerReady = Completer<void>();
  final _done = Completer<void>();
  Completer<void>? _resume;
  Future<void> _sendTail = Future<void>.value();
  int _sendSequence = 0;
  int _receiveSequence = 0;
  int _pendingSends = 0;
  bool _closed = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  String get remoteAddress => _channel.remoteAddress;
  Future<void> get done => _done.future;

  /// Serializes encryption and writes, retaining input ordering under load.
  /// A stalled peer is disconnected rather than accumulating old input forever.
  Future<void> send(Map<String, dynamic> message) {
    if (_closed) return Future<void>.error(StateError('Session is closed'));
    late final List<int> clearText;
    try {
      clearText = utf8.encode(jsonEncode(message));
      if (clearText.length > _maxPlaintextBytes) {
        throw const FormatException('Input message is too large');
      }
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    if (_pendingSends >= 256) {
      unawaited(close());
      return Future<void>.error(StateError('Peer cannot keep up with input'));
    }
    _pendingSends++;
    final result = _sendTail.then((_) async {
      try {
        if (_closed) throw StateError('Session is closed');
        if (_sendSequence > _maxSequence) {
          throw StateError('Session sequence exhausted');
        }
        final sequence = _sendSequence++;
        final box = await _cipher.encrypt(clearText,
            secretKey: _sendKey, nonce: _nonce(sequence), aad: _aad(sequence));
        await _channel.write({
          'v': 1,
          'type': 'data',
          'seq': sequence,
          'body': _encode(box.cipherText),
          'tag': _encode(box.mac.bytes),
        });
      } catch (_) {
        await close();
        rethrow;
      } finally {
        _pendingSends--;
      }
    });
    // Keep the queue usable for cleanup; the caller still receives the error.
    _sendTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _read() async {
    try {
      await _consumerReady.future;
      while (!_closed) {
        if (_resume != null) await _resume!.future;
        if (_closed) break;
        final frame = await _channel.read();
        final sequence = frame['seq'];
        if (frame['v'] != 1 ||
            frame['type'] != 'data' ||
            sequence is! int ||
            sequence != _receiveSequence ||
            sequence > _maxSequence) {
          throw const FormatException('Invalid or replayed encrypted frame');
        }
        final body = _decodeField(frame, 'body', maxLength: _maxPlaintextBytes);
        final tag = _decodeField(frame, 'tag', exactLength: 16);
        final clearText = await _cipher.decrypt(
          SecretBox(body, nonce: _nonce(sequence), mac: Mac(tag)),
          secretKey: _receiveKey,
          aad: _aad(sequence),
        );
        final decoded = jsonDecode(utf8.decode(clearText));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Input message must be an object');
        }
        _receiveSequence++;
        if (!_closed) _messages.add(decoded);
      }
    } on _PeerDisconnected {
      // EOF is an ordinary disconnect, while malformed/authentication failures
      // below are surfaced to the controller for its status display.
    } catch (error, stack) {
      if (!_closed) _messages.addError(error, stack);
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return _done.future;
    _closed = true;
    if (!_consumerReady.isCompleted) _consumerReady.complete();
    _resume?.complete();
    _resume = null;
    await _channel.close();
    // Closing an unlistened single-subscription stream must not block teardown.
    unawaited(_messages.close());
    _onClosed?.call();
    _done.complete();
  }
}

/// An IPv4 LAN listener with at most one authenticated peer and four handshakes.
/// Failed unauthenticated connections are dropped without exposing the secret.
class SecureListener {
  SecureListener._(this._server, this._secret) {
    _subscription =
        _server.listen(_accept, onError: (Object error, StackTrace stack) {
      if (!_closed) _peers.addError(error, stack);
    });
  }

  static Future<SecureListener> bind({
    required String pairingKey,
    int port = defaultSecurePort,
    InternetAddress? address,
  }) async {
    final secret = SecretKey(_decodePairingKey(pairingKey));
    final socket = await ServerSocket.bind(
        address ?? InternetAddress.anyIPv4, port,
        shared: false);
    return SecureListener._(socket, secret);
  }

  final ServerSocket _server;
  final SecretKey _secret;
  final _peers = StreamController<SecurePeer>();
  final _pending = <_FrameChannel>{};
  late final StreamSubscription<Socket> _subscription;
  SecurePeer? _active;
  final _attempts = <DateTime>[];
  bool _reserved = false;
  bool _closed = false;

  Stream<SecurePeer> get peers => _peers.stream;
  int get port => _server.port;

  void _accept(Socket socket) {
    final now = DateTime.now();
    // PINs have a small search space. Bound both the attempt rate and the
    // number of in-flight handshakes; this is not a substitute for a strong PIN.
    _attempts.removeWhere(
        (time) => now.difference(time) >= const Duration(minutes: 1));
    if (_attempts.length >= 5) {
      socket.destroy();
      return;
    }
    if (_closed || _active != null || _reserved || _pending.length >= 4) {
      socket.destroy();
      return;
    }
    _attempts.add(now);
    final channel = _FrameChannel(socket);
    _pending.add(channel);
    unawaited(_authenticate(channel));
  }

  Future<void> _authenticate(_FrameChannel channel) async {
    var ownsReservation = false;
    try {
      final keys = await _serverHandshake(channel, _secret, () {
        if (_closed || _active != null || _reserved) {
          throw StateError('A controller is already connected');
        }
        // Reserve after proof verification but before the final ready frame.
        // Competing authenticated handshakes cannot both become active.
        _reserved = true;
        ownsReservation = true;
      }).timeout(_handshakeTimeout);
      if (_closed) throw StateError('Listener is closed');
      late final SecurePeer peer;
      peer = SecurePeer._(channel, keys.serverToClient, keys.clientToServer,
          onClosed: () {
        if (identical(_active, peer)) _active = null;
      });
      _active = peer;
      // Ownership transfers before notifying the caller. A caller may stop the
      // listening socket immediately without interrupting this accepted peer.
      _pending.remove(channel);
      _peers.add(peer);
    } catch (_) {
      await channel.close();
    } finally {
      _pending.remove(channel);
      if (ownsReservation) _reserved = false;
    }
  }

  /// Stops accepting connections and cancels pending handshakes. Accepted peers
  /// are owned by the caller and remain connected until [SecurePeer.close].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close();
    await Future.wait(_pending.toList().map((channel) => channel.close()));
    unawaited(_peers.close());
  }
}

Future<SecurePeer> connectSecurePeer({
  required String host,
  required String pairingKey,
  int port = defaultSecurePort,
}) async {
  final secret = SecretKey(_decodePairingKey(pairingKey));
  final socket =
      await Socket.connect(host.trim(), port, timeout: _handshakeTimeout);
  final channel = _FrameChannel(socket);
  try {
    final keys =
        await _clientHandshake(channel, secret).timeout(_handshakeTimeout);
    return SecurePeer._(channel, keys.clientToServer, keys.serverToClient);
  } catch (_) {
    await channel.close();
    rethrow;
  }
}

class _SessionKeys {
  const _SessionKeys(this.clientToServer, this.serverToClient);
  final SecretKey clientToServer;
  final SecretKey serverToClient;
}

Future<_SessionKeys> _clientHandshake(
    _FrameChannel channel, SecretKey secret) async {
  // Both peers contribute fresh nonces. The transcript binds the proofs and
  // derived traffic keys to this handshake rather than reusing them per PIN.
  final clientNonce = _randomBytes(32);
  await channel.write({'v': 1, 'type': 'hello', 'nonce': _encode(clientNonce)});
  final challenge = await channel.read();
  _expectHandshake(challenge, 'challenge');
  final serverNonce = _decodeField(challenge, 'nonce', exactLength: 32);
  final transcript = _transcript(clientNonce, serverNonce);
  secret =
      await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256)
          .deriveKey(secretKey: secret, nonce: transcript);
  await _verifyProof(challenge, secret, transcript, 'server');
  await channel.write({
    'v': 1,
    'type': 'authenticate',
    'proof': await _proof(secret, transcript, 'client'),
  });
  final ready = await channel.read();
  _expectHandshake(ready, 'ready');
  await _verifyProof(ready, secret, transcript, 'ready');
  return _deriveKeys(secret, transcript);
}

Future<_SessionKeys> _serverHandshake(
    _FrameChannel channel, SecretKey secret, void Function() reserve) async {
  final hello = await channel.read();
  _expectHandshake(hello, 'hello');
  final clientNonce = _decodeField(hello, 'nonce', exactLength: 32);
  final serverNonce = _randomBytes(32);
  final transcript = _transcript(clientNonce, serverNonce);
  secret =
      await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256)
          .deriveKey(secretKey: secret, nonce: transcript);
  await channel.write({
    'v': 1,
    'type': 'challenge',
    'nonce': _encode(serverNonce),
    'proof': await _proof(secret, transcript, 'server'),
  });
  final authenticate = await channel.read();
  _expectHandshake(authenticate, 'authenticate');
  await _verifyProof(authenticate, secret, transcript, 'client');
  reserve();
  final keys = await _deriveKeys(secret, transcript);
  await channel.write({
    'v': 1,
    'type': 'ready',
    'proof': await _proof(secret, transcript, 'ready'),
  });
  return keys;
}

void _expectHandshake(Map<String, dynamic> frame, String type) {
  if (frame['v'] != 1 || frame['type'] != type) {
    throw const FormatException('Unsupported handshake');
  }
}

List<int> _transcript(List<int> client, List<int> server) =>
    [...utf8.encode('lan-bridge/1\u0000'), ...client, ...server];

Future<String> _proof(SecretKey key, List<int> transcript, String role) async =>
    _encode((await _hmac.calculateMac([...transcript, ...utf8.encode(role)],
            secretKey: key))
        .bytes);

Future<void> _verifyProof(Map<String, dynamic> frame, SecretKey key,
    List<int> transcript, String role) async {
  final received = _decodeField(frame, 'proof', exactLength: 32);
  final expected = base64Url
      .decode(base64Url.normalize(await _proof(key, transcript, role)));
  // Compare all bytes before deciding, rather than exiting at the first
  // mismatch. Each proof is also bound to its distinct role in the transcript.
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= expected[index] ^ received[index];
  }
  if (difference != 0) {
    throw const FormatException('PIN 码不正确，请核对客户端显示的 6 位数字');
  }
}

Future<_SessionKeys> _deriveKeys(SecretKey secret, List<int> transcript) async {
  // Separate directional keys allow each peer to start its nonce counter at
  // zero without reusing an AES-GCM nonce under the same key.
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final client = await hkdf.deriveKey(
      secretKey: secret,
      nonce: transcript,
      info: utf8.encode('lan-bridge/1/client-to-server'));
  final server = await hkdf.deriveKey(
      secretKey: secret,
      nonce: transcript,
      info: utf8.encode('lan-bridge/1/server-to-client'));
  return _SessionKeys(client, server);
}

Uint8List _nonce(int sequence) {
  final bytes = Uint8List(12);
  ByteData.sublistView(bytes).setUint64(4, sequence, Endian.big);
  return bytes;
}

List<int> _aad(int sequence) => utf8.encode('lan-bridge/1/data/$sequence');
List<int> _randomBytes(int count) =>
    List<int>.generate(count, (_) => _random.nextInt(256));
String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _decodePairingKey(String value) {
  final pin = value.trim();
  if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
    throw const FormatException('请输入 6 位数字 PIN 码');
  }
  return utf8.encode(pin);
}

List<int> _decodeField(Map<String, dynamic> frame, String name,
    {int? exactLength, int maxLength = maxSecureFrameBytes}) {
  final value = frame[name];
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
    throw FormatException('Invalid $name encoding');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (bytes.length > maxLength ||
      (exactLength != null && bytes.length != exactLength)) {
    throw FormatException('Invalid $name length');
  }
  return bytes;
}

class _PeerDisconnected implements Exception {
  const _PeerDisconnected();
}

class _FrameChannel {
  _FrameChannel(this.socket) : remoteAddress = socket.remoteAddress.address {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _frames = StreamIterator(_decodeFrames(socket));
  }

  final Socket socket;
  final String remoteAddress;
  late final StreamIterator<Map<String, dynamic>> _frames;
  bool _closed = false;

  Future<Map<String, dynamic>> read() async {
    if (_closed || !await _frames.moveNext()) throw const _PeerDisconnected();
    return _frames.current;
  }

  Future<void> write(Map<String, dynamic> frame) async {
    if (_closed) throw const _PeerDisconnected();
    final bytes = utf8.encode(jsonEncode(frame));
    if (bytes.length > maxSecureFrameBytes) {
      throw const FormatException('Wire frame is too large');
    }
    socket.add([...bytes, 10]);
    await socket.flush().timeout(_writeTimeout);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    socket.destroy();
    await _frames.cancel();
  }
}

/// An async generator preserves socket backpressure even when a single network
/// packet contains many frames. No unbounded line decoder or frame queue exists.
Stream<Map<String, dynamic>> _decodeFrames(Socket socket) async* {
  var pending = <int>[];
  await for (final chunk in socket) {
    for (final byte in chunk) {
      if (byte == 10) {
        if (pending.isEmpty) throw const FormatException('Empty wire frame');
        final decoded = jsonDecode(utf8.decode(pending));
        pending = <int>[];
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Wire frame must be an object');
        }
        yield decoded;
      } else {
        if (pending.length >= maxSecureFrameBytes) {
          throw const FormatException('Wire frame limit exceeded');
        }
        pending.add(byte);
      }
    }
  }
  if (pending.isNotEmpty) throw const FormatException('Truncated wire frame');
}
