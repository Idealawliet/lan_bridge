import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const transferChunkSize = 6144;
const maxTransferEntries = 10000;
const maxTransferBytes = 100 * 1024 * 1024 * 1024;
typedef SendFrame = Future<void> Function(Map<String, dynamic> message);

class TransferRecord {
  TransferRecord(this.id, this.name, this.bytes, this.outgoing, this.drag,
      this.result, this.time);
  final String id, name;
  final int? bytes;
  final bool outgoing, drag;
  String result;
  final DateTime time;
}

class TransferOffer {
  TransferOffer(this.id, this.name, this.count, this.bytes, this.drag, this.y,
      {this.clipboard = false});
  final String id, name;
  final int count, bytes;
  final bool drag, clipboard;
  final double y;
}

class _Entry {
  _Entry(this.local, this.relative, this.directory, this.size);
  final String local, relative;
  final bool directory;
  final int size;
}

/// Chunk acknowledgements bound disk/network backpressure. Files are never
/// exposed as completed until the manifest, lengths and SHA-256 hashes agree.
class FileTransfer extends ChangeNotifier {
  FileTransfer(
      {required this.send,
      required this.receiveDirectory,
      this.onDragReceived,
      this.onClipboardOffered,
      this.onClipboardReceived});
  final SendFrame send;
  final Future<Directory> Function() receiveDirectory;
  final Future<void> Function(List<String> paths, double y)? onDragReceived;
  final Future<bool> Function()? onClipboardOffered;
  final Future<void> Function(List<String> paths)? onClipboardReceived;
  TransferOffer? offer;
  String status = '将文件或文件夹拖入，发送到另一台电脑';
  String? lastDirectory;
  String? sendingName;
  final List<TransferRecord> history = [];
  String? _outgoingDragId, _incomingDragId;
  void _record(String id, String name, int? bytes, bool outgoing, bool drag,
      String result) {
    final existing = history.where((record) => record.id == id).firstOrNull;
    if (existing != null) {
      existing.result = result;
    } else {
      history.insert(0, TransferRecord(id, name, bytes, outgoing, drag, result, DateTime.now()));
      if (history.length > 50) history.removeLast();
    }
    _notify();
  }

  void dragFinished({required bool cancelled, bool outgoing = false, String? reason}) {
    final id = outgoing ? _outgoingDragId : _incomingDragId;
    if (id == null) return;
    for (final record in history) {
      if (record.id == id) {
        record.result = reason != null ? '拖放失败：$reason；已接收的副本保留在下载目录'
            : cancelled ? '拖放已取消，已接收的副本保留在下载目录' : '系统拖放已完成';
        break;
      }
    }
    if (outgoing) {
      _outgoingDragId = null;
    } else {
      _incomingDragId = null;
    }
    _notify();
  }
  int sentBytes = 0, receivedBytes = 0, sendTotal = 0, receiveTotal = 0;
  final Stopwatch _sendClock = Stopwatch(), _receiveClock = Stopwatch();
  double get sendBytesPerSecond => _rate(sentBytes, _sendClock);
  double get receiveBytesPerSecond => _rate(receivedBytes, _receiveClock);
  static double _rate(int bytes, Stopwatch clock) =>
      clock.elapsedMilliseconds == 0 ? 0 : bytes * 1000 / clock.elapsedMilliseconds;
  bool sending = false, receiving = false, _closed = false;
  String? _outId;
  Completer<Map<String, dynamic>>? _reply;
  Directory? _staging;
  RandomAccessFile? _file;
  _HashSink? _hashResult;
  ByteConversionSink? _hash;
  int _fileSize = 0, _fileOffset = 0, _entryCount = 0, _declaredBytes = 0;
  final Set<String> _paths = {}, _directories = {}, _roots = {};
  int _sequence = 0;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  void _notify({bool force = true}) {
    if (_closed) return;
    if (force ||
        DateTime.now().difference(_lastProgress).inMilliseconds > 100) {
      _lastProgress = DateTime.now();
      notifyListeners();
    }
  }

  Future<void> _emit(String op, String id,
          [Map<String, dynamic> fields = const {}]) =>
      send({'type': 'share', 'op': op, 'id': id, ...fields});

