// Generate with flutter test --dart-define=GENERATE_SCREENSHOTS=true test/screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/main.dart';
import 'package:lan_bridge/core/bridge_controller.dart';
import 'package:lan_bridge/core/lan_workspace.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/github_updates.dart';
import 'package:lan_bridge/sharing/file_transfer.dart';

class PreviewController extends BridgeController {
  @override
  Future<void> initialize() async {
    supported = true;
    permissionsGranted = true;
  }

  @override
  Future<void> disconnect() async {}
}

class PreviewDiscovery extends LanDiscovery {
  @override
  Future<void> start({int port = LanDiscovery.discoveryPort}) async {}
}

class PreviewUpdates extends GitHubUpdates {
  PreviewUpdates() : super(operatingSystem: 'windows');
  @override
  Future<void> initialize() async {
    versions = [
      for (final version in ['0.11.7', '0.11.6', '0.11.5'])
        GitHubUpdates.selectRelease([
          {
            'tag_name': 'v$version',
            'draft': false,
            'prerelease': true,
            'body': '传输界面显示文件名称、大小、进度与拖放结果。',
            'assets': [
              for (final name in [
                'lan-bridge-windows-x64-$version-setup-unsigned.exe',
                'lan-bridge-windows-x64-$version-setup-unsigned.exe.sha256'
              ])
                {
                  'name': name,
                  'size': 100,
                  'browser_download_url':
                      'https://github.com/Idealawliet/lan_bridge/releases/download/v$version/$name'
                }
            ],
          }
        ], 'windows', currentVersion, includeOlder: true)!
    ];
    available = versions.first;
    notifyListeners();
  }
}

void main() {
  testWidgets(
      'render actual application screenshots with clearly labeled demo devices',
      (tester) async {
    await tester.runAsync(() async {
      final font = FontLoader('Roboto')
        ..addFont(File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(File(
                '/workspace/.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      await icons.load();
    });
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    final workspace = LanWorkspace(PreviewController(),
        discovery: PreviewDiscovery(), enableSharing: false);
    Future<void> save(String name) async {
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('docs/images/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester
        .runAsync(() => Directory('docs/images').create(recursive: true));
    await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: LanBridgeApp(
            home: BridgeDashboard(
                workspace: workspace, updates: PreviewUpdates()))));
    await save('home');
    final controller = PreviewController()
      ..phase = ConnectionPhase.connected
      ..supported = true
      ..permissionsGranted = true;
    workspace.computers['demo'] = ControlledComputer(
        LanDevice(
            id: 'demo',
            name: '设计电脑 · 演示设备',
            platform: 'macos',
            host: '192.168.1.20',
            port: 24872,
            busy: false,
            seen: DateTime.now()),
        controller);
    workspace.router.focused = 'demo';
    await workspace.startServer();
    await save('server');
    final transfers = FileTransfer(
        send: (_) async {}, receiveDirectory: () async => Directory.systemTemp);
    controller.files = transfers;
    await transfers.receive({
      'op': 'offer',
      'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'name': '项目资料.zip',
      'count': 1,
      'bytes': 5242880,
      'drag': false,
      'y': .5,
    });
    workspace.local.setEdgeTriggerRange(1);
    await tester.pump();
    await tester.ensureVisible(find.text('对方发送：项目资料.zip · 5.0 MiB · 1 个条目'));
    await save('sharing');
    await transfers.close();
    controller.files = null;
    await tester.ensureVisible(find.byTooltip('设置'));
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('屏幕边缘触发范围：100%'));
    await save('settings');
    await tester.ensureVisible(find.text('版本管理 · 升级 / 降级 / 重装'));
    await tester.pumpAndSettle();
    await save('versions');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, skip: !const bool.fromEnvironment('GENERATE_SCREENSHOTS'));
}
