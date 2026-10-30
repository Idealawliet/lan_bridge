import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// 默认监听端口；调用方可传入其他端口，测试使用 0 让系统分配。
const defaultSecurePort = 24872;
// 限制线上 JSON 帧大小，防止没有换行结束符的数据无限占用内存。
const maxSecureFrameBytes = 16384;
// 明文上限预留 Base64 膨胀、认证标签和 JSON 字段所需空间。
const _maxPlaintextBytes = 10240;
// 连接与握手各有截止时间，未认证连接不能一直占用资源。
const _handshakeTimeout = Duration(seconds: 5);
// 写入停滞超过此时长就断开，避免堆积已经过时的输入。
const _writeTimeout = Duration(seconds: 5);
// 序号保持在可精确表示的整数范围内，到达上限必须重建会话。
const _maxSequence = 0x1fffffffffffff;
// PIN 和握手随机数使用系统安全随机源。
final _random = Random.secure();
// HMAC 用来证明双方持有同一份派生凭据。
final _hmac = Hmac.sha256();
// AES-GCM 同时提供内容加密和帧完整性认证。
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
    // 采用单订阅流，确保同一条远程输入只交给一个消费者。
    _messages = StreamController<Map<String, dynamic>>(
      onListen: () {
        // 唤醒等待订阅者的读取循环；关闭时也需要唤醒，避免悬挂等待。
        if (!_consumerReady.isCompleted) _consumerReady.complete();
      },
      // 消费者暂停时建立等待信号，把背压传回套接字读取侧。
      onPause: () => _resume ??= Completer<void>(),
      onResume: () {
        // 解除暂停等待，使读取循环可以继续处理数据或退出。
        _resume?.complete();
        // 清除已经完成的等待信号，下一次暂停可以创建新信号。
        _resume = null;
      },
      // 消费者取消订阅代表不再处理输入，同时关闭对应会话。
      onCancel: close,
    );
    // 启动接收循环；错误由循环转发到消息流并执行关闭。
    unawaited(_read());
  }

  // 帧通道负责 TCP 分帧，当前类负责认证解密和消息生命周期。
  final _FrameChannel _channel;
  // 发送方向的会话密钥，不能与反方向共用 nonce 空间。
  final SecretKey _sendKey;
  // 接收方向的会话密钥，与发送方向分开派生。
  final SecretKey _receiveKey;
  // 通知监听器释放当前连接名额，不负责关闭其他会话。
  final void Function()? _onClosed;
  late final StreamController<Map<String, dynamic>> _messages;
  // 在业务订阅消息前暂停读取，避免积压尚无人消费的消息。
  final _consumerReady = Completer<void>();
  // 所有会话关闭请求等待同一个完成信号。
  final _done = Completer<void>();
  // 非空表示消息订阅者已暂停消费。
  Completer<void>? _resume;
  // 将并发 send 调用串成顺序链，保持输入事件的原始次序。
  Future<void> _sendTail = Future<void>.value();
  // 发送序号参与 nonce 和认证附加数据，每帧只能使用一次。
  int _sendSequence = 0;
  // 下一帧必须携带的序号；重复或跳号都拒绝处理。
  int _receiveSequence = 0;
  // 统计包含正在发送项在内的等待数量，用于限制背压。
  int _pendingSends = 0;
  bool _closed = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  String get remoteAddress => _channel.remoteAddress;
  Future<void> get done => _done.future;

  /// Serializes encryption and writes, retaining input ordering under load.
  /// A stalled peer is disconnected rather than accumulating old input forever.
  Future<void> send(Map<String, dynamic> message) {
    // 已关闭的会话立即返回失败，不能继续排队发送。
    if (_closed) return Future<void>.error(StateError('Session is closed'));
    // 先序列化为不可替换的字节快照，之后调用方修改 Map 不影响发送内容。
    late final List<int> clearText;
    try {
      // 在加入异步队列之前完成 JSON 编码并转换为 UTF-8。
      clearText = utf8.encode(jsonEncode(message));
      // 按字节数检查上限，不能使用字符数代替。
      if (clearText.length > _maxPlaintextBytes) {
        throw const FormatException('Input message is too large');
      }
    } catch (error, stack) {
      // 将编码或格式错误交给调用方，此时没有消耗任何发送序号。
      return Future<void>.error(error, stack);
    }
    // 远端跟不上输入时终止会话，避免无上限增加延迟和内存。
    if (_pendingSends >= 256) {
      // 触发连接清理，调用方仍会收到本次发送失败。
      unawaited(close());
      return Future<void>.error(StateError('Peer cannot keep up with input'));
    }
    // 先占用队列名额，避免同一轮并发调用突破上限。
    _pendingSends++;
    // 等待上一帧处理完再加密并写入当前帧。
    final result = _sendTail.then((_) async {
      try {
        // 排队期间可能已断线，真正执行前再次检查会话状态。
        if (_closed) throw StateError('Session is closed');
        // 禁止序号回绕，否则会重复使用同一密钥下的 nonce。
        if (_sendSequence > _maxSequence) {
          throw StateError('Session sequence exhausted');
        }
        // 为当前帧保留唯一序号，即使后续失败也不复用。
        final sequence = _sendSequence++;
        // 使用当前方向的密钥加密，并把序号纳入完整性认证。
        final box = await _cipher.encrypt(clearText,
            secretKey: _sendKey, nonce: _nonce(sequence), aad: _aad(sequence));
        // 将密文、认证标签和序号写成一个完整的线上帧。
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
        // 成功和失败都归还队列名额。
        _pendingSends--;
      }
    });
    // Keep the queue usable for cleanup; the caller still receives the error.
    _sendTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    // 返回当前调用自己的结果，保留错误给调用方处理。
    return result;
  }

  Future<void> _read() async {
    try {
      // 等待业务层订阅消息或请求关闭后再进入读取循环。
      await _consumerReady.future;
      // 每次循环只解密一帧，避免批量网络数据绕过背压。
      while (!_closed) {
        // 暂停期间等待消费者恢复；close 也会解除这个等待。
        if (_resume != null) await _resume!.future;
        // 异步等待之后重新检查关闭状态，不能继续取下一帧。
        if (_closed) break;
        // 从 TCP 字节流取出一个经过大小检查的 JSON 对象。
        final frame = await _channel.read();
        // 读取未可信的帧序号，下面先验证类型和预期值。
        final sequence = frame['seq'];
        // 协议版本、消息类型和序号必须全部匹配。
        if (frame['v'] != 1 ||
            frame['type'] != 'data' ||
            sequence is! int ||
            sequence != _receiveSequence ||
            sequence > _maxSequence) {
          throw const FormatException('Invalid or replayed encrypted frame');
        }
        // 解码密文并检查长度，避免无界解码结果进入加密库。
        final body = _decodeField(frame, 'body', maxLength: _maxPlaintextBytes);
        // GCM 认证标签固定为 16 字节，不接受截断标签。
        final tag = _decodeField(frame, 'tag', exactLength: 16);
        // 先验证认证标签再使用明文，篡改数据会在这里失败。
        final clearText = await _cipher.decrypt(
          SecretBox(body, nonce: _nonce(sequence), mac: Mac(tag)),
          secretKey: _receiveKey,
          aad: _aad(sequence),
        );
        // 仅对认证成功的明文进行 UTF-8 和 JSON 解码。
        final decoded = jsonDecode(utf8.decode(clearText));
        // 业务协议只接受对象，不允许数组或标量冒充消息。
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Input message must be an object');
        }
        // 完整验证成功后推进接收序号，防止同一帧再次生效。
        _receiveSequence++;
        // 解密等待期间可能断开；仅向仍然有效的会话投递。
        if (!_closed) _messages.add(decoded);
      }
    } on _PeerDisconnected {
      // EOF is an ordinary disconnect, while malformed/authentication failures
      // below are surfaced to the controller for its status display.
    } catch (error, stack) {
      // 将格式或认证错误交给控制器显示，主动关闭时不追加错误。
      if (!_closed) _messages.addError(error, stack);
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    // 重复关闭等待第一次清理完成，不启动第二次清理。
    if (_closed) return _done.future;
    // 在异步清理前标记关闭，阻止新增读写或握手。
    _closed = true;
    // 唤醒等待订阅者的读取循环；关闭时也需要唤醒，避免悬挂等待。
    if (!_consumerReady.isCompleted) _consumerReady.complete();
    // 解除暂停等待，使读取循环可以继续处理数据或退出。
    _resume?.complete();
    // 清除已经完成的等待信号，下一次暂停可以创建新信号。
    _resume = null;
    // 释放套接字与帧迭代器，让挂起的读取尽快结束。
    await _channel.close();
    // Closing an unlistened single-subscription stream must not block teardown.
    // 关闭业务消息流；未订阅或暂停的消费者不能阻塞资源清理。
    unawaited(_messages.close());
    // 通知监听器释放此会话占用的活动名额。
    _onClosed?.call();
    // 发布关闭完成信号，唤醒等待 done 或重复 close 的调用方。
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
    // 先验证六位 PIN，再创建监听或连接套接字。
    final secret = SecretKey(_decodePairingKey(pairingKey));
    // 申请独占监听端口，防止多个实例意外共用一个入口。
    final socket = await ServerSocket.bind(
        address ?? InternetAddress.anyIPv4, port,
        shared: false);
    // 封装监听套接字，随后接入的连接必须完成 PIN 握手。
    return SecureListener._(socket, secret);
  }

  final ServerSocket _server;
  final SecretKey _secret;
  final _peers = StreamController<SecurePeer>();
  // 保存尚未完成认证的通道，停止监听时统一清理。
  final _pending = <_FrameChannel>{};
  late final StreamSubscription<Socket> _subscription;
  // 一个监听器同时只允许一个已认证的控制方。
  SecurePeer? _active;
  // 记录最近一分钟的握手尝试，用于限制在线 PIN 猜测。
  final _attempts = <DateTime>[];
  // 认证成功到 ready 发送完成之间预留名额，阻止并发会话抢占。
  bool _reserved = false;
  bool _closed = false;

  Stream<SecurePeer> get peers => _peers.stream;
  int get port => _server.port;

  void _accept(Socket socket) {
    // 本次接入时间用于清理过期尝试并记录当前尝试。
    final now = DateTime.now();
    // PINs have a small search space. Bound both the attempt rate and the
    // number of in-flight handshakes; this is not a substitute for a strong PIN.
    // 移除一分钟窗口外的记录，避免限流状态无限累积。
    _attempts.removeWhere(
        (time) => now.difference(time) >= const Duration(minutes: 1));
    // 窗口内最多接受五次握手尝试，超限直接关闭新套接字。
    if (_attempts.length >= 5) {
      socket.destroy();
      return;
    }
    // 关闭中、已有控制方、名额已预留或待认证过多时拒绝接入。
    if (_closed || _active != null || _reserved || _pending.length >= 4) {
      socket.destroy();
      return;
    }
    // 只有真正进入握手阶段的连接才记入尝试次数。
    _attempts.add(now);
    // 将原始套接字包装为有长度限制的 JSON 帧通道。
    final channel = _FrameChannel(socket);
    // 先登记通道，再异步认证，确保停止监听能找到它。
    _pending.add(channel);
    // 并行处理有限数量的握手，不阻塞监听其他连接。
    unawaited(_authenticate(channel));
  }

  Future<void> _authenticate(_FrameChannel channel) async {
    // 仅创建预留名额的这一轮握手有权释放它。
    var ownsReservation = false;
    try {
      // 等待对端证明 PIN；证明通过后回调尝试预留活动名额。
      final keys = await _serverHandshake(channel, _secret, () {
        // 验证证明存在异步等待，因此预留前必须重新检查竞争状态。
        if (_closed || _active != null || _reserved) {
          throw StateError('A controller is already connected');
        }
        // Reserve after proof verification but before the final ready frame.
        // Competing authenticated handshakes cannot both become active.
        // 提前锁定唯一连接名额，阻止另一条已通过验证的握手成为活动会话。
        _reserved = true;
        // 记录预留所有权，finally 只释放当前握手创建的预留。
        ownsReservation = true;
      }).timeout(_handshakeTimeout);
      // 握手结束时监听器可能已经关闭，禁止再发布连接。
      if (_closed) throw StateError('Listener is closed');
      late final SecurePeer peer;
      peer = SecurePeer._(channel, keys.serverToClient, keys.clientToServer,
          onClosed: () {
        // 旧会话关闭时只能清除自己的引用，不能影响后来的会话。
        if (identical(_active, peer)) _active = null;
      });
      // 认证完成后登记当前活动会话。
      _active = peer;
      // Ownership transfers before notifying the caller. A caller may stop the
      // listening socket immediately without interrupting this accepted peer.
      // 从待认证集合移除；成功时所有权转交会话，失败时完成清理。
      _pending.remove(channel);
      // 向业务层发布经过认证的连接。
      _peers.add(peer);
    } catch (_) {
      await channel.close();
    } finally {
      // 从待认证集合移除；成功时所有权转交会话，失败时完成清理。
      _pending.remove(channel);
      // 成功和失败都解除当前握手的临时预留。
      if (ownsReservation) _reserved = false;
    }
  }

  /// Stops accepting connections and cancels pending handshakes. Accepted peers
  /// are owned by the caller and remain connected until [SecurePeer.close].
  Future<void> close() async {
    if (_closed) return;
    // 在异步清理前标记关闭，阻止新增读写或握手。
    _closed = true;
    // 停止接收新的套接字事件。
    await _subscription.cancel();
    // 释放本地监听端口。
    await _server.close();
    // 对待认证集合取快照后并行关闭，避免异步移除影响遍历。
    await Future.wait(_pending.toList().map((channel) => channel.close()));
    // 结束连接通知流，不等待业务层是否继续消费。
    unawaited(_peers.close());
  }
}

