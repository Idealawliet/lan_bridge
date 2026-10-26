import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';

import 'core/bridge_controller.dart';
import 'core/lan_workspace.dart';
import 'core/desktop_lifecycle.dart';
import 'core/lan_discovery.dart';
import 'screen_workspace.dart';

const _ink = Color(0xFF202434);
const _muted = Color(0xFF858995);
const _teal = Color(0xFF635BDB);
const _border = Color(0xFFE8E9EF);
const _canvas = Color(0xFFF7F7FA);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LanBridgeApp());
}

class LanBridgeApp extends StatelessWidget {
  const LanBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LAN Bridge · 跨屏协作',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _teal),
        scaffoldBackgroundColor: _canvas,
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'sans-serif'
        ],
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: _ink, height: 1.55),
          bodySmall: TextStyle(color: _muted, height: 1.5),
          titleMedium: TextStyle(color: _ink, fontWeight: FontWeight.w700),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8FAF9),
          isDense: true,
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _border),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _teal,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            side: const BorderSide(color: _border),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: const BridgeDashboard(),
    );
  }
}

class BridgeDashboard extends StatefulWidget {
  const BridgeDashboard({super.key, this.controller, this.workspace});
  final BridgeController? controller;
  final LanWorkspace? workspace;

  @override
  State<BridgeDashboard> createState() => _BridgeDashboardState();
}

class _BridgeDashboardState extends State<BridgeDashboard> {
  late final _localBridge =
      widget.workspace?.local ?? widget.controller ?? BridgeController();
  late final _workspace = widget.workspace ?? LanWorkspace(_localBridge);
  BridgeController get _bridge => _workspace.active?.controller ?? _localBridge;
  final _address = TextEditingController();
  late final AppLifecycleListener _lifecycle;
  late final DesktopLifecycle _desktopLifecycle;
  bool _initializing = true;

  bool get _locked =>
      _initializing ||
      _workspace.running ||
      _bridge.phase != ConnectionPhase.idle;
  bool get _canStart =>
      !_initializing && _bridge.supported && _bridge.permissionsGranted;

