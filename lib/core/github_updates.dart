import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_version.dart';
import 'desktop_settings.dart';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion._(this.numbers, this.pre);
  final List<int> numbers;
  final List<String> pre;
  static ReleaseVersion? parse(String value) {
    if (value.length > 128) return null;
    final match = RegExp(
            r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$')
        .firstMatch(value);
    if (match == null) return null;
    final pre = match[4]?.split('.') ?? <String>[];
    if (pre.any((part) =>
        part.isEmpty ||
        (RegExp(r'^\d+$').hasMatch(part) &&
            part.length > 1 &&
            part.startsWith('0')))) {
      return null;
    }
    if (match[5]?.split('.').any((part) => part.isEmpty) ?? false) return null;
    final numbers = [for (var i = 1; i <= 3; i++) int.tryParse(match[i]!)];
    if (numbers.any((number) => number == null)) return null;
    return ReleaseVersion._(numbers.cast<int>(), pre);
  }

  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = numbers[i].compareTo(other.numbers[i]);
      if (result != 0) return result;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty
          ? 0
          : pre.isEmpty
              ? 1
              : -1;
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = RegExp(r'^\d+$').hasMatch(pre[i]),
          b = RegExp(r'^\d+$').hasMatch(other.pre[i]);
      final result = a && b
          ? pre[i].length == other.pre[i].length
              ? pre[i].compareTo(other.pre[i])
              : pre[i].length.compareTo(other.pre[i].length)
          : a
              ? -1
              : b
                  ? 1
                  : pre[i].compareTo(other.pre[i]);
      if (result != 0) return result;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size);
  final String name;
  final Uri url;
  final int size;
}

class AppRelease {
  const AppRelease(
      {required this.tag,
      required this.version,
      required this.notes,
      required this.prerelease,
      required this.installer,
      required this.checksum});
  final String tag, notes;
  final ReleaseVersion version;
  final bool prerelease;
  final ReleaseAsset installer, checksum;
}

class UpdateResponse {
  UpdateResponse(this.status, this.body);
  final int status;
  final Stream<List<int>> body;
}

abstract class UpdateTransport {
  Future<UpdateResponse> get(Uri uri);
  void close();
}

class GitHubUpdateTransport implements UpdateTransport {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  @override
  Future<UpdateResponse> get(Uri uri) async {
    final request =
        await _client.getUrl(uri).timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.userAgentHeader, 'LAN-Bridge/$appVersion');
    request.headers.set(
        HttpHeaders.acceptHeader,
        uri.host == 'api.github.com'
            ? 'application/vnd.github+json'
            : 'application/octet-stream');
    if (uri.host == 'api.github.com') {
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    return UpdateResponse(
        response.statusCode, response.timeout(const Duration(seconds: 30)));
  }

  @override
  void close() => _client.close(force: true);
}

/// Uses public GitHub Releases; no GitHub credentials are shipped in the app.
class GitHubUpdates extends ChangeNotifier {
  GitHubUpdates(
      {String? operatingSystem,
      this.currentVersion = appVersion,
      UpdateTransport Function()? transportFactory,
      DesktopSettings? settings,
      Future<Directory> Function()? directory,
      Future<void> Function(String, List<String>)? launch})
      : operatingSystem = operatingSystem ?? Platform.operatingSystem,
        _transportFactory = transportFactory ?? GitHubUpdateTransport.new,
        _settings = settings ?? DesktopSettings(fileName: 'updates.json'),
        _directory = directory ??
            (() async => Directory(p.join(
                (await getTemporaryDirectory()).path, 'LAN Bridge Updates'))),
        _launch = launch ?? _launchProcess;
  static final releasesUri = Uri.https('api.github.com',
      '/repos/Idealawliet/lan_bridge/releases', {'per_page': '100'});
  static const maxInstallerBytes = 512 * 1024 * 1024;
  final String operatingSystem, currentVersion;
  final UpdateTransport Function() _transportFactory;
  final DesktopSettings _settings;
  final Future<Directory> Function() _directory;
  final Future<void> Function(String, List<String>) _launch;
  bool autoCheck = true,
      checking = false,
      downloading = false,
      _disposed = false;
  String status = '从 GitHub 检查最新发行版（含预览版）';
  AppRelease? available;
  String? skippedTag;
  List<AppRelease> versions = [];

  void selectVersion(String tag) {
    if (checking || downloading) return;
    final selected =
        versions.where((release) => release.tag == tag).firstOrNull;
    if (selected == null) return;
    available = selected;
    downloadedFile = null;
    _downloadedHash = null;
    status = '已选择 $tag，可下载并安装此版本';
    _notify();
  }