Future<SecurePeer> connectSecurePeer({
  required String host,
  required String pairingKey,
  int port = defaultSecurePort,
}) async {
  // 先验证六位 PIN，再创建监听或连接套接字。
  final secret = SecretKey(_decodePairingKey(pairingKey));
  final socket =
      await Socket.connect(host.trim(), port, timeout: _handshakeTimeout);
  // 将原始套接字包装为有长度限制的 JSON 帧通道。
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
  // 每次握手生成新的发起端随机数，避免跨会话复用证明。
  final clientNonce = _randomBytes(32);
  // 发送协议版本和本次随机数，不在网络上传输 PIN。
  await channel.write({'v': 1, 'type': 'hello', 'nonce': _encode(clientNonce)});
  // 等待监听端的随机数和身份凭据证明。
  final challenge = await channel.read();
  // 只接受当前握手步骤对应的帧类型。
  _expectHandshake(challenge, 'challenge');
  // 监听端随机数必须为完整的 32 字节。
  final serverNonce = _decodeField(challenge, 'nonce', exactLength: 32);
  // 按固定顺序组合双方随机数，使证明绑定当前握手。
  final transcript = _transcript(clientNonce, serverNonce);
  // 以 PIN 为输入、握手记录为盐执行 PBKDF2，提高凭据猜测成本。
  secret =
      await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256)
          .deriveKey(secretKey: secret, nonce: transcript);
  // 先验证监听端证明，再向其提供发起端证明。
  await _verifyProof(challenge, secret, transcript, 'server');
  await channel.write({
    'v': 1,
    'type': 'authenticate',
    'proof': await _proof(secret, transcript, 'client'),
  });
  // 等待监听端确认握手完成和连接名额已预留。
  final ready = await channel.read();
  // 拒绝跳步或协议不兼容的握手响应。
  _expectHandshake(ready, 'ready');
  // ready 本身也必须带有效证明，不能仅凭帧名称信任连接。
  await _verifyProof(ready, secret, transcript, 'ready');
  // 为两个通信方向分别派生密钥，握手凭据不直接作为通信密钥。
  return _deriveKeys(secret, transcript);
}

