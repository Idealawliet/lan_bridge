import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/desktop_settings.dart';

void main() {
  test('preferences round trip and replace previous settings', () async {
    final directory = await Directory.systemTemp.createTemp('lan-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final settings = DesktopSettings(directory: () async => directory);
    expect(await settings.load(), isEmpty);
    await settings.save({
      'side': 'top',
      'offset': .4,
      'role': 'source',
      'connectionMode': 'server'
    });
    expect((await settings.load())['offset'], .4);
    await settings.save({'side': 'bottom', 'offset': -.2});
    expect(await settings.load(), {'side': 'bottom', 'offset': -.2});
    expect(directory.listSync().length, 1);
  });
  test('Windows login uses quoted executable and current-user registry only',
      () async {
    final calls = <List<String>>[];
    var active = false;
    final startup = LoginStartup(
        operatingSystem: 'windows',
        executable: r'C:\Apps & Tools\LAN Bridge\lan_bridge.exe',
        run: (program, args) async {
          expect(program, 'reg.exe');
          calls.add(args);
          if (args.first == 'add') active = true;
          if (args.first == 'delete') active = false;
          return ProcessResult(
              1, args.first == 'query' && !active ? 1 : 0, '', '');
        });
    expect(await startup.enabled(), isFalse);
    await startup.setEnabled(true);
    expect(await startup.enabled(), isTrue);
    final add = calls.firstWhere((args) => args.first == 'add');
    expect(add[1], startsWith('HKCU\\'));
    expect(add[add.indexOf('/d') + 1],
        r'"C:\Apps & Tools\LAN Bridge\lan_bridge.exe"');
    await startup.setEnabled(false);
    expect(await startup.enabled(), isFalse);
  });
  test('registry errors are surfaced', () async {
    final startup = LoginStartup(
        operatingSystem: 'windows',
        run: (program, args) async => ProcessResult(1, 5, '', 'denied'));
    await expectLater(startup.setEnabled(true), throwsStateError);
  });
  test('macOS launch agent escapes paths and can be removed idempotently',
      () async {
    final home = await Directory.systemTemp.createTemp('lan-login-');
    addTearDown(() => home.delete(recursive: true));
    final startup = LoginStartup(
        operatingSystem: 'macos',
        home: home.path,
        executable: '/Applications/A&B <test>.app/Contents/MacOS/lan_bridge');
    expect(await startup.enabled(), isFalse);
    await startup.setEnabled(true);
    expect(await startup.enabled(), isTrue);
    final file =
        File('${home.path}/Library/LaunchAgents/com.lanbridge.login.plist');
    final content = await file.readAsString();
    expect(content, contains('A&amp;B &lt;test&gt;.app'));
    expect(content, contains('<key>RunAtLoad</key><true/>'));
    expect(content, isNot(contains('KeepAlive')));
    await startup.setEnabled(false);
    await startup.setEnabled(false);
    expect(await startup.enabled(), isFalse);
  });
}
