import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/app_version.dart';
import 'package:lan_bridge/core/desktop_settings.dart';
import 'package:lan_bridge/core/github_updates.dart';

Map<String, dynamic> release(String version,
    {String os = 'windows',
    bool draft = false,
    bool preview = true,
    List<int> bytes = const [1, 2, 3]}) {
  final name = os == 'windows'
      ? 'lan-bridge-windows-x64-$version-setup-unsigned.exe'
      : 'lan-bridge-macos-$version-unsigned.dmg';
  Map<String, dynamic> asset(String file, int size) => {
        'name': file,
        'size': size,
        'browser_download_url':
            'https://github.com/Idealawliet/lan_bridge/releases/download/v$version/$file'
      };
  return {
    'tag_name': 'v$version',
    'draft': draft,
    'prerelease': preview,
    'body': '更新说明',
    'assets': [asset(name, bytes.length), asset('$name.sha256', 180)]
  };
}

class MemoryTransport implements UpdateTransport {
  MemoryTransport(this.responses, this.requests);
  final Map<String, UpdateResponse Function()> responses;
  final List<Uri> requests;
  bool closed = false;
  @override
  Future<UpdateResponse> get(Uri uri) async {
    requests.add(uri);
    return responses[uri.toString()]?.call() ??
        UpdateResponse(404, const Stream.empty());
  }

  @override
  void close() {
    closed = true;
  }
}

UpdateResponse response(List<int> bytes, {int status = 200}) =>
    UpdateResponse(status, Stream.fromIterable([bytes]));