Future<_SessionKeys> _serverHandshake(
    _FrameChannel channel, SecretKey secret, void Function() reserve) async {
  // 监听端等待第一条握手帧。
  final hello = await channel.read();
  // 确认首帧版本和类型，拒绝其他消息进入认证流程。
  _expectHandshake(hello, 'hello');
  // 读取并检查发起端随机数的编码和固定长度。
  final clientNonce = _decodeField(hello, 'nonce', exactLength: 32);
  // 生成监听端本次随机数，保证双方都参与会话新鲜性。
  final serverNonce = _randomBytes(32);
  // 按固定顺序组合双方随机数，使证明绑定当前握手。
  final transcript = _transcript(clientNonce, serverNonce);
  // 以 PIN 为输入、握手记录为盐执行 PBKDF2，提高凭据猜测成本。
  secret =
      await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256)
          .deriveKey(secretKey: secret, nonce: transcript);
  await channel.write({
    'v': 1,
    'type': 'challenge',
    'nonce': _encode(serverNonce),
    'proof': await _proof(secret, transcript, 'server'),
  });
  // 等待发起端对当前握手给出凭据证明。
  final authenticate = await channel.read();
  // 验证步骤顺序，拒绝将其他帧作为身份认证。
  _expectHandshake(authenticate, 'authenticate');
  // 证明角色绑定为 client，不能拿监听端自己的证明反射回来。
  await _verifyProof(authenticate, secret, transcript, 'client');
  // 双方认证成功后预留连接名额，失败则不发送 ready。
  reserve();
  // 派生双方方向密钥，完成后才通知发起端可以传输业务数据。
  final keys = await _deriveKeys(secret, transcript);
  await channel.write({
    'v': 1,
    'type': 'ready',
    'proof': await _proof(secret, transcript, 'ready'),
  });
  // 将方向密钥交给 SecurePeer，后续每帧使用独立序号认证。
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
  // 证明长度必须与 SHA-256 的 32 字节输出一致。
  final received = _decodeField(frame, 'proof', exactLength: 32);
  // 根据本地凭据、握手记录和角色重新计算期望证明。
  final expected = base64Url
      .decode(base64Url.normalize(await _proof(key, transcript, role)));
  // Compare all bytes before deciding, rather than exiting at the first
  // mismatch. Each proof is also bound to its distinct role in the transcript.
  // 累积差异位，比较过程中不因首个不同字节提前退出。
  var difference = 0;
  // 遍历完整证明，避免显式暴露首个不匹配的位置。
  for (var index = 0; index < expected.length; index++) {
    // 相等字节异或为零，任意差异都会保留到最终结果。
    difference |= expected[index] ^ received[index];
  }
  // 所有字节比较完成后统一判断认证结果。
  if (difference != 0) {
    throw const FormatException('PIN 码不正确，请核对客户端显示的 6 位数字');
  }
}