  File? downloadedFile;
  String? _downloadedHash;
  int received = 0;
  int _generation = 0;
  UpdateTransport? _transport;
  Future<void> _settingsQueue = Future.value();
  bool get supported =>
      operatingSystem == 'windows' || operatingSystem == 'macos';
  double? get progress => available == null
      ? null
      : (received / available!.installer.size).clamp(0, 1);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (!supported) return;
    try {
      final settings = await _settings.load();
      autoCheck = settings['autoCheck'] != false;
      skippedTag = settings['skippedTag'] is String
          ? settings['skippedTag'] as String
          : null;
    } catch (_) {/* A broken preference file must not prevent manual checks. */}
    _notify();
    if (!_disposed && autoCheck) await check();
  }

  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    _notify();
    await _savePreferences();
  }

  Future<void> skipVersion(String? tag) async {
    skippedTag = tag;
    _notify();
    await _savePreferences();
  }

  Future<void> _savePreferences() async {
    final preferences = {'autoCheck': autoCheck, 'skippedTag': skippedTag};
    _settingsQueue = _settingsQueue
        .then((_) => _settings.save(preferences))
        .catchError((Object _) {
      status = '无法保存自动检查偏好';
      _notify();
    });
    await _settingsQueue;
  }

  static Uri? _assetUrl(Object? value, String tag, String name) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !listEquals(uri.pathSegments,
            ['Idealawliet', 'lan_bridge', 'releases', 'download', tag, name])) {
      return null;
    }
    return uri;
  }

  static AppRelease? selectRelease(
      List<dynamic> releases, String os, String current,
      {bool includeOlder = false}) {
    final installed = ReleaseVersion.parse(current);
    if (installed == null) throw const FormatException('无法识别当前版本');
    AppRelease? newest;
    for (final data in releases) {
      if (data is! Map ||
          data['draft'] != false ||
          data['tag_name'] is! String ||
          data['assets'] is! List) {
        continue;
      }
      final tag = data['tag_name'] as String;
      final version = ReleaseVersion.parse(tag);
      if (version == null ||
          (!includeOlder && version.compareTo(installed) <= 0) ||
          (newest != null && version.compareTo(newest.version) <= 0)) {
        continue;
      }
      final number = tag.startsWith('v') ? tag.substring(1) : tag;
      final names = os == 'windows'
          ? [
              'lan-bridge-windows-x64-$number-setup.exe',
              'lan-bridge-windows-x64-$number-setup-unsigned.exe'
            ]
          : os == 'macos'
              ? [
                  'lan-bridge-macos-$number.dmg',
                  'lan-bridge-macos-$number-unsigned.dmg'
                ]
              : <String>[];
      ReleaseAsset? installer, checksum;
      for (final name in names) {
        ReleaseAsset? find(String name, int limit) {
          for (final item in data['assets'] as List) {
            if (item is! Map || item['name'] != name) continue;
            final size = item['size'];
            final url = _assetUrl(item['browser_download_url'], tag, name);
            if (url != null && size is int && size > 0 && size <= limit) {
              return ReleaseAsset(name, url, size);
            }
          }
          return null;
        }

        installer = find(name, maxInstallerBytes);
        checksum = find('$name.sha256', 4096);
        if (installer != null && checksum != null) break;
      }
      if (installer == null || checksum == null) continue;
      newest = AppRelease(
          tag: tag,
          version: version,
          notes: data['body'] is String ? data['body'] as String : '',
          prerelease: data['prerelease'] == true,
          installer: installer,
          checksum: checksum);
    }
    return newest;
  }

  Future<List<int>> _read(UpdateTransport transport, Uri uri, int limit) async {
    final response = await transport.get(uri);
    _checkStatus(response.status);
    final bytes = <int>[];
    await for (final chunk in response.body) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('更新信息超过大小限制');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static void _checkStatus(int status) {
    if (status == 403 || status == 429) throw StateError('GitHub 暂时限制请求，请稍后重试');
    if (status != 200) throw HttpException('GitHub 返回 HTTP $status');
  }

  Future<void> check() async {
    if (!supported || checking || downloading || _disposed) return;
    checking = true;
    status = '正在检查 GitHub 最新发行版…';
    _notify();
    final transport = _transportFactory();
    _transport = transport;
    try {
      final data = jsonDecode(
          utf8.decode(await _read(transport, releasesUri, 8 * 1024 * 1024)));
      if (data is! List) throw const FormatException('GitHub 发行信息格式不正确');
      if (_disposed) return;
      final catalog = <String, AppRelease>{};
      for (final entry in data) {
        final release = selectRelease([entry], operatingSystem, currentVersion,
            includeOlder: true);
        if (release != null) catalog[release.tag] = release;
      }
      versions = catalog.values.toList()
        ..sort((a, b) => b.version.compareTo(a.version));
      final latest = selectRelease(data, operatingSystem, currentVersion);
      if (latest?.tag != available?.tag) {
        downloadedFile = null;
        _downloadedHash = null;
      }
      available = latest;
      status = latest == null
          ? '当前已是最新可用版本'
          : '发现新版本 ${latest.tag}${latest.prerelease ? '（预览版）' : ''}';
    } catch (error) {
      if (!_disposed) {
        status = error is StateError
            ? '检查更新失败：${error.message}'
            : '检查更新失败，请检查网络或稍后重试';
      }
    } finally {
      transport.close();
      if (identical(_transport, transport)) _transport = null;
      checking = false;
      _notify();
    }
  }

  Future<void> download() async {
    final release = available;
    if (release == null || downloading || checking || _disposed) return;
    downloading = true;
    received = 0;
    downloadedFile = null;
    _downloadedHash = null;
    final generation = ++_generation;
    final transport = _transportFactory();
    _transport = transport;
    File? partial;
    Directory? attemptDirectory;
    RandomAccessFile? sink;
    var stage = '获取校验文件';
    status = '正在下载 ${release.tag}…';
    _notify();
    try {
      final checksum = utf8
          .decode(await _read(transport, release.checksum.url, 4096))
          .trim();
      final match =
          RegExp(r'^([a-fA-F0-9]{64})\s+\*?(.+)$').firstMatch(checksum);
      if (match == null || match[2] != release.installer.name) {
        throw const FormatException('校验文件格式或文件名不正确');
      }
      final expectedHash = match[1]!.toLowerCase();
      stage = '准备本地文件';
      final directory = await _directory();
      await directory.create(recursive: true);
      // Each attempt has its own destination so a previous installer cannot
      // block or be mistaken for the file currently being downloaded.
      attemptDirectory = await directory.createTemp('download-');
      final destination =
          File(p.join(attemptDirectory.path, release.installer.name));
      partial = File('${destination.path}.part');
      sink = await partial.open(mode: FileMode.write);
      stage = '下载安装包';
      final response = await transport.get(release.installer.url);
      _checkStatus(response.status);
      final digest = _DigestSink();
      final hash = sha256.startChunkedConversion(digest);
      final clock = Stopwatch()..start();
      var lastNotify = -100;
      await for (final chunk in response.body) {
        if (_disposed || generation != _generation) throw StateError('已取消');
        received += chunk.length;
        if (received > release.installer.size || received > maxInstallerBytes) {
          throw const FormatException('安装包大小不匹配');
        }
        hash.add(chunk);
        await sink.writeFrom(chunk);
        if (clock.elapsedMilliseconds - lastNotify >= 100) {
          lastNotify = clock.elapsedMilliseconds;
          _notify();
        }
      }
      hash.close();
      // A .part file is never offered for installation. Verify both the
      // published asset length and checksum before renaming it into place.
      stage = '校验安装包';
      await sink.close();
      sink = null;
      if (_disposed || generation != _generation) throw StateError('已取消');
      if (received != release.installer.size ||
          digest.value?.toString() != expectedHash) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      stage = '保存已校验的安装包';
      final completed = await partial.rename(destination.path);
      if (_disposed || generation != _generation) {
        await completed.delete();
        throw StateError('已取消');
      }
      downloadedFile = completed;
      _downloadedHash = expectedHash;
      status = '下载完成，SHA-256 校验通过，可选择安装';
    } catch (error) {
      final detail = switch (error) {
        FormatException e => e.message,
        HttpException e => e.message,
        FileSystemException e => e.osError?.message ?? e.message,
        SocketException _ => '无法连接服务器，请检查网络',
        TimeoutException _ => '连接超时，请稍后重试',
        StateError e => e.message.toString(),
        _ => '发生未知错误，请稍后重试',
      };
      status = generation != _generation ? '已取消下载' : '$stage失败：$detail';
    } finally {
      try {
        await sink?.close();
        if (partial != null && await partial.exists()) await partial.delete();
        if (downloadedFile == null &&
            attemptDirectory != null &&
            await attemptDirectory.exists()) {
          await attemptDirectory.delete(recursive: true);
        }
      } on FileSystemException {
        // A failed or cancelled partial file is never exposed as installable.
      }
      transport.close();
      if (identical(_transport, transport)) _transport = null;
      downloading = false;
      _notify();
    }
  }

  void cancelDownload() {
    if (!downloading) return;
    _generation++;
    _transport?.close();
    status = '正在取消下载…';
    _notify();
  }

  Future<void> openInstaller() async {
    // The downloaded file may have changed since the progress dialog closed.
    // Recheck it immediately before launching the platform installer.
    final file = downloadedFile;
    if (file == null || _downloadedHash == null || !supported) {
      throw StateError('请先下载并校验安装包');
    }
    if ((await sha256.bind(file.openRead()).first).toString() !=
        _downloadedHash) {
      downloadedFile = null;
      _downloadedHash = null;
      status = '安装包已变化，请重新下载';
      _notify();
      throw StateError(status);
    }
    await _launch(operatingSystem == 'macos' ? '/usr/bin/open' : file.path,
        operatingSystem == 'macos' ? [file.path] : <String>[]);
  }

  static Future<void> _launchProcess(
      String executable, List<String> arguments) async {
    if (Platform.isMacOS) {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) throw StateError('无法打开安装包，请重试');
    } else {
      await Process.start(executable, arguments,
          mode: ProcessStartMode.detached);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _transport?.close();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