  Future<void> sendPaths(List<String> paths,
      {bool drag = false, bool clipboard = false, double y = .5}) async {
    if (_closed || sending) throw StateError('已有发送任务');
    sending = true;
    final names = paths.map((path) => p.basename(p.normalize(path))).join('、');
    sendingName = names.length > 1024 ? '${names.substring(0, 1020)}…' : names;
    sentBytes = 0;
    _sendClock.reset();
    sendTotal = 0;
    final id = List.generate(
            16,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    _outId = id;
    var manifestReady = false;
    status = '正在读取文件清单';
    _notify();
    try {
      final entries = <_Entry>[];
      final names = <String>{};
      Future<void> scan(String local, String relative) async {
        if (_closed || _outId != id) throw StateError('传输已取消');
        validateTransferPath(relative);
        if (!names.add(relative.toLowerCase())) {
          throw FileSystemException('文件名在另一系统中冲突', relative);
        }
        if (entries.length >= maxTransferEntries) {
          throw StateError('每次最多传输 $maxTransferEntries 个条目');
        }
        final type = await FileSystemEntity.type(local, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          entries.add(_Entry(local, relative, true, 0));
          await for (final child in Directory(local).list(followLinks: false)) {
            await scan(child.path, '$relative/${p.basename(child.path)}');
          }
        } else if (type == FileSystemEntityType.file) {
          final size = await File(local).length();
          sendTotal += size;
          if (sendTotal > maxTransferBytes) {
            throw StateError('单次传输不能超过 100 GiB');
          }
          entries.add(_Entry(local, relative, false, size));
        } else {
          throw FileSystemException('不传输符号链接或特殊文件', local);
        }
      }

      for (final path in paths) {
        await scan(p.normalize(path), p.basename(p.normalize(path)));
      }
      if (entries.isEmpty) throw StateError('没有可发送的文件');
      manifestReady = true;
      status = drag
          ? '跨屏拖放：正在传输，请保持按住鼠标'
          : clipboard
              ? '正在同步剪贴板原始文件'
              : '等待对方接收';
      _notify();
      await _exchange(
          'offer',
          id,
          {
            'name': sendingName,
            'count': entries.length,
            'bytes': sendTotal,
            'drag': drag,
            'clipboard': clipboard,
            'y': y
          },
          timeout: const Duration(minutes: 2));
      _sendClock.start();
      var seq = 0;
      for (final entry in entries) {
        await _exchange('entry', id, {
          'seq': seq++,
          'path': entry.relative,
          'directory': entry.directory,
          'size': entry.size
        });
        if (entry.directory) continue;
        final hashResult = _HashSink();
        final hash = sha256.startChunkedConversion(hashResult);
        final file = await File(entry.local).open();
        var offset = 0;
        try {
          while (offset < entry.size) {
            final bytes =
                await file.read(min(transferChunkSize, entry.size - offset));
            if (bytes.isEmpty) throw StateError('发送期间文件长度改变');
            hash.add(bytes);
            await _exchange('chunk', id,
                {'seq': seq++, 'offset': offset, 'data': base64Encode(bytes)});
            offset += bytes.length;
            sentBytes += bytes.length;
            _notify(force: false);
          }
          if (await file.length() != entry.size) throw StateError('发送期间文件长度改变');
        } finally {
          await file.close();
          hash.close();
        }
        await _exchange('file_end', id,
            {'seq': seq++, 'hash': hashResult.value.toString()});
      }
      if (drag) {
        _outgoingDragId = id;
        _record(id, sendingName!, sendTotal, true, true, '正在完成文件传输');
      }
      await _exchange('finish', id, {'seq': seq});
      status = drag ? '文件已就绪，继续拖到目标文件夹并松开' : '发送完成';
      if (!drag) _record(id, sendingName!, sendTotal, true, false, status);
      if (drag && _outgoingDragId == id) {
        _record(id, sendingName!, sendTotal, true, true, '文件已传送，等待系统拖放结果');
      }
    } catch (e) {
      status = '发送未完成：$e';
      _record(id, sendingName!, manifestReady ? sendTotal : null, true, drag, status);
      if (_outgoingDragId == id) _outgoingDragId = null;
      try {
        await _emit('cancel', id);
      } catch (_) {}
      rethrow;
    } finally {
      if (_outId == id) {
        _outId = null;
        _reply = null;
      }
      sending = false;
      _sendClock.stop();
      _notify();
    }
  }

  Future<Map<String, dynamic>> _exchange(
      String op, String id, Map<String, dynamic> fields,
      {Duration timeout = const Duration(seconds: 25)}) async {
    if (_closed || _outId != id) throw StateError('传输已取消');
    final reply = Completer<Map<String, dynamic>>();
    _reply = reply;
    final future = reply.future.timeout(timeout);
    unawaited(future.then<void>((_) {}, onError: (Object _) {}));
    await _emit(op, id, fields);
    final message = await future;
    if (message['op'] != 'ack' || message['seq'] != (fields['seq'] ?? -1)) {
      final reason = message['reason'];
      throw StateError(reason is String && reason.isNotEmpty && reason.length <= 256
          ? '接收方：$reason' : '接收方拒绝或取消传输');
    }
    return message;
  }

  Future<void> receive(Map<String, dynamic> m) async {
    final id = m['id'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException('无效传输编号');
    }
    final op = m['op'];
    if ((op == 'ack' || op == 'reject' || op == 'cancel') && id == _outId) {
      if (_reply != null && !_reply!.isCompleted) _reply!.complete(m);
      if (op != 'ack') _outId = null;
      return;
    }
    if (op == 'offer') {
      if (offer != null || receiving) {
        await _emit('reject', id);
        return;
      }
      final count = m['count'],
          bytes = m['bytes'],
          name = m['name'],
          y = m['y'];
      if (count is! int ||
          count < 1 ||
          count > maxTransferEntries ||
          bytes is! int ||
          bytes < 0 ||
          bytes > maxTransferBytes ||
          name is! String ||
          name.length > 1024 ||
          y is! num ||
          !y.isFinite ||
          y < 0 ||
          y > 1 ||
          m['drag'] is! bool ||
          (m['clipboard'] != null && m['clipboard'] is! bool) ||
          (m['clipboard'] == true && m['drag'] == true)) {
        throw const FormatException('无效文件清单');
      }
      final clipboard = m['clipboard'] == true;
      if (clipboard &&
          (onClipboardReceived == null ||
              !await (onClipboardOffered?.call() ?? Future.value(false)))) {
        await _emit('reject', id);
        return;
      }
      offer = TransferOffer(
          id, name, count, bytes, m['drag'] == true, y.toDouble(),
          clipboard: clipboard);
      status = '对方希望发送：$name';
      _notify();
      if (offer!.drag || offer!.clipboard) await accept();
      return;
    }
    if (id != offer?.id) return; // Late packets from cancelled transfers.
    if (op == 'cancel') {
      final cancelled = offer!;
      await _discard();
      status = '对方已取消传输';
      _record(id, cancelled.name, cancelled.bytes, false, cancelled.drag, status);
      _notify();
      return;
    }
    TransferOffer? completedTransfer;
    try {
      if (!receiving || _staging == null) throw StateError('传输尚未接受');
      if (m['seq'] != _sequence++) throw const FormatException('文件帧顺序错误');
      switch (op) {
        case 'entry':
          if (_file != null || ++_entryCount > offer!.count) {
            throw const FormatException('文件清单不一致');
          }
          final relative = m['path'],
              directory = m['directory'],
              size = m['size'];
          if (relative is! String ||
              directory is! bool ||
              size is! int ||
              size < 0 ||
              size > maxTransferBytes) {
            throw const FormatException('无效文件条目');
          }
          validateTransferPath(relative);
          final key = relative.toLowerCase();
          if (!_paths.add(key)) throw const FormatException('重复文件名');
          final parent = p.posix.dirname(relative);
          if (parent != '.' && !_directories.contains(parent.toLowerCase())) {
            throw const FormatException('缺少父目录');
          }
          if (parent == '.') _roots.add(relative);
          final target = p.joinAll([_staging!.path, ...relative.split('/')]);
          await _checkParents(relative);
          if (await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const FormatException('目标路径已经存在');
          }
          if (directory) {
            if (size != 0) throw const FormatException('目录大小无效');
            await Directory(target).create();
            _directories.add(key);
          } else {
            _declaredBytes += size;
            if (_declaredBytes > offer!.bytes) {
              throw const FormatException('传输大小超限');
            }
            _file = await File(target).open(mode: FileMode.writeOnly);
            _fileSize = size;
            _fileOffset = 0;
            _hashResult = _HashSink();
            _hash = sha256.startChunkedConversion(_hashResult!);
          }
        case 'chunk':
          if (_file == null ||
              m['offset'] != _fileOffset ||
              m['data'] is! String ||
              (m['data'] as String).length > 8192) {
            throw const FormatException('无效文件块');
          }
          final bytes = base64Decode(m['data'] as String);
          if (bytes.isEmpty ||
              bytes.length > transferChunkSize ||
              _fileOffset + bytes.length > _fileSize) {
            throw const FormatException('文件块大小错误');
          }
          await _file!.writeFrom(bytes);
          _hash!.add(bytes);
          _fileOffset += bytes.length;
          receivedBytes += bytes.length;
          _notify(force: false);
        case 'file_end':
          if (_file == null || _fileOffset != _fileSize) {
            throw const FormatException('文件未完整接收');
          }
          _hash!.close();
          _hash = null;
          if (m['hash'] != _hashResult!.value.toString()) {
            throw const FormatException('文件校验失败');
          }
          await _file!.flush();
          await _file!.close();
          _file = null;
        case 'finish':
          if (_file != null ||
              _entryCount != offer!.count ||
              receivedBytes != offer!.bytes ||
              _declaredBytes != offer!.bytes) {
            throw const FormatException('文件清单未完成');
          }
          final transfer = offer!;
          final stage = _staging!;
          final destination =
              p.join(p.dirname(stage.path), 'Received-${transfer.id}');
          if (await FileSystemEntity.type(destination, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const FormatException('接收目录已存在');
          }
          await stage.rename(destination);
          completedTransfer = transfer;
          final paths =
              _roots.map((name) => p.join(destination, name)).toList();
          _staging = null;
          offer = null;
          receiving = false;
          _receiveClock.stop();
          lastDirectory = destination;
          status = '接收完成：$destination';
          _record(id, transfer.name, transfer.bytes, false, transfer.drag,
              transfer.drag ? '文件已接收，等待系统拖放结果' : status);
          if (transfer.drag) _incomingDragId = id;
          _notify();
          if (transfer.clipboard) await onClipboardReceived?.call(paths);
          await _emit('ack', id, {'seq': m['seq']});
          if (transfer.drag) await onDragReceived?.call(paths, transfer.y);
          return;
        default:
          throw const FormatException('未知文件消息');
      }
      await _emit('ack', id, {'seq': m['seq']});
    } catch (e) {
      final failed = offer ?? completedTransfer;
      await _discard();
      status = '接收失败：$e${completedTransfer != null && lastDirectory != null ? '；已接收文件保存在 $lastDirectory' : ''}';
      if (failed != null) _record(id, failed.name, failed.bytes, false, failed.drag, status);
      _notify();
      final reason = e.toString();
      await _emit('reject', id, {'reason': reason.length > 256 ? reason.substring(0, 256) : reason});
    }
  }

  Future<void> accept() async {
    final incoming = offer;
    if (incoming == null || receiving) return;
    try {
      final root = await receiveDirectory();
      await root.create(recursive: true);
      final stage = await root.createTemp('.lan-bridge-');
      if (_closed || offer != incoming) {
        await stage.delete(recursive: true);
        return;
      }
      _staging = stage;
      receiving = true;
      receivedBytes = 0;
      _receiveClock
        ..reset()
        ..start();
      receiveTotal = incoming.bytes;
      _sequence = 0;
      _entryCount = 0;
      _declaredBytes = 0;
      _paths.clear();
      _directories.clear();
      _roots.clear();
      status = incoming.drag ? '正在准备跨屏拖放文件' : '正在接收文件';
      _notify();
      await _emit('ack', incoming.id, {'seq': -1});
    } catch (e) {
      // The offer may have been cancelled while the directory was resolving.
      // Never discard a replacement offer or report a stale failure.
      if (_closed || offer != incoming) return;
      await _discard();
      status = '无法创建接收目录：$e';
      _record(incoming.id, incoming.name, incoming.bytes, false, incoming.drag, status);
      _notify();
      final reason = status.length > 256 ? status.substring(0, 256) : status;
      await _emit('reject', incoming.id, {'reason': reason});
    }
  }

  Future<void> reject() async {
    final rejected = offer;
    final id = rejected?.id;
    await _discard();
    if (id != null) {
      _record(id, rejected!.name, rejected.bytes, false, rejected.drag, '已拒绝接收');
      await _emit('reject', id);
    }
    status = '已拒绝接收';
    _notify();
  }

  Future<void> cancel() async {
    final out = _outId, incoming = offer?.id;
    final cancelled = offer;
    _outId = null;
    if (_reply != null && !_reply!.isCompleted) {
      _reply!.complete({'op': 'cancel'});
    }
    await _discard();
    if (incoming != null && cancelled != null) {
      _record(incoming, cancelled.name, cancelled.bytes, false, cancelled.drag, '传输已取消');
    }
    if (!_closed) {
      if (out != null) await _emit('cancel', out);
      if (incoming != null) await _emit('cancel', incoming);
    }
    status = '传输已取消';
    _notify();
  }

  Future<void> _checkParents(String relative) async {
    var path = _staging!.path;
    for (final segment in [
      '.',
      ...relative.split('/').take(relative.split('/').length - 1)
    ]) {
      path = p.join(path, segment);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException('接收路径被替换');
      }
    }
  }

  Future<void> _discard() async {
    await _file?.close();
    _file = null;
    _hash = null;
    _hashResult = null;
    final stage = _staging;
    _staging = null;
    offer = null;
    receiving = false;
    _receiveClock.stop();
    if (stage != null && await stage.exists()) {
      await stage.delete(recursive: true);
    }
  }

  Future<void> close() async {
    _closed = true;
    await cancel();
  }
}

void validateTransferPath(String path) {
  if (path.isEmpty ||
      utf8.encode(path).length > 2048 ||
      path.startsWith('/') ||
      path.contains('\\')) {
    throw const FormatException('不安全的文件路径');
  }
  for (final segment in path.split('/')) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        RegExp(r'[<>:"|?*\x00-\x1f\x7f]').hasMatch(segment) ||
        RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)',
                caseSensitive: false)
            .hasMatch(segment)) {
      throw const FormatException('文件名不兼容 Windows/macOS');
    }
  }
}

class _HashSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