Future<_SessionKeys> _deriveKeys(SecretKey secret, List<int> transcript) async {
  // Separate directional keys allow each peer to start its nonce counter at
  // zero without reusing an AES-GCM nonce under the same key.
  // 为 AES-256 派生 32 字节密钥。
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  // 以 client-to-server 标签隔离发起端到监听端方向。
  final client = await hkdf.deriveKey(
      secretKey: secret,
      nonce: transcript,
      info: utf8.encode('lan-bridge/1/client-to-server'));
  // 以不同标签隔离反方向，允许两边序号各自从零开始。
  final server = await hkdf.deriveKey(
      secretKey: secret,
      nonce: transcript,
      info: utf8.encode('lan-bridge/1/server-to-client'));
  // 按固定方向顺序封装密钥，建立会话时再映射到本端收发。
  return _SessionKeys(client, server);
}

Uint8List _nonce(int sequence) {
  // GCM nonce 为 12 字节，前四字节保持零。
  final bytes = Uint8List(12);
  // 后八字节以大端序编码单调序号，同一方向密钥下不能重复。
  ByteData.sublistView(bytes).setUint64(4, sequence, Endian.big);
  return bytes;
}

List<int> _aad(int sequence) => utf8.encode('lan-bridge/1/data/$sequence');
List<int> _randomBytes(int count) =>
    List<int>.generate(count, (_) => _random.nextInt(256));
