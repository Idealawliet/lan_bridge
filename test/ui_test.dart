import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/bridge_controller.dart';
import 'package:lan_bridge/main.dart';
import 'package:lan_bridge/core/lan_workspace.dart';
import 'package:lan_bridge/core/lan_discovery.dart';
import 'package:lan_bridge/core/secure_transport.dart';
import 'package:lan_bridge/screen_workspace.dart';

class _PreviewController extends BridgeController {
  @override
  Future<void> listen({bool discoveredClient = false}) async {
    pairingKey = '123456';
    phase = ConnectionPhase.listening;
    notifyListeners();
  }

  void setControl(BridgeRole nextRole, bool active, {bool connected = true}) {
    role = nextRole;
    remoteActive = active;
    phase = connected ? ConnectionPhase.connected : ConnectionPhase.idle;
    notifyListeners();
  }

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
  LanDevice? requested;
  @override
  void requestConnection(LanDevice device) {
    requested = device;
  }

  @override
  Future<void> start({int port = LanDiscovery.discoveryPort}) async {}
}

class _PreviewWorkspace extends LanWorkspace {
  _PreviewWorkspace(super.local) : super(discovery: _PreviewDiscovery());
  void refreshLayout() => notifyListeners();
}

void main() {
  testWidgets(
      'layout only shows real connected clients before start, after leave and after stop',
      (tester) async {
    final workspace = _PreviewWorkspace(_PreviewController());
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(workspace: workspace)));
    await tester.pumpAndSettle();
    ScreenWorkspace layout() =>
        tester.widget<ScreenWorkspace>(find.byType(ScreenWorkspace));
    expect(layout().nodes, isEmpty);
    expect(find.byKey(const ValueKey('screen-local-peer')), findsNothing);
    await tester.tap(find.text('启动服务端'));
    await tester.pumpAndSettle();
    expect(layout().nodes, isEmpty);
    expect(find.text('服务端 · 已连接 0 台客户端'), findsOneWidget);
    final client = _PreviewController()..setControl(BridgeRole.source, false);
    final device = LanDevice(
        id: 'real-client',
        name: '真实客户端',
        platform: 'test',
        host: '192.168.1.2',
        port: 24872,
        busy: false,
        seen: DateTime.now());
    workspace.computers[device.id] = ControlledComputer(device, client);
    workspace.refreshLayout();
    await tester.pumpAndSettle();
    expect(layout().nodes.map((node) => node.id), ['real-client']);
    expect(find.text('服务端 · 已连接 1 台客户端'), findsOneWidget);
    client.setControl(BridgeRole.source, false, connected: false);
    workspace.refreshLayout();
    await tester.pumpAndSettle();
    expect(layout().nodes, isEmpty);
    expect(find.byKey(const ValueKey('screen-real-client')), findsNothing);
    expect(find.text('服务端 · 已连接 0 台客户端'), findsOneWidget);
    await workspace.stop();
    await tester.pumpAndSettle();
    expect(layout().nodes, isEmpty);
    expect(find.byKey(const ValueKey('screen-local-peer')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'client starts from home, requests a server and can approve control',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final discovery = _PreviewDiscovery();
    final controller = _PreviewController();
    final workspace = LanWorkspace(controller, discovery: discovery);
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(workspace: workspace)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动客户端'));
    await tester.pumpAndSettle();
    expect(controller.role, BridgeRole.target);
    expect(find.text('123456'), findsOneWidget);
    final layout = tester.widget<ScreenWorkspace>(find.byType(ScreenWorkspace));
    expect(layout.nodes, isEmpty);
    expect(layout.referenceName, '本机 · 被控电脑');
    final serverId = generatePairingKey();
    final metadata = <String, dynamic>{
      'op': 'server',
      'id': serverId,
      'name': '键鼠电脑',
      'platform': 'windows',
      'port': 24872,
      'busy': false,
    };
    discovery.ingest(metadata, '192.168.1.2', DateTime.now());
    await tester.pumpAndSettle();
    await tester.tap(find.text('申请加入'));
    expect(discovery.requested!.id, serverId);
    discovery.ingest({
      ...metadata,
      'op': 'request',
      'kind': 'control',
      'target': discovery.id,
      'request': generatePairingKey()
    }, '192.168.1.2', DateTime.now());
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许控制'));
    await tester.pumpAndSettle();
    expect(discovery.incomingRequests.values.single.status, 'accepted');
    expect(find.text('已同意，请将本机 PIN 告知服务端完成配对'), findsOneWidget);
    expect(controller.connected, isFalse);
    controller.setControl(BridgeRole.target, false);
    await tester.pumpAndSettle();
    expect(find.text('离开服务端'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('tray follows actual control ownership and disconnect recovery',
      (tester) async {
    const channel = MethodChannel('lan_bridge/lifecycle');
    final statuses = <Map<Object?, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateStatus') {
        statuses.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = _PreviewController();
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(controller: controller)));
    await tester.pumpAndSettle();
    expect(statuses.last['control'], '正在控制本机');
    controller.setControl(BridgeRole.source, false);
    await tester.pumpAndSettle();
    expect(statuses.last['control'], '正在控制本机');
    controller.setControl(BridgeRole.source, true);
    await tester.pumpAndSettle();
    expect(statuses.last['control'], startsWith('正在控制远端：'));
    controller.setControl(BridgeRole.target, true);
    await tester.pumpAndSettle();
    expect(statuses.last['control'], '本机正被远端控制');
    controller.setControl(BridgeRole.target, false);
    await tester.pumpAndSettle();
    expect(statuses.last['control'], '当前控制：远端主机（非本机）');
    controller.setControl(BridgeRole.source, false, connected: false);
    await tester.pumpAndSettle();
    expect(statuses.last, {'control': '正在控制本机', 'signal': '未连接', 'bars': 0});
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

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
    expect(find.text('设计电脑'), findsNWidgets(2));
    expect(workspace.computers, isEmpty);
    await tester.tap(find.text('申请控制'));
    expect(discovery.requested!.name, '设计电脑');
    await tester.tap(find.text('已有 PIN，直接连接'));
    await tester.pumpAndSettle();
    expect(find.text('客户端 PIN 码'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(workspace.computers, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'startup choices stay on home and connection preferences stay in settings',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _PreviewController();
    await tester
        .pumpWidget(MaterialApp(home: BridgeDashboard(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-local-peer')), findsNothing);
    expect(find.text('启动服务端'), findsOneWidget);
    expect(find.text('启动客户端'), findsOneWidget);
    expect(find.text('连接设置'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('连接设置'), findsOneWidget);
    expect(find.text('常规设置'), findsOneWidget);
    expect(find.text('客户端 · 被控电脑'), findsNothing);
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
      expect(find.text('开始协作'), findsOneWidget);
      expect(find.text('屏幕布局'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
