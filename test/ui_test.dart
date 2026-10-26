import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/bridge_controller.dart';
import 'package:lan_bridge/main.dart';
import 'package:lan_bridge/core/lan_workspace.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/secure_transport.dart';

class _PreviewController extends BridgeController {
  @override
  Future<void> initialize() async {
    supported = true;
    permissionsGranted = true;
  }

  @override
  Future<void> disconnect() async {}
}

class _ConnectedPreviewController extends _PreviewController {
  @override
  Future<void> initialize() async {
    await super.initialize();
    phase = ConnectionPhase.connected;
  }

  @override
  Future<void> updateArrangement(PeerSide value, double offset) async {
    side = value;
    screenOffset = offset;
    notifyListeners();
  }
}

class _PreviewDiscovery extends LanDiscovery {
  @override
  Future<void> start({int port = LanDiscovery.discoveryPort}) async {}
}

void main() {
  testWidgets('connected source keeps screen dragging enabled', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _ConnectedPreviewController();
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(controller: controller)));
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('screen-local-peer'));
    final size = tester.getSize(target);
    await tester.drag(target, Offset(-size.width, -size.height),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(controller.side, PeerSide.top);
    expect(controller.connected, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('server lists discovered clients and requires explicit pairing',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final discovery = _PreviewDiscovery();
    final workspace = LanWorkspace(_PreviewController(), discovery: discovery);
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(workspace: workspace)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动服务端'));
    await tester.pumpAndSettle();
    discovery.ingest({
      'op': 'client',
      'id': generatePairingKey(),
      'name': '设计电脑',
      'platform': 'macos',
      'port': 24872,
      'busy': false
    }, '192.168.1.55', DateTime.now());
    await tester.pumpAndSettle();
    expect(find.text('设计电脑'), findsOneWidget);
    expect(workspace.computers, isEmpty);
    final canvas = find.byType(DragTarget<LanDevice>);
    final targetBox = tester.getRect(canvas);
    final card = tester.getCenter(find.text('设计电脑'));
    await tester.dragFrom(card, targetBox.center - card,
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('客户端 PIN 码'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(workspace.computers, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'layout can change and settings combine computer and connection roles',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(controller: controller)));
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('screen-local-peer'));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    final size = tester.getSize(target);
    await tester.drag(target, Offset(-size.width, -size.height),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(controller.side, PeerSide.top);
    expect(find.text('连接设置'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('连接设置'), findsOneWidget);
    final client = find.text('客户端 · 被控电脑');
    await tester.ensureVisible(client);
    await tester.tap(client);
    await tester.pumpAndSettle();
    expect(controller.connectionMode, ConnectionMode.client);
    expect(controller.role, BridgeRole.target);
    expect(find.text('允许被发现'), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('启动客户端'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final size in [
    const Size(1280, 900),
    const Size(800, 900),
    const Size(600, 800)
  ]) {
    testWidgets('desktop setup fits ${size.width} wide window', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
          MaterialApp(home: BridgeDashboard(controller: _PreviewController())));
      await tester.pumpAndSettle();
      expect(find.text('LAN Bridge'), findsOneWidget);
      expect(find.text('开始协作'), findsNothing);
      expect(find.text('屏幕布局'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