  @override
  void initState() {
    super.initState();
    _localBridge.addListener(_refresh);
    _workspace.addListener(_refresh);
    _desktopLifecycle = DesktopLifecycle(_prepareQuit)..install();
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await _prepareQuit();
      return AppExitResponse.exit;
    });
    _updateTray();
    unawaited(_initialize());
  }

  Future<void> _prepareQuit() async {
    await _workspace.stop();
    await _localBridge.disconnect();
  }

  Future<void> _initialize() async {
    await _run(_localBridge.initialize);
    if (mounted) setState(() => _initializing = false);
  }

  String? _lastTrayStatus;
  void _updateTray() {
    final bridge = _bridge;
    final control = bridge.connected && bridge.remoteActive
        ? bridge.role == BridgeRole.target
            ? '本机正被远端控制'
            : '正在控制远端：${_workspace.active?.device.name ?? bridge.peerAddress ?? "远端电脑"}'
        : bridge.connected && bridge.role == BridgeRole.target
            ? '当前控制：远端主机（非本机）'
            : '正在控制本机';
    final signal = !bridge.connected
        ? '未连接'
        : bridge.latencyMs == null
            ? '信号：测量中'
            : '延迟 ${bridge.latencyMs!.round()} ms · 抖动 ${bridge.jitterMs.round()} ms';
    final key = '$control|$signal|${bridge.signalBars}';
    if (_lastTrayStatus == key) return;
    _lastTrayStatus = key;
    unawaited(_desktopLifecycle.updateStatus(
        control: control, signal: signal, bars: bridge.signalBars ?? 0));
  }

  void _refresh() {
    _updateTray();
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已复制$label'), duration: const Duration(seconds: 2)),
      );
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _desktopLifecycle.dispose();
    _workspace.removeListener(_refresh);
    _localBridge.removeListener(_refresh);
    unawaited(_workspace.close().whenComplete(_localBridge.dispose));
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1160),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _header(),
                        const SizedBox(height: 24),
                        _screenLayout(),
                        const SizedBox(height: 16),
                        if (!_initializing && !_bridge.supported)
                          _notice(Icons.desktop_access_disabled_outlined,
                              '当前平台不可用', '请在 Windows 或 macOS 上运行。',
                              warning: true)
                        else if (!_initializing && !_bridge.permissionsGranted)
                          _permissionNotice(),
                        if (_bridge.error != null)
                          _notice(Icons.error_outline, '连接异常', _bridge.error!,
                              warning: true),
                        if (_bridge.files != null) ...[
                          const SizedBox(height: 16),
                          _sharingPanel()
                        ],
                        if (_bridge.connected || _workspace.running) ...[
                          const SizedBox(height: 16),
                          _recoveryBar()
                        ],
                      ])))));

  Widget _header() {
    return Row(
      children: [
        const _Brand(),
        const Spacer(),
        IconButton(
          tooltip: '设置',
          onPressed: _openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 8),
        Container(
          decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(30)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.computer_outlined, size: 16, color: _muted),
            const SizedBox(width: 7),
            Text(_bridge.platformName,
                style: const TextStyle(fontSize: 12, color: _muted))
          ]),
        ),
      ],
    );
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: _workspace,
        builder: (context, _) => AlertDialog(
          title: const Text('设置'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _rolePanel(),
                const SizedBox(height: 16),
                _connectionPanel(),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            )
          ],
        ),
      ),
    );
  }

  Future<void> _joinDevice(LanDevice device,
      {PeerSide? initialSide, double initialOffset = 0}) async {
    final key = TextEditingController();
    var side = initialSide ??
        PeerSide.values.firstWhere(
            (side) => !_workspace.computers.values
                .any((m) => m.controller.side == side),
            orElse: () => PeerSide.right);
    var offset = initialOffset;
    final pinForm = GlobalKey<FormState>();
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: Text('加入 ${device.name}'),
                  content: Form(
                      key: pinForm,
                      child: SizedBox(
                          width: 380,
                          child: SingleChildScrollView(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                Text(
                                    '${device.host}:${device.port} · ${device.platform}'),
                                const SizedBox(height: 12),
                                const Text('核对客户端名称与地址，输入该客户端显示的6 位 PIN 码。'),
                                const SizedBox(height: 12),
                                TextFormField(
                                    controller: key,
                                    autofocus: true,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                      LengthLimitingTextInputFormatter(6)
                                    ],
                                    validator: (value) =>
                                        RegExp(r'^\d{6}$').hasMatch(value ?? '')
                                            ? null
                                            : '请输入 6 位数字 PIN 码',
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                        labelText: '客户端 PIN 码')),
                                const SizedBox(height: 16),
                                Wrap(spacing: 8, children: [
                                  for (final entry in const {
                                    PeerSide.left: '左',
                                    PeerSide.right: '右',
                                    PeerSide.top: '上',
                                    PeerSide.bottom: '下'
                                  }.entries)
                                    ChoiceChip(
                                        label: Text(entry.value),
                                        selected: side == entry.key,
                                        onSelected: (_) =>
                                            update(() => side = entry.key))
                                ]),
                                const Text('相对于服务端主屏幕的位置'),
                                Slider(
                                    value: offset,
                                    min: -.9,
                                    max: .9,
                                    label: '${(offset * 100).round()}%',
                                    onChanged: (value) =>
                                        update(() => offset = value)),
                                const Text('相接区域重叠时，优先进入当前选中的客户端。',
                                    style: TextStyle(fontSize: 12)),
                              ])))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () {
                          if (pinForm.currentState!.validate()) {
                            Navigator.pop(context, true);
                          }
                        },
                        child: const Text('加入控制组'))
                  ],
                )));
    final secret = key.text.trim();
    // The dialog's route may still animate while the text field is mounted.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    key.dispose();
    if (approved == true && mounted) {
      await _run(() => _workspace.add(device, secret, side, offset: offset));
    }
  }

  Widget _multiComputerPanel() {
    final workspace = _workspace;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!workspace.running)
        FilledButton.icon(
          onPressed: !_canStart || workspace.busy
              ? null
              : () => unawaited(_run(_localBridge.role == BridgeRole.source
                  ? workspace.startServer
                  : workspace.startClient)),
          icon: Icon(_localBridge.role == BridgeRole.source
              ? Icons.hub_outlined
              : Icons.desktop_windows_outlined),
          label:
              Text(_localBridge.role == BridgeRole.source ? '启动服务端' : '启动客户端'),
        )
      else ...[
        Row(children: [
          Expanded(
              child: Text(workspace.serving
                  ? '服务端 · 已连接 ${workspace.computers.length} 台客户端'
                  : '客户端 · ${_localBridge.statusText}')),
          TextButton(
            onPressed:
                workspace.busy ? null : () => unawaited(_run(workspace.stop)),
            child: const Text('停止服务'),
          ),
        ]),
        if (!workspace.serving && _localBridge.listening)
          Row(children: [
            const Text('配对 PIN 码  '),
            SelectableText(_localBridge.pairingKey,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 24,
                    letterSpacing: 6,
                    fontWeight: FontWeight.bold)),
            IconButton(
                onPressed: () =>
                    unawaited(_copy(_localBridge.pairingKey, 'PIN 码')),
                tooltip: '复制 PIN 码',
                icon: const Icon(Icons.copy_outlined)),
          ]),
      ],
      if (_bridge.connected)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            const Icon(Icons.mouse, color: _teal, size: 20),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    _bridge.remoteActive
                        ? '当前控制：${workspace.serving ? (workspace.active?.device.name ?? '客户端') : '本机客户端'}'
                        : '当前控制：${workspace.serving ? '本机服务端' : '服务端电脑'}',
                    style: const TextStyle(
                        color: _teal, fontWeight: FontWeight.w700))),
          ]),
        ),
      if (workspace.busy) const LinearProgressIndicator(),
      if (workspace.error != null)
        Text(workspace.error!, style: const TextStyle(color: Colors.red)),
    ]);
  }

  Widget _screenLayout() {
    final multi = _workspace.running && _workspace.serving;
    final nodes = multi
        ? [
            for (final m in _workspace.computers.values)
              ScreenNode(m.device.id, m.device.name, m.controller.side,
                  m.controller.screenOffset,
                  selected: _workspace.active == m,
                  controlling: m.controller.remoteActive)
          ]
        : [
            ScreenNode(
                'local-peer',
                _bridge.role == BridgeRole.target ? '本机 · 被控电脑' : '被控电脑',
                _bridge.side,
                _bridge.screenOffset,
                controlling: _bridge.remoteActive)
          ];
    return _Panel(
        child: Column(children: [
      _multiComputerPanel(),
      const SizedBox(height: 20),
      const Divider(height: 1, color: _border),
      const SizedBox(height: 24),
      ScreenWorkspace(
        nodes: nodes,
        referenceActive: !_bridge.remoteActive,
        referenceName:
            _bridge.role == BridgeRole.target ? '键鼠主机 · 另一台电脑' : '本机 · 键鼠主机',
        available: multi
            ? _workspace.discovery.devices.values
                .where((d) => !_workspace.computers.containsKey(d.id))
                .toList()
            : [],
        enabled: multi
            ? !_workspace.busy
            : !_initializing &&
                !_bridge.busy &&
                _bridge.role == BridgeRole.source,
        onArrange: (id, side, offset) => unawaited(_run(() => multi
            ? _workspace.arrange(id, side, offset)
            : _bridge.updateArrangement(side, offset))),
        onRequest: (device, side, offset) => unawaited(
            _joinDevice(device, initialSide: side, initialOffset: offset)),
        closeEnabled: !_workspace.busy && !_bridge.busy,
        onClose: multi
            ? (id) => unawaited(_run(() => _workspace.remove(id)))
            : _bridge.connected
                ? (_) => unawaited(_run(_bridge.disconnect))
                : null,
        onSelect: (id) {
          if (multi) unawaited(_run(() => _workspace.focus(id)));
        },
      )
    ]));
  }

  Widget _rolePanel() {
    final local = _localBridge;
    return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _SectionTitle(
          number: '01', title: '这台电脑的角色', subtitle: '服务端提供键鼠，客户端接受控制。'),
      const SizedBox(height: 18),
      _RoleTile(
          title: '服务端 · 键鼠主机',
          description: '使用本机键鼠控制局域网内的客户端',
          icon: Icons.keyboard_alt_outlined,
          selected: local.role == BridgeRole.source,
          onTap: _locked
              ? null
              : () => unawaited(_run(() => local.setRole(BridgeRole.source)))),
      const SizedBox(height: 12),
      _RoleTile(
          title: '客户端 · 被控电脑',
          description: '启动后自动等待服务端连接，使用 PIN 码配对',
          icon: Icons.desktop_windows_outlined,
          selected: local.role == BridgeRole.target,
          onTap: _locked
              ? null
              : () => unawaited(_run(() => local.setRole(BridgeRole.target)))),
      const Divider(height: 28),
      SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('开机自启'),
          subtitle: const Text('登录后打开应用，连接需手动启动。'),
          value: local.loginStartup,
          onChanged: !local.supported || local.startupBusy
              ? null
              : (value) => unawaited(local.setLoginStartup(value))),
      if (local.settingsError != null)
        Text(local.settingsError!, style: const TextStyle(color: Colors.red)),
      if (_locked)
        const Text('停止服务后可切换角色；连接期间可拖拽屏幕调整布局。',
            style: TextStyle(color: _muted, fontSize: 12)),
    ]));
  }

  Widget _connectionPanel() {
    final local = _localBridge;
    return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _SectionTitle(
          number: '02',
          title: '连接设置',
          subtitle: '两端启动后，服务端拖入客户端并输入其 6 位 PIN 码。'),
      const SizedBox(height: 16),
      Text('本机局域网地址：${local.localAddresses.join('、')}'),
      if (local.role == BridgeRole.source) ...[
        const SizedBox(height: 16),
        TextField(
            controller: _address,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: '客户端 IP 地址', hintText: '例如 192.168.1.24')),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: !_workspace.running ||
                    !_workspace.serving ||
                    _workspace.busy
                ? null
                : () async {
                    final host = _address.text.trim();
                    if (host.isEmpty || host == '0.0.0.0') {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请输入客户端实际的局域网 IP 地址')));
                      return;
                    }
                    await _joinDevice(LanDevice(
                        id: 'manual-$host',
                        name: host,
                        platform: 'desktop',
                        host: host,
                        port: local.port,
                        busy: false,
                        seen: DateTime.now()));
                  },
            icon: const Icon(Icons.link),
            label: const Text('通过 IP 添加客户端')),
      ],
    ]));
  }

  Widget _permissionNotice() {
    return _Panel(
      padding: const EdgeInsets.all(18),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 18,
        runSpacing: 14,
        children: [
          const Icon(Icons.admin_panel_settings_outlined, color: _teal),
          const SizedBox(
              width: 330,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('先允许系统输入权限',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('macOS 需开启“辅助功能”和“输入监控”；授权后重新打开客户端。',
                        style: TextStyle(color: _muted, fontSize: 12))
                  ])),
          OutlinedButton(
              onPressed: () => unawaited(_run(_bridge.requestPermissions)),
              child: const Text('检查 / 请求权限')),
        ],
      ),
    );
  }

  Widget _notice(IconData icon, String title, String message,
      {bool warning = false}) {
    final color = warning ? const Color(0xFF966326) : _teal;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: warning ? const Color(0xFFFFF5E7) : const Color(0xFFEAF6F0),
          borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 4),
          SelectableText(message, style: TextStyle(color: color, fontSize: 12))
        ]))
      ]),
    );
  }

  Widget _recoveryBar() => Row(children: [
        const Icon(Icons.keyboard_outlined, size: 18, color: _muted),
        const SizedBox(width: 8),
        Expanded(
            child: Text(
                _bridge.platformName == 'macOS'
                    ? 'Control + Option + Esc 返回本机'
                    : 'Ctrl + Alt + Esc 返回本机',
                style: const TextStyle(color: _muted, fontSize: 12))),
        TextButton.icon(
            onPressed: () => unawaited(_run(_workspace.running
                ? _workspace.stop
                : _bridge.emergencyReturn)),
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('返回本机')),
      ]);

  Widget _sharingPanel() {
    final files = _bridge.files!;
    final clipboard = _bridge.clipboard;
    Future<void> sendPaths(List<String> paths) async {
      if (paths.isNotEmpty) await _run(() => files.sendPaths(paths));
    }

    String bytes(int value) => value < 1024 * 1024
        ? '${(value / 1024).toStringAsFixed(1)} KiB'
        : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
    return _Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('剪贴板与文件互通',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      if (clipboard != null)
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('双向剪贴板同步'),
          subtitle: Text(clipboard.status),
          value: clipboard.enabled,
          onChanged: clipboard.setEnabled,
        ),
      const Text(
          '跨屏拖放：从资源管理器或 Finder 拖动文件到屏幕接缝，保持按住鼠标。准备完成后继续拖到另一端的目标目录，再松开。原文件不会删除。',
          style: TextStyle(color: _muted, fontSize: 13)),
      if (_bridge.dragStatus != null)
        Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_bridge.dragStatus!,
                style: const TextStyle(color: _teal))),
      const SizedBox(height: 16),
      DropTarget(
        enable: _bridge.connected && !files.sending,
        onDragDone: (details) =>
            unawaited(sendPaths(details.files.map((f) => f.path).toList())),
        child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: _canvas,
                border: Border.all(color: _border),
                borderRadius: BorderRadius.circular(12)),
            child: const Column(children: [
              Icon(Icons.drive_folder_upload_outlined, color: _teal, size: 30),
              SizedBox(height: 8),
              Text('也可把文件或文件夹拖到这里发送'),
              Text('对方确认后，保存到下载目录 / LAN Bridge',
                  style: TextStyle(color: _muted, fontSize: 12))
            ])),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        OutlinedButton.icon(
            onPressed: files.sending
                ? null
                : () async {
                    final selected = await openFiles();
                    await sendPaths(selected.map((f) => f.path).toList());
                  },
            icon: const Icon(Icons.attach_file),
            label: const Text('选择文件')),
        OutlinedButton.icon(
            onPressed: files.sending
                ? null
                : () async {
                    final selected = await getDirectoryPath();
                    if (selected != null) await sendPaths([selected]);
                  },
            icon: const Icon(Icons.folder_outlined),
            label: const Text('选择文件夹')),
        if (files.sending || files.receiving)
          TextButton(
              onPressed: () => unawaited(_run(files.cancel)),
              child: const Text('取消传输')),
      ]),
      if (files.offer != null && !files.receiving) ...[
        const SizedBox(height: 12),
        Text(
            '对方发送：${files.offer!.name} · ${bytes(files.offer!.bytes)} · ${files.offer!.count} 个条目'),
        Wrap(spacing: 12, children: [
          FilledButton(
              onPressed: () => unawaited(_run(files.accept)),
              child: const Text('接收')),
          TextButton(
              onPressed: () => unawaited(_run(files.reject)),
              child: const Text('拒绝'))
        ]),
      ],
      if (files.sending) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(
            value: files.sendTotal == 0
                ? null
                : files.sentBytes / files.sendTotal),
        Text('发送 ${bytes(files.sentBytes)} / ${bytes(files.sendTotal)}')
      ],
      if (files.receiving) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(
            value: files.receiveTotal == 0
                ? null
                : files.receivedBytes / files.receiveTotal),
        Text('接收 ${bytes(files.receivedBytes)} / ${bytes(files.receiveTotal)}')
      ],
      const SizedBox(height: 10),
      SelectableText(files.status,
          style: const TextStyle(color: _muted, fontSize: 12)),
    ]));
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: _teal, borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.swap_horiz_rounded,
                color: Colors.white, size: 25)),
        const SizedBox(width: 10),
        const Text('LAN Bridge',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: _ink)),
      ]);
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(24)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
                color: Color(0x06242A4A), blurRadius: 24, offset: Offset(0, 8))
          ]),
      child: Material(type: MaterialType.transparency, child: child));
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(
      {required this.number, required this.title, required this.subtitle});
  final String number;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(number,
              style: const TextStyle(
                  color: _teal, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)))
        ]),
        const SizedBox(height: 7),
        Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12))
      ]);
}

class _RoleTile extends StatelessWidget {
  const _RoleTile(
      {required this.title,
      required this.description,
      required this.icon,
      required this.selected,
      required this.onTap});
  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      child: Material(
        color: selected ? const Color(0xFFF0F8F4) : Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
                color: selected ? const Color(0xFF73B9AA) : _border,
                width: selected ? 1.4 : 1)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 17),
            child: Row(children: [
              Icon(icon, color: selected ? _teal : _muted, size: 25),
              const SizedBox(width: 13),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 13,
                            color: selected ? _teal : _ink,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(description,
                        style: const TextStyle(color: _muted, fontSize: 11))
                  ])),
              const SizedBox(width: 10),
              Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? _teal : const Color(0xFFB5C3C2),
                  size: 18)
            ]),
          ),
        ),
      ),
    );
  }
}
