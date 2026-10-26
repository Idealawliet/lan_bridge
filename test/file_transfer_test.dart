import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/sharing/file_transfer.dart';
import 'package:path/path.dart' as p;

void main() {
  test('clipboard transfers keep original extensions, bytes and directories',
      () async {
    final root = await Directory.systemTemp.createTemp('lan-file-clipboard-');
    addTearDown(() => root.delete(recursive: true));
    final originals = await Directory(p.join(root.path, 'source')).create();
    final data = List.generate(20001, (i) => i % 253);
    final jpg = await File(p.join(originals.path, '原图.jpg')).writeAsBytes(data);
    final doc = await File(p.join(originals.path, '报告.docx'))
        .writeAsBytes([80, 75, 3, 4, 1]);
    final folder = await Directory(p.join(originals.path, '目录')).create();
    await Directory(p.join(folder.path, '空目录')).create();
    await File(p.join(folder.path, '压缩包.zip')).writeAsBytes([80, 75, 3, 4, 2]);
    List<String>? copied;
    late FileTransfer sender, receiver;
    receiver = FileTransfer(
        send: (m) => sender.receive(m),
        receiveDirectory: () async => Directory(p.join(root.path, 'received')),
        onClipboardOffered: () async => true,
        onClipboardReceived: (paths) async {
          copied = paths;
        });
    sender = FileTransfer(
        send: (m) => receiver.receive(m), receiveDirectory: () async => root);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    await sender.sendPaths([jpg.path, doc.path, folder.path], clipboard: true);
    expect(
        copied!.map(p.basename), unorderedEquals(['原图.jpg', '报告.docx', '目录']));
    final receivedJpg = copied!.firstWhere((path) => path.endsWith('.jpg'));
    expect(await File(receivedJpg).readAsBytes(), data);
    final receivedDoc = copied!.firstWhere((path) => path.endsWith('.docx'));
    expect(await File(receivedDoc).readAsBytes(), await doc.readAsBytes());
    final receivedFolder =
        copied!.firstWhere((path) => p.basename(path) == '目录');
    expect(await Directory(p.join(receivedFolder, '空目录')).exists(), isTrue);
    expect(await File(p.join(receivedFolder, '压缩包.zip')).readAsBytes(),
        [80, 75, 3, 4, 2]);
    expect(await jpg.exists(), isTrue);
  });

  test(
      'streams nested files, zero byte files and empty folders without overwriting',
      () async {
    final root = await Directory.systemTemp.createTemp('lan-transfer-test-');
    addTearDown(() => root.delete(recursive: true));
    final original = await Directory(p.join(root.path, 'original')).create();
    await Directory(p.join(original.path, 'empty')).create();
    await File(p.join(original.path, 'zero.txt')).writeAsBytes([]);
    final data = List.generate(transferChunkSize * 3 + 77, (i) => i % 251);
    await File(p.join(original.path, '文件.bin')).writeAsBytes(data);
    late FileTransfer sender, receiver;
    receiver = FileTransfer(
        send: (m) => sender.receive(m),
        receiveDirectory: () async => Directory(p.join(root.path, 'received')));
    sender = FileTransfer(
        send: (m) async {
          await receiver.receive(m);
          if (m['op'] == 'offer') await receiver.accept();
        },
        receiveDirectory: () async => root);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    await sender.sendPaths([original.path]);
    final destination = p.join(receiver.lastDirectory!, 'original');
    expect(await File(p.join(destination, '文件.bin')).readAsBytes(), data);
    expect(await File(p.join(destination, 'zero.txt')).length(), 0);
    expect(await Directory(p.join(destination, 'empty')).exists(), isTrue);
    expect(sender.sentBytes, data.length);
    expect(await original.exists(), isTrue);
    final first = receiver.lastDirectory;
    await sender.sendPaths([original.path]);
    expect(receiver.lastDirectory, isNot(first));
    expect(await Directory(first!).exists(), isTrue);
  });
  test('portable path validation refuses traversal, ADS and reserved devices',
      () {
    for (final path in [
      '../x',
      '/x',
      'a/../x',
      'a\\b',
      'file:ads',
      'CON.txt',
      'x/COM1',
      'x/',
      'a\u0000b',
      'a.'
    ]) {
      expect(() => validateTransferPath(path), throwsFormatException,
          reason: path);
    }
    validateTransferPath('文件夹/报告 2026.txt');
  });
  test('receiver rejects bad checksum and removes incomplete data', () async {
    final root = await Directory.systemTemp.createTemp('lan-integrity-test-');
    addTearDown(() => root.delete(recursive: true));
    final messages = <Map<String, dynamic>>[];
    final receiver = FileTransfer(
        send: (m) async {
          messages.add(m);
        },
        receiveDirectory: () async => root);
    addTearDown(receiver.close);
    const id = '11111111111111111111111111111111';
    await receiver.receive({
      'op': 'offer',
      'id': id,
      'name': 'x',
      'count': 1,
      'bytes': 1,
      'drag': false,
      'y': .5
    });
    await receiver.accept();
    await receiver.receive({
      'op': 'entry',
      'id': id,
      'seq': 0,
      'path': 'x',
      'directory': false,
      'size': 1
    });
    await receiver.receive(
        {'op': 'chunk', 'id': id, 'seq': 1, 'offset': 0, 'data': 'YQ=='});
    await receiver
        .receive({'op': 'file_end', 'id': id, 'seq': 2, 'hash': 'wrong'});
    expect(messages.last['op'], 'reject');
    expect(await root.list().toList(), isEmpty);
    expect(receiver.lastDirectory, isNull);
  });
  test('sender rejects symlinks before offering', () async {
    final root = await Directory.systemTemp.createTemp('lan-links-test-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'data')).writeAsString('secret');
    final link = await Link(p.join(root.path, 'link')).create(file.path);
    final sent = <Map<String, dynamic>>[];
    final sender = FileTransfer(
        send: (m) async {
          sent.add(m);
        },
        receiveDirectory: () async => root);
    addTearDown(sender.close);
    await expectLater(
        sender.sendPaths([link.path]), throwsA(isA<FileSystemException>()));
    expect(sent.where((m) => m['op'] == 'offer'), isEmpty);
  });
  test('cancelling an offer releases sender immediately', () async {
    final root = await Directory.systemTemp.createTemp('lan-cancel-test-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, 'file')).writeAsString('hello');
    final offered = Completer<void>();
    final sender = FileTransfer(
        send: (m) async {
          if (m['op'] == 'offer') offered.complete();
        },
        receiveDirectory: () async => root);
    addTearDown(sender.close);
    final sending = sender.sendPaths([file.path]);
    final rejected = expectLater(sending, throwsStateError);
    await offered.future;
    await sender.cancel();
    await rejected;
    expect(sender.sending, isFalse);
  });
  test('cross-screen callback receives complete verified roots only', () async {
    final root = await Directory.systemTemp.createTemp('lan-drag-test-');
    addTearDown(() => root.delete(recursive: true));
    final folder = await Directory(p.join(root.path, 'folder')).create();
    await File(p.join(folder.path, 'hello')).writeAsString('hello');
    late FileTransfer a, b;
    List<String>? dragged;
    b = FileTransfer(
        send: (m) => a.receive(m),
        receiveDirectory: () async => Directory(p.join(root.path, 'recv')),
        onDragReceived: (paths, y) async {
          dragged = paths;
          expect(y, .25);
          expect(await File(p.join(paths.single, 'hello')).readAsString(),
              'hello');
        });
    a = FileTransfer(
        send: (m) => b.receive(m), receiveDirectory: () async => root);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.sendPaths([folder.path], drag: true, y: .25);
    expect(dragged, hasLength(1));
  });
}
