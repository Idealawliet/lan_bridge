import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Per-user preferences. Pairing keys are deliberately never persisted.
class DesktopSettings {
  DesktopSettings(
      {Future<Directory> Function()? directory,
      this.fileName = 'settings.json'})
      : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  final String fileName;
  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));
  Future<Map<String, dynamic>> load() async {
    final file = await _file();
    if (!await file.exists()) return {};
    return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map);
  }

  Future<void> save(Map<String, dynamic> data) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    // Writes are serialized by the controller.
    if (Platform.isWindows && await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

/// Starts this installed copy at user login, without enabling remote control.
class LoginStartup {
  LoginStartup(
      {String? operatingSystem,
      String? executable,
      String? home,
      Future<ProcessResult> Function(String, List<String>)? run})
      : _os = operatingSystem ?? Platform.operatingSystem,
        _executable = executable ?? Platform.resolvedExecutable,
        _home = home ?? Platform.environment['HOME'],
        _run = run ?? ((program, args) => Process.run(program, args));
  final String _os, _executable;
  final String? _home;
  final Future<ProcessResult> Function(String, List<String>) _run;
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  Future<File> _agent() async {
    final home = _home;
    if (home == null) throw StateError('无法确定用户目录');
    return File(
        p.join(home, 'Library', 'LaunchAgents', 'com.lanbridge.login.plist'));
  }

  Future<bool> enabled() async {
    if (_os == 'windows') {
      final result =
          await _run('reg.exe', ['query', _runKey, '/v', 'LANBridge']);
      return result.exitCode == 0;
    }
    if (_os == 'macos') return (await _agent()).exists();
    return false;
  }

  Future<void> setEnabled(bool value) async {
    if (_os == 'windows') {
      if (!value && !await enabled()) return;
      final result = await _run(
          'reg.exe',
          value
              ? [
                  'add',
                  _runKey,
                  '/v',
                  'LANBridge',
                  '/t',
                  'REG_SZ',
                  '/d',
                  '"$_executable"',
                  '/f'
                ]
              : ['delete', _runKey, '/v', 'LANBridge', '/f']);
      if (result.exitCode != 0) throw StateError('无法更新登录启动项：${result.stderr}');
    } else if (_os == 'macos') {
      final file = await _agent();
      if (!value) {
        if (await file.exists()) await file.delete();
        return;
      }
      final executable = _executable;
      if (!executable.contains('.app/Contents/MacOS/')) {
        throw StateError('请先将应用安装到固定位置后再开启自启');
      }
      final escaped = executable
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&apos;');
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.lanbridge.login</string>
<key>ProgramArguments</key><array><string>$escaped</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
''', flush: true);
      await temporary.rename(file.path);
    } else {
      throw UnsupportedError('仅 Windows 和 macOS 支持登录启动');
    }
  }
}