String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _decodePairingKey(String value) {
  // 允许用户粘贴时带首尾空白，但中间字符仍必须是六位数字。
  final pin = value.trim();
  if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
    throw const FormatException('请输入 6 位数字 PIN 码');
  }
  // 按字符编码保留前导零，例如 001234 与 1234 不等价。
  return utf8.encode(pin);
}

List<int> _decodeField(Map<String, dynamic> frame, String name,
    {int? exactLength, int maxLength = maxSecureFrameBytes}) {
  // 线上字段视为不可信输入，先验证类型再解码。
  final value = frame[name];
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
    throw FormatException('Invalid $name encoding');
  }
  // 恢复省略的填充字符后解码 URL 安全 Base64。
  final bytes = base64Url.decode(base64Url.normalize(value));
  // 同时检查最大长度和协议要求的固定长度。
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
    // 关闭 Nagle 合并，减少键鼠小包等待导致的交互延迟。
    socket.setOption(SocketOption.tcpNoDelay, true);
    // 以按需迭代方式读取帧，暂停消费时保留套接字背压。
    _frames = StreamIterator(_decodeFrames(socket));
  }

  final Socket socket;
  final String remoteAddress;
  late final StreamIterator<Map<String, dynamic>> _frames;
  bool _closed = false;

  Future<Map<String, dynamic>> read() async {
    // 已关闭或收到 EOF 都作为正常断开信号处理。
    if (_closed || !await _frames.moveNext()) throw const _PeerDisconnected();
    // 每次 read 只交出一帧，保持消息处理顺序。
    return _frames.current;
  }

  Future<void> write(Map<String, dynamic> frame) async {
    // 不能向已关闭的通道继续写入。
    if (_closed) throw const _PeerDisconnected();
    // 线上帧统一编码为 UTF-8 JSON。
    final bytes = utf8.encode(jsonEncode(frame));
    // 加密和 Base64 编码后的最终帧仍需满足线上长度上限。
    if (bytes.length > maxSecureFrameBytes) {
      throw const FormatException('Wire frame is too large');
    }
    // 追加换行字节作为帧边界；JSON 字符串内换行已被转义。
    socket.add([...bytes, 10]);
    // 等待输出缓冲提交，超时由上层关闭会话；这不是对端确认。
    await socket.flush().timeout(_writeTimeout);
  }

  Future<void> close() async {
    if (_closed) return;
    // 在异步清理前标记关闭，阻止新增读写或握手。
    _closed = true;
    socket.destroy();
    // 取消帧迭代，释放其底层套接字订阅。
    await _frames.cancel();
  }
}