void main() {
  test(
      'historical catalog supports downgrade and reinstall through verified download flow',
      () async {
    final releases = [release('0.8.3'), release('0.10.0'), release('0.9.1')];
    expect(GitHubUpdates.selectRelease(releases, 'windows', '0.11.0'), isNull);
    expect(
        GitHubUpdates.selectRelease([releases.first], 'windows', '0.11.0',
                includeOlder: true)!
            .tag,
        'v0.8.3');
  });
  test('runtime version matches the installer package version', () {
    final spec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: ([^+\s]+)', multiLine: true).firstMatch(spec)![1],
        appVersion);
  });

  test('semantic versions compare numbers and prereleases without downgrading',
      () {
    final versions = [
      'v0.9.1',
      'v0.10.0-alpha',
      'v0.10.0-alpha.2',
      'v0.10.0-alpha.10',
      'v0.10.0-rc.1',
      'v0.10.0',
      'v1.0.0'
    ];
    for (var i = 1; i < versions.length; i++) {
      expect(
          ReleaseVersion.parse(versions[i])!
              .compareTo(ReleaseVersion.parse(versions[i - 1])!),
          greaterThan(0));
    }
    expect(
        ReleaseVersion.parse('1.0.0+99')!
            .compareTo(ReleaseVersion.parse('1.0.0+1')!),
        0);
    for (final invalid in [
      'latest',
      'v1.2',
      'v01.2.3',
      '1.2.3-01',
      '1.2.3-rc..1'
    ]) {
      expect(ReleaseVersion.parse(invalid), isNull);
    }
  });

  test(
      'selects the highest published tag including preview releases and correct OS installer',
      () {
    final data = [
      release('0.9.9'),
      release('0.10.0'),
      release('2.0.0', draft: true),
      release('3.0.0', os: 'macos')
    ];
    final windows = GitHubUpdates.selectRelease(data, 'windows', '0.9.1')!;
    expect(windows.tag, 'v0.10.0');
    expect(windows.prerelease, isTrue);
    expect(windows.installer.name, endsWith('setup-unsigned.exe'));
    expect(GitHubUpdates.selectRelease(data, 'macos', '0.9.1')!.tag, 'v3.0.0');
    expect(
        GitHubUpdates.selectRelease([release('0.10.0')], 'windows', '0.10.0'),
        isNull);
    expect(
        GitHubUpdates.selectRelease(
            [release('0.10.0-rc.1')], 'windows', '0.10.0'),
        isNull);
  });

  test(
      'ignores missing checksums, external downloads, wrong paths and oversized installers',
      () {
    for (final url in [
      'http://github.com/Idealawliet/lan_bridge/releases/download/v2.0.0/file.exe',
      'https://evil.example/file.exe',
      'https://github.com/other/repo/releases/download/v2.0.0/file.exe'
    ]) {
      final data = release('2.0.0');
      (data['assets'] as List).first['browser_download_url'] = url;
      expect(GitHubUpdates.selectRelease([data], 'windows', '1.0.0'), isNull);
    }
    final missing = release('2.0.0');
    (missing['assets'] as List).removeLast();
    expect(GitHubUpdates.selectRelease([missing], 'windows', '1.0.0'), isNull);
    final large = release('2.0.0');
    (large['assets'] as List).first['size'] =
        GitHubUpdates.maxInstallerBytes + 1;
    expect(GitHubUpdates.selectRelease([large], 'windows', '1.0.0'), isNull);
  });

  late Directory directory;
  late Map<String, UpdateResponse Function()> responses;
  late List<Uri> requests;
  late List<List<String>> launches;
  GitHubUpdates updater({String os = 'windows'}) => GitHubUpdates(
        operatingSystem: os,
        currentVersion: '0.9.1',
        transportFactory: () => MemoryTransport(responses, requests),
        settings: DesktopSettings(
            directory: () async => directory, fileName: 'updates.json'),
        directory: () async => Directory('${directory.path}/downloads'),
        launch: (executable, args) async => launches.add([executable, ...args]),
      );

  void serveRelease(
      {String os = 'windows',
      List<int> bytes = const [1, 2, 3],
      String? checksum}) {
    final data = release('0.10.0', os: os, bytes: bytes);
    final assets = data['assets'] as List;
    responses[GitHubUpdates.releasesUri.toString()] =
        () => response(utf8.encode(jsonEncode([data])));
    responses[assets[0]['browser_download_url'] as String] =
        () => response(bytes);
    responses[assets[1]['browser_download_url'] as String] = () => response(
        utf8.encode(
            '${checksum ?? sha256.convert(bytes)}  ${assets[0]['name']}\n'));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lan-updates-');
    responses = {};
    requests = [];
    launches = [];
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
      'startup checks metadata only; download and installation require separate actions',
      () async {
    serveRelease();
    final updates = updater();
    addTearDown(updates.dispose);
    await updates.initialize();
    expect(updates.available!.tag, 'v0.10.0');
    expect(requests, [GitHubUpdates.releasesUri]);
    expect(updates.downloadedFile, isNull);
    expect(launches, isEmpty);
    await updates.download();
    expect(await updates.downloadedFile!.readAsBytes(), [1, 2, 3]);
    expect(updates.progress, 1);
    expect(launches, isEmpty);
    await updates.openInstaller();
    expect(launches.single, [updates.downloadedFile!.path]);
    expect(
        directory
            .listSync(recursive: true)
            .any((f) => f.path.endsWith('.part')),
        isFalse);
  });

  test(
      'selecting an old version downloads exactly that release and verifies it',
      () async {
    serveRelease();
    final data = [release('0.8.3'), release('0.10.0')];
    responses[GitHubUpdates.releasesUri.toString()] =
        () => response(utf8.encode(jsonEncode(data)));
    final old = data.first['assets'] as List;
    responses[old[0]['browser_download_url'] as String] =
        () => response([1, 2, 3]);
    responses[old[1]['browser_download_url'] as String] = () => response(
        utf8.encode('${sha256.convert([1, 2, 3])}  ${old[0]['name']}'));
    final updates = updater();
    addTearDown(updates.dispose);
    await updates.check();
    expect(updates.versions.map((r) => r.tag), ['v0.10.0', 'v0.8.3']);
    updates.selectVersion('v0.8.3');
    await updates.download();
    expect(updates.downloadedFile!.path, contains('0.8.3'));
    await updates.openInstaller();
    expect(launches.single.first, contains('0.8.3'));
  });

  test('macOS opens the verified disk image with separate arguments', () async {
    serveRelease(os: 'macos');
    final updates = updater(os: 'macos');
    addTearDown(updates.dispose);
    await updates.check();
    await updates.download();
    await updates.openInstaller();
    expect(launches.single, ['/usr/bin/open', updates.downloadedFile!.path]);
    expect(updates.downloadedFile!.path, endsWith('.dmg'));
  });

  test(
      'auto check preference survives restart and manual checking remains available',
      () async {
    serveRelease();
    final updates = updater();
    addTearDown(updates.dispose);
    await updates.setAutoCheck(false);
    final restarted = updater();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.autoCheck, isFalse);
    expect(requests, isEmpty);
    await restarted.check();
    expect(restarted.available, isNotNull);
  });

  test('bad checksums and truncated downloads never become installable',
      () async {
    serveRelease(checksum: '0' * 64);
    final updates = updater();
    addTearDown(updates.dispose);
    await updates.check();
    await updates.download();
    expect(updates.downloadedFile, isNull);
    await expectLater(updates.openInstaller(), throwsStateError);
    expect(launches, isEmpty);
    expect(
        directory
            .listSync(recursive: true)
            .any((f) => f.path.endsWith('.part')),
        isFalse);
    serveRelease();
    responses[updates.available!.installer.url.toString()] =
        () => response([1]);
    await updates.download();
    expect(updates.downloadedFile, isNull);
  });

  test('installation rechecks the downloaded file and refuses changed bytes',
      () async {
    serveRelease();
    final updates = updater();
    addTearDown(updates.dispose);
    await updates.check();
    await updates.download();
    await updates.downloadedFile!.writeAsBytes([9, 9, 9]);
    await expectLater(updates.openInstaller(), throwsStateError);
    expect(updates.downloadedFile, isNull);
    expect(launches, isEmpty);
  });

  test('network errors and rate limits allow retry without losing the UI',
      () async {
    final updates = updater();
    addTearDown(updates.dispose);
    responses[GitHubUpdates.releasesUri.toString()] =
        () => response([], status: 403);
    await updates.check();
    expect(updates.checking, isFalse);
    expect(updates.available, isNull);
    expect(updates.status, contains('失败'));
    responses[GitHubUpdates.releasesUri.toString()] =
        () => response(utf8.encode('not json'));
    await updates.check();
    expect(updates.checking, isFalse);
    serveRelease();
    await updates.check();
    expect(updates.available, isNotNull);
  });

  test(
      'cancelling an in-flight download removes partial files and permits retry',
      () async {
    serveRelease();
    final updates = updater();
    addTearDown(updates.dispose);
    await updates.check();
    final gate = StreamController<List<int>>();
    final started = Completer<void>();
    responses[updates.available!.installer.url.toString()] = () {
      started.complete();
      return UpdateResponse(200, gate.stream);
    };
    final downloading = updates.download();
    await started.future;
    updates.cancelDownload();
    gate.add([1, 2, 3]);
    await gate.close();
    await downloading;
    expect(updates.downloadedFile, isNull);
    expect(updates.status, '已取消下载');
    expect(
        directory
            .listSync(recursive: true)
            .any((f) => f.path.endsWith('.part')),
        isFalse);
    serveRelease();
    await updates.download();
    expect(updates.downloadedFile, isNotNull);
  });
}
