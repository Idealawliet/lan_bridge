import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/sharing/clipboard_sync.dart';

class MemoryClipboard implements ClipboardAccess {
  int rev = 0, writes = 0;
  ClipboardContent? content;
  bool failWrite = false;
  Completer<void>? readGate, writeGate;
  void copy(String text) {
    content = ClipboardContent('text', Uint8List.fromList(utf8.encode(text)));
    rev++;
  }

  @override
  Future<int> revision() async => rev;
  @override
  Future<ClipboardContent?> read() async {
    final value = content;
    await readGate?.future;
    return value;
  }

  @override
  Future<void> write(ClipboardContent value) async {
    if (failWrite) throw StateError('clipboard busy');
    await writeGate?.future;
    content = value;
    writes++;
    rev++;
  }
}

void main() {
  test('pause and resume invalidate text waiting behind a file clipboard write',
      () async {
    final sourceAccess = MemoryClipboard();
    final receiverAccess = MemoryClipboard()..writeGate = Completer<void>();
    late ClipboardSync sender, receiver;
    sender =
        ClipboardSync(access: sourceAccess, send: (m) => receiver.receive(m));
    receiver =
        ClipboardSync(access: receiverAccess, send: (m) => sender.receive(m));
    addTearDown(sender.close);
    addTearDown(receiver.close);
    await sender.start();
    await receiver.start();
    final applyingFiles = receiver.applyFiles(['/received/original.jpg']);
    await Future<void>.delayed(Duration.zero);
    sourceAccess.copy('old queued text');
    final sendingText = sender.poll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    receiver.setEnabled(false);
    receiver.setEnabled(true);
    receiverAccess.writeGate!.complete();
    await applyingFiles;
    await sendingText;
    expect(receiverAccess.writes, 1);
    expect(receiverAccess.content!.format, 'files');
    expect(receiverAccess.content!.filePaths, ['/received/original.jpg']);
  });

  test(
      'file clipboard wins over image previews and file names are not converted',
      () async {
    var imageReads = 0;
    final paths = ['/tmp/原图.jpg', '/tmp/报告.docx', '/tmp/压缩包.zip'];
    List<String>? written;
    final access = SystemClipboard(() async => 1, () async => true,
        readFiles: () async => paths,
        readImage: () async {
          imageReads++;
          return Uint8List.fromList([1, 2, 3]);
        },
        writeFiles: (value) async {
          written = value;
          return true;
        });
    final content = await access.read();
    expect(content!.format, 'files');
    expect(content.filePaths, paths);
    expect(imageReads, 0);
    await access.write(content);
    expect(written, paths);
  });

  test(
      'file copies use the original-file transfer without exposing source paths on clipboard wire',
      () async {
    final access = MemoryClipboard();
    final frames = <Map<String, dynamic>>[];
    List<String>? transferred;
    final sync = ClipboardSync(
        access: access,
        send: (frame) async => frames.add(frame),
        sendFiles: (paths) async {
          transferred = paths;
        });
    addTearDown(sync.close);
    await sync.start();
    access.content = ClipboardContent.files(['/tmp/原图.jpg', '/tmp/目录']);
    access.rev++;
    await sync.poll();
    expect(transferred, ['/tmp/原图.jpg', '/tmp/目录']);
    expect(frames, isEmpty);
    expect(sync.status, contains('原始文件已同步'));
    await sync.poll();
    expect(access.writes, 0);
  });

  test(
      'received file clipboard does not echo or overwrite newer copied content',
      () async {
    final access = MemoryClipboard();
    final frames = <Map<String, dynamic>>[];
    final sync =
        ClipboardSync(access: access, send: (frame) async => frames.add(frame));
    addTearDown(sync.close);
    await sync.start();
    expect(await sync.applyFiles(['/received/原图.jpg'], expectedRevision: 0),
        isTrue);
    expect(access.content!.filePaths, ['/received/原图.jpg']);
    await sync.poll();
    expect(frames, isEmpty);
    final oldRevision = access.rev;
    access.copy('刚复制的新文本');
    expect(
        await sync
            .applyFiles(['/received/old.zip'], expectedRevision: oldRevision),
        isFalse);
    expect(utf8.decode(access.content!.bytes), '刚复制的新文本');
    sync.setEnabled(false);
    expect(await sync.applyFiles(['/received/old.zip']), isFalse);
  });

  test('pause waits for an already-started OS clipboard write', () async {
    final ca = MemoryClipboard(),
        cb = MemoryClipboard()..writeGate = Completer<void>();
    late ClipboardSync a, b;
    a = ClipboardSync(send: (m) => b.receive(m), access: ca);
    b = ClipboardSync(send: (m) => a.receive(m), access: cb);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.start();
    await b.start();
    ca.copy('old client');
    final poll = a.poll();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    var paused = false;
    final pause = b.pause().then((_) => paused = true);
    await Future<void>.delayed(Duration.zero);
    expect(paused, isFalse);
    cb.writeGate!.complete();
    await pause;
    await poll;
    expect(cb.writes, 1);
    expect(b.enabled, isFalse);
  });

  test('copying identical content retries after receiver write failure',
      () async {
    final ca = MemoryClipboard(), cb = MemoryClipboard()..failWrite = true;
    late ClipboardSync a, b;
    a = ClipboardSync(send: (m) => b.receive(m), access: ca);
    b = ClipboardSync(send: (m) => a.receive(m), access: cb);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.start();
    await b.start();
    ca.copy('retry me');
    await a.poll();
    cb.failWrite = false;
    ca.copy('retry me');
    await a.poll();
    expect(cb.writes, 1);
  });
  test('pause and resume invalidate an in-flight clipboard read', () async {
    final ca = MemoryClipboard();
    final frames = <Map<String, dynamic>>[];
    late ClipboardSync sync;
    sync = ClipboardSync(
        access: ca,
        send: (m) async {
          frames.add(m);
          await sync.receive({
            'op': 'ack',
            'id': m['id'],
            'seq': m['op'] == 'begin'
                ? -1
                : m['op'] == 'end'
                    ? -2
                    : m['offset']
          });
        });
    addTearDown(sync.close);
    await sync.start();
    ca.copy('old focus secret');
    ca.readGate = Completer<void>();
    final poll = sync.poll();
    await Future<void>.delayed(Duration.zero);
    sync.setEnabled(false);
    sync.setEnabled(true);
    ca.readGate!.complete();
    await poll;
    expect(frames, isEmpty);
  });

  test(
      'new text copies synchronize both directions without echo or pre-connection leaks',
      () async {
    final ca = MemoryClipboard()..copy('old secret'), cb = MemoryClipboard();
    late ClipboardSync a, b;
    a = ClipboardSync(send: (m) => b.receive(m), access: ca);
    b = ClipboardSync(send: (m) => a.receive(m), access: cb);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.start();
    await b.start();
    await a.poll();
    expect(cb.content, isNull);
    ca.copy('你好\n${'large text ' * 2000}');
    await a.poll();
    expect(utf8.decode(cb.content!.bytes), utf8.decode(ca.content!.bytes));
    await b.poll();
    expect(ca.writes, 0);
    cb.copy('reverse');
    await b.poll();
    expect(utf8.decode(ca.content!.bytes), 'reverse');
    await a.poll();
    expect(cb.writes, 1);
  });
  test(
      'binary image payload survives chunking and oversized clipboard is skipped',
      () async {
    final ca = MemoryClipboard(), cb = MemoryClipboard();
    late ClipboardSync a, b;
    a = ClipboardSync(send: (m) => b.receive(m), access: ca);
    b = ClipboardSync(send: (m) => a.receive(m), access: cb);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.start();
    await b.start();
    final bytes = Uint8List.fromList(List.generate(15000, (i) => i % 256));
    ca.content = ClipboardContent('png', bytes);
    ca.rev++;
    await a.poll();
    expect(cb.content!.bytes, bytes);
    expect(cb.content!.format, 'png');
    ca.content = ClipboardContent('png', Uint8List(ClipboardSync.maxBytes + 1));
    ca.rev++;
    await a.poll();
    expect(cb.writes, 1);
    expect(a.status, contains('超过'));
  });
  test('disabled clipboard never writes incoming content', () async {
    final clipboard = MemoryClipboard();
    final sync = ClipboardSync(send: (_) async {}, access: clipboard);
    addTearDown(sync.close);
    sync.setEnabled(false);
    await sync
        .receive({'op': 'begin', 'id': 'test', 'format': 'text', 'size': 2});
    expect(clipboard.writes, 0);
  });
  test('resume skips paused copies and write failure does not break later sync',
      () async {
    final ca = MemoryClipboard(), cb = MemoryClipboard();
    late ClipboardSync a, b;
    a = ClipboardSync(send: (m) => b.receive(m), access: ca);
    b = ClipboardSync(send: (m) => a.receive(m), access: cb);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.start();
    await b.start();
    a.setEnabled(false);
    ca.copy('private while paused');
    a.setEnabled(true);
    await a.poll();
    expect(cb.content, isNull);
    cb.failWrite = true;
    ca.copy('busy');
    await a.poll();
    expect(a.status, contains('未同步'));
    cb.failWrite = false;
    ca.copy('recovered');
    await a.poll();
    expect(utf8.decode(cb.content!.bytes), 'recovered');
    b.setEnabled(false);
    ca.copy('receiver paused');
    await a.poll();
    expect(cb.writes, 1);
    expect(a.status, contains('未同步'));
  });
}
