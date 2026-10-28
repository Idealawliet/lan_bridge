import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'file_transfer.dart';

class ClipboardContent {
  ClipboardContent(this.format, this.bytes);
  factory ClipboardContent.files(List<String> paths) => ClipboardContent(
      'files', Uint8List.fromList(utf8.encode(jsonEncode(paths))));
  List<String> get filePaths =>
      (jsonDecode(utf8.decode(bytes)) as List).cast<String>();
  final String format;
  final Uint8List bytes;
}

abstract class ClipboardAccess {
  Future<int> revision();
  Future<ClipboardContent?> read();
  Future<void> write(ClipboardContent content);
}

class SystemClipboard implements ClipboardAccess {
  SystemClipboard(this.getRevision, this.hasFiles,
      {Future<List<String>> Function()? readFiles,
      Future<Uint8List?> Function()? readImage,
      Future<String?> Function()? readText,
      Future<bool> Function(List<String>)? writeFiles})
      : _readFiles = readFiles ?? Pasteboard.files,
        _readImage = readImage ?? (() => Pasteboard.image),
        _readText = readText ??
            (() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text),
        _writeFiles = writeFiles ?? Pasteboard.writeFiles;
  final Future<int> Function() getRevision;
  final Future<bool> Function() hasFiles;
  final Future<List<String>> Function() _readFiles;
  final Future<Uint8List?> Function() _readImage;
  final Future<String?> Function() _readText;
  final Future<bool> Function(List<String>) _writeFiles;
  @override
  Future<int> revision() => getRevision();
  @override
  Future<ClipboardContent?> read() async {
    // File URLs/CF_HDROP take precedence over preview images and display names.
    // Only the original bytes go through FileTransfer, never an image conversion.
    if (await hasFiles()) {
      final paths = await _readFiles();
      return paths.isEmpty ? null : ClipboardContent.files(paths);
    }
    final image = await _readImage();
    if (await hasFiles()) {
      return null; // Clipboard changed during the async read.
    }
    if (image != null && image.isNotEmpty) {
      return ClipboardContent('png', image);
    }
    final text = await _readText();
    if (await hasFiles()) return null;
    return text == null
        ? null
        : ClipboardContent('text', Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Future<void> write(ClipboardContent content) async {
    if (content.format == 'files') {
      if (!await _writeFiles(content.filePaths)) {
        throw StateError('无法将接收文件写入系统剪贴板');
      }
    } else if (content.format == 'png') {
      await Pasteboard.writeImage(content.bytes);
    } else {
      await Clipboard.setData(ClipboardData(text: utf8.decode(content.bytes)));
    }
  }
}

/// Synchronizes clipboard changes for one active session.
///
/// Revision checks guard asynchronous OS reads against concurrent local copies;
/// fingerprints suppress echoes after applying remote content. File clipboard
/// entries use [FileTransfer] so the original file bytes and names survive.
class ClipboardSync extends ChangeNotifier {
  ClipboardSync({required this.send, required this.access, this.sendFiles});
  final Future<void> Function(List<String>)? sendFiles;
  final SendFrame send;
  final ClipboardAccess access;
  static const maxBytes = 8 * 1024 * 1024;
  bool enabled = true, _closed = false, _polling = false, _applying = false;
  String status = '同步文本、图片与原始文件';
  Timer? _timer;
  int? _revision;
  String? _fingerprint, _incomingId;
  BytesBuilder? _incoming;
  int _incomingSize = 0, _received = 0;
  String _incomingFormat = '';
  Completer<void>? _ack, _writeDone;
  Future<void> get settled => _writeDone?.future ?? Future<void>.value();
  Future<void> pause() async {
    setEnabled(false);
    await settled;
  }

  String? _outgoingId;
  int _expectedAck = -1, _counter = 0, _generation = 0;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> start() async {
    final generation = _generation;
    try {
      final revision = await access.revision();
      if (generation == _generation && !_closed) _revision = revision;
    } catch (_) {
      status = '剪贴板暂不可用';
    }
    if (!_closed) {
      _timer = Timer.periodic(const Duration(milliseconds: 750), (_) {
        unawaited(poll());
      });
    }
  }

  void setEnabled(bool value) {
    // Increment even on resume: any in-flight read or write begun under the
    // previous policy must not become a new outgoing synchronization.
    _generation++;
    enabled = value;
    _revision = null;
    if (!value && _ack != null && !_ack!.isCompleted) {
      _ack!.completeError(StateError('同步已暂停'));
    }
    _incoming = null;
    _incomingId = null;
    status = value ? '同步已开启；仅同步连接后新复制的内容' : '同步已暂停';
    _notify();
  }

  Future<void> poll() async {
    if (_closed || !enabled || _polling || _applying) return;
    _polling = true;
    final generation = _generation;
    try {
      final revision = await access.revision();
      if (_closed || !enabled || generation != _generation) return;
      if (_revision == null) {
        _revision = revision;
        return;
      }
      if (_revision == revision || _applying || _closed) return;
      _revision = revision;
      final content = await access.read();
      if (content == null ||
          _applying ||
          _closed ||
          !enabled ||
          generation != _generation) {
        return;
      }
      if (await access.revision() != revision ||
          _closed ||
          !enabled ||
          _applying ||
          generation != _generation) {
        return;
      }
      final fingerprint = '${content.format}:${sha256.convert(content.bytes)}';
      if (fingerprint == _fingerprint) return;
      if (content.bytes.length > maxBytes) {
        status = '剪贴板超过 8 MiB，未同步';
        _notify();
        return;
      }
      if (content.format == 'files') {
        if (sendFiles == null) return;
        status = '正在同步原始文件，请等待传输完成后粘贴';
        _notify();
        await sendFiles!(content.filePaths);
        if (generation != _generation || _closed || !enabled) return;
        _fingerprint = fingerprint;
        status = '原始文件已同步，可在另一台电脑粘贴';
        _notify();
        return;
      }
      final id = '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
      _outgoingId = id;
      await _sendAndWait({
        'op': 'begin',
        'id': id,
        'format': content.format,
        'size': content.bytes.length
      }, -1, generation);
      var offset = 0;
      while (offset < content.bytes.length) {
        final end = (offset + transferChunkSize).clamp(0, content.bytes.length);
        await _sendAndWait({
          'op': 'chunk',
          'id': id,
          'offset': offset,
          'data': base64Encode(content.bytes.sublist(offset, end))
        }, offset, generation);
        offset = end;
      }
      await _sendAndWait({
        'op': 'end',
        'id': id,
        'hash': sha256.convert(content.bytes).toString()
      }, -2, generation);
      if (generation != _generation) return;
      _fingerprint = fingerprint;
      status = content.format == 'png' ? '图片剪贴板已同步' : '文本剪贴板已同步';
      _notify();
    } catch (e) {
      if (generation == _generation) {
        status = '剪贴板未同步：$e';
        _notify();
      }
    } finally {
      _polling = false;
      _outgoingId = null;
      _ack = null;
    }
  }

  Future<bool> applyFiles(List<String> paths, {int? expectedRevision}) async {
    // A potentially long file transfer must not overwrite a newer local copy
    // made after the receiver accepted the offer.
    if (_closed || !enabled || _applying) return false;
    final generation = _generation;
    if (expectedRevision != null &&
        await access.revision() != expectedRevision) {
      status = '文件已收到；本机剪贴板已变化，保留新复制的内容';
      _notify();
      return false;
    }
    if (_closed || !enabled || generation != _generation || _applying) {
      return false;
    }
    _applying = true;
    final completion = Completer<void>();
    _writeDone = completion;
    try {
      final content = ClipboardContent.files(paths);
      await access.write(content);
      _revision = await access.revision();
      _fingerprint = 'files:${sha256.convert(content.bytes)}';
      status = '原始文件已接收，可直接粘贴（保留文件名和格式）';
      _notify();
      return true;
    } finally {
      _applying = false;
      completion.complete();
      _writeDone = null;
    }
  }

  Future<void> _sendAndWait(
      Map<String, dynamic> frame, int sequence, int generation) async {
    if (_closed || !enabled || generation != _generation) {
      throw StateError('同步已停止');
    }
    final ack = Completer<void>();
    _ack = ack;
    _expectedAck = sequence;
    final future = ack.future.timeout(const Duration(seconds: 10));
    unawaited(future.then<void>((_) {}, onError: (Object _) {}));
    await send({'type': 'clipboard', ...frame});
    await future;
  }

  Future<void> receive(Map<String, dynamic> m) async {
    if (_closed) return;
    final id = m['id'], op = m['op'];
    if (op == 'ack') {
      if (id == _outgoingId &&
          m['seq'] == _expectedAck &&
          _ack != null &&
          !_ack!.isCompleted) {
        _ack!.complete();
      }
      return;
    }
    if (op == 'reject') {
      if (id == _outgoingId && _ack != null && !_ack!.isCompleted) {
        _ack!.completeError(StateError('对端剪贴板暂停或暂不可用'));
      }
      return;
    }
    if (id is! String || id.length > 80) throw const FormatException('无效剪贴板编号');
    if (!enabled) {
      await send({'type': 'clipboard', 'op': 'reject', 'id': id});
      return;
    }
    var seq = -1;
    if (op == 'begin') {
      final size = m['size'];
      if (size is! int ||
          size < 0 ||
          size > maxBytes ||
          !['text', 'png'].contains(m['format'])) {
        throw const FormatException('剪贴板大小或格式错误');
      }
      _incomingId = id;
      _incomingSize = size;
      _received = 0;
      _incomingFormat = m['format'] as String;
      _incoming = BytesBuilder(copy: false);
    } else {
      if (id != _incomingId || _incoming == null) {
        await send({'type': 'clipboard', 'op': 'reject', 'id': id});
        return;
      }
      if (op == 'chunk') {
        final data = m['data'];
        if (data is! String || data.length > 8192 || m['offset'] != _received) {
          throw const FormatException('剪贴板块错误');
        }
        final bytes = base64Decode(data);
        if (bytes.isEmpty ||
            bytes.length > transferChunkSize ||
            _received + bytes.length > _incomingSize) {
          throw const FormatException('剪贴板块超限');
        }
        seq = _received;
        _incoming!.add(bytes);
        _received += bytes.length;
      } else if (op == 'end') {
        if (_received != _incomingSize) throw const FormatException('剪贴板不完整');
        final bytes = _incoming!.takeBytes();
        _incoming = null;
        _incomingId = null;
        if (sha256.convert(bytes).toString() != m['hash']) {
          throw const FormatException('剪贴板校验失败');
        }
        final generation = _generation;
        if (_applying) await settled;
        if (_closed || !enabled || generation != _generation) {
          await send({'type': 'clipboard', 'op': 'reject', 'id': id});
          return;
        }
        _applying = true;
        final writeDone = Completer<void>();
        _writeDone = writeDone;
        try {
          await access.write(ClipboardContent(_incomingFormat, bytes));
          _revision = await access.revision();
          _fingerprint = '$_incomingFormat:${m['hash']}';
          status = _incomingFormat == 'png' ? '已接收图片剪贴板' : '已接收文本剪贴板';
          _notify();
        } catch (_) {
          status = '系统剪贴板暂不可写入';
          _notify();
          await send({'type': 'clipboard', 'op': 'reject', 'id': id});
          return;
        } finally {
          _applying = false;
          writeDone.complete();
          _writeDone = null;
        }
        seq = -2;
      } else {
        throw const FormatException('未知剪贴板消息');
      }
    }
    await send({'type': 'clipboard', 'op': 'ack', 'id': id, 'seq': seq});
  }

  void close() {
    _generation++;
    _closed = true;
    _timer?.cancel();
    _incoming = null;
    if (_ack != null && !_ack!.isCompleted) {
      _ack!.completeError(StateError('连接已断开'));
    }
  }
}