/// An async generator preserves socket backpressure even when a single network
/// packet contains many frames. No unbounded line decoder or frame queue exists.
Stream<Map<String, dynamic>> _decodeFrames(Socket socket) async* {
  // 仅保存当前尚未完整到达的一帧。
  var pending = <int>[];
  // TCP 的块边界与协议帧边界无关，需要逐字节寻找分隔符。
  await for (final chunk in socket) {
    // 一个网络块可能包含多帧，也可能只包含半帧。
    for (final byte in chunk) {
      // 遇到换行意味着当前帧完整，开始验证和解码。
      if (byte == 10) {
        // 拒绝空帧，防止空消息进入上层协议。
        if (pending.isEmpty) throw const FormatException('Empty wire frame');
        // 在完整帧上解码，避免把跨网络块的 UTF-8 字符误判为损坏。
        final decoded = jsonDecode(utf8.decode(pending));
        // 及时丢弃上一帧缓冲，开始接收下一帧。
        pending = <int>[];
        // 业务协议只接受对象，不允许数组或标量冒充消息。
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Wire frame must be an object');
        }
        // 等待下游请求下一帧再继续，避免一次网络读取生成无界消息队列。
        yield decoded;
      } else {
        // 即使对端不发送换行，也在达到上限时主动拒绝。
        if (pending.length >= maxSecureFrameBytes) {
          throw const FormatException('Wire frame limit exceeded');
        }
        // 只将当前帧内容加入有界缓冲区。
        pending.add(byte);
      }
    }
  }
  // EOF 前还有未结束的数据说明帧被截断，不能视为完整消息。
  if (pending.isNotEmpty) throw const FormatException('Truncated wire frame');
}
