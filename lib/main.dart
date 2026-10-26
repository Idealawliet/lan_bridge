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
  final _key = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final AppLifecycleListener _lifecycle;
  late final DesktopLifecycle _desktopLifecycle;
  bool _initializing = true;
  bool _showKey = false;

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

  void _refresh() {
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

  void _connect() {
    if (_form.currentState?.validate() ?? false) {
      unawaited(
          _run(() => _bridge.connect(_address.text.trim(), _key.text.trim())));
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
    _key.dispose();
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
                        if (!_workspace.running)
                          Material(
                              color: Colors.transparent,
                              child: ExpansionTile(
                                  title: const Text('连接设置',
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600)),
                                  leading: const Icon(Icons.tune, size: 20),
                                  shape: const Border(),
                                  collapsedShape: const Border(),
                                  children: [
                                    LayoutBuilder(
                                        builder: (context, c) => c.maxWidth <
                                                760
                                            ? Column(children: [
                                                _rolePanel(),
                                                const SizedBox(height: 12),
                                                _connectionPanel()
                                              ])
                                            : Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                    Expanded(
                                                        child: _rolePanel()),
                                                    const SizedBox(width: 16),
                                                    Expanded(
                                                        child:
                                                            _connectionPanel())
                                                  ]))
                                  ])),
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

  Future<void> _joinDevice(LanDevice device,
      {PeerSide? initialSide, double initialOffset = 0}) async {
    final key = TextEditingController();
    var side = initialSide ??
        PeerSide.values.firstWhere(
            (side) => !_workspace.computers.values
                .any((m) => m.controller.side == side),
            orElse: () => PeerSide.right);
    var offset = initialOffset;
    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: Text('加入 ${device.name}'),
                  content: SizedBox(
                      width: 380,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                            '${device.host}:${device.port} · ${device.platform}'),
                        const SizedBox(height: 12),
                        const Text('核对客户端名称与地址，输入该客户端显示的完整配对密钥。'),
                        const SizedBox(height: 12),
                        TextField(
                            controller: key,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration:
                                const InputDecoration(labelText: '客户端配对密钥')),
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
                            onChanged: (value) => update(() => offset = value)),
                        const Text('相接区域重叠时，优先进入当前选中的客户端。',
                            style: TextStyle(fontSize: 12)),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
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
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: !_canStart ||
                      workspace.busy ||
                      _localBridge.phase != ConnectionPhase.idle
                  ? null
                  : () => unawaited(_run(workspace.startServer)),
              icon: const Icon(Icons.hub_outlined),
              label: const Text('发现设备')),
          OutlinedButton.icon(
              onPressed: !_canStart ||
                      workspace.busy ||
                      _localBridge.phase != ConnectionPhase.idle
                  ? null
                  : () => unawaited(_run(workspace.startClient)),
              icon: const Icon(Icons.wifi_find),
              label: const Text('允许被发现')),
        ])
      else ...[
        Row(children: [
          Expanded(
              child: Text(workspace.serving
                  ? '●  已连接 ${workspace.computers.length} 台设备'
                  : '客户端已公开 · ${_localBridge.statusText}')),
          TextButton(
              onPressed:
                  workspace.busy ? null : () => unawaited(_run(workspace.stop)),
              child: const Text('停止服务'))
        ]),
        if (!workspace.serving) ...[
          const SizedBox(height: 8),
          if (_localBridge.listening) ...[
            const Text('配对密钥'),
            SelectableText(_localBridge.pairingKey,
                style: const TextStyle(fontFamily: 'monospace')),
            TextButton.icon(
                onPressed: () =>
                    unawaited(_copy(_localBridge.pairingKey, '客户端配对密钥')),
                icon: const Icon(Icons.copy),
                label: const Text('复制密钥')),
          ] else if (!_localBridge.connected)
            const Text('会话已结束。停止服务后重新开启可发现模式，生成新密钥。'),
        ],
      ],
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
                  selected: _workspace.active == m)
          ]
        : [
            ScreenNode(
                'local-peer',
                _bridge.role == BridgeRole.target ? '本机 · 被控电脑' : '被控电脑',
                _bridge.side,
                _bridge.screenOffset)
          ];
    return _Panel(
        child: Column(children: [
      _multiComputerPanel(),
      const SizedBox(height: 20),
      const Divider(height: 1, color: _border),
      const SizedBox(height: 24),
      ScreenWorkspace(
        nodes: nodes,
        referenceName:
            _bridge.role == BridgeRole.target ? '键鼠主机 · 另一台电脑' : '本机 · 键鼠主机',
        available: multi
            ? _workspace.discovery.devices.values
                .where((d) => !_workspace.computers.containsKey(d.id))
                .toList()
            : [],
        enabled: multi
            ? !_workspace.busy
            : !_locked && _bridge.role == BridgeRole.source,
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
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _SectionTitle(
            number: '01', title: '这台电脑的角色', subtitle: '键鼠角色与客户端 / 服务端可分别设置。'),
        const SizedBox(height: 22),
        _RoleTile(
          title: '键鼠主机',
          description: '键盘和鼠标连接在这台电脑上',
          icon: Icons.keyboard_alt_outlined,
          selected: _bridge.role == BridgeRole.source,
          onTap: _locked
              ? null
              : () => unawaited(_run(() => _bridge.setRole(BridgeRole.source))),
        ),
        const SizedBox(height: 12),
        _RoleTile(
          title: '被控电脑',
          description: '使用另一台电脑的键鼠操作本机',
          icon: Icons.desktop_windows_outlined,
          selected: _bridge.role == BridgeRole.target,
          onTap: _locked
              ? null
              : () => unawaited(_run(() => _bridge.setRole(BridgeRole.target))),
        ),
        const SizedBox(height: 18),
        const Divider(height: 28),
        const Text('网络连接方式', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
              label: const Text('客户端 · 主动连接'),
              selected: _bridge.connectionMode == ConnectionMode.client,
              onSelected: _locked
                  ? null
                  : (_) => _bridge.setConnectionMode(ConnectionMode.client)),
          ChoiceChip(
              label: const Text('服务端 · 等待连接'),
              selected: _bridge.connectionMode == ConnectionMode.server,
              onSelected: _locked
                  ? null
                  : (_) => _bridge.setConnectionMode(ConnectionMode.server)),
        ]),
        const SizedBox(height: 8),
        const Text('两端分别选客户端和服务端；任意一端都可提供键鼠。',
            style: TextStyle(color: _muted, fontSize: 12)),
        const Divider(height: 28),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('开机自启', style: TextStyle(fontSize: 14)),
            subtitle: const Text('登录系统后启动应用，保留角色与布局；连接仍需手动配对。',
                style: TextStyle(fontSize: 12)),
            value: _bridge.loginStartup,
            onChanged: !_bridge.supported || _bridge.startupBusy
                ? null
                : (value) => unawaited(_bridge.setLoginStartup(value))),
        if (_bridge.settingsError != null)
          Text(_bridge.settingsError!,
              style: const TextStyle(color: Colors.red, fontSize: 12)),
        const SizedBox(height: 12),
        Text(_locked ? '断开连接或停止等待后，可更改角色和布局。' : '另一台电脑请选择与这里不同的角色。',
            style: const TextStyle(color: _muted, fontSize: 12)),
      ]),
    );
  }

  Widget _connectionPanel() {
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionTitle(
            number: '02',
            title: _bridge.connectionMode == ConnectionMode.client
                ? '连接另一台电脑'
                : '等待客户端连接',
            subtitle: _bridge.connectionMode == ConnectionMode.client
                ? '填写服务端电脑显示的局域网地址和密钥。'
                : '开始等待后，将本机地址和配对密钥交给客户端。'),
        const SizedBox(height: 22),
        if (_bridge.connected)
          _connectedContent()
        else if (_bridge.connectionMode == ConnectionMode.client)
          _sourceContent()
        else
          _targetContent(),
      ]),
    );
  }

  Widget _sourceContent() {
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('服务端 IP 地址',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextFormField(
          controller: _address,
          enabled: !_bridge.busy,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
              hintText: '例如 192.168.1.24',
              prefixIcon: Icon(Icons.lan_outlined, size: 19)),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入服务端的局域网地址' : null,
        ),
        const SizedBox(height: 16),
        const Text('配对密钥',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextFormField(
          controller: _key,
          enabled: !_bridge.busy,
          obscureText: !_showKey,
          autocorrect: false,
          enableSuggestions: false,
          onFieldSubmitted: (_) {
            if (_canStart && !_bridge.busy) _connect();
          },
          decoration: InputDecoration(
              hintText: '粘贴另一台电脑的完整密钥',
              prefixIcon: const Icon(Icons.key_outlined, size: 19),
              suffixIcon: IconButton(
                  tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                  onPressed: () => setState(() => _showKey = !_showKey),
                  icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 19))),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入完整配对密钥' : null,
        ),
        const SizedBox(height: 20),
        if (_bridge.busy)
          OutlinedButton.icon(
              onPressed: () => unawaited(_run(_bridge.disconnect)),
              icon: const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              label: const Text('正在连接 · 取消'))
        else
          FilledButton.icon(
              onPressed: _canStart ? _connect : null,
              icon: const Icon(Icons.link, size: 19),
              label: const Text('建立安全连接')),
      ]),
    );
  }

  Widget _targetContent() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('本机局域网地址',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      if (_bridge.localAddresses.isEmpty)
        const Text('未找到局域网地址，请检查网络连接。',
            style: TextStyle(color: _muted, fontSize: 12))
      else
        Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _bridge.localAddresses
                .map((address) => ActionChip(
                    avatar: const Icon(Icons.copy_outlined, size: 14),
                    label: Text(address, style: const TextStyle(fontSize: 12)),
                    tooltip: '复制 $address',
                    onPressed: () => unawaited(_copy(address, '地址'))))
                .toList()),
      const SizedBox(height: 20),
      if (_bridge.listening) ...[
        const Text('本次配对密钥',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          decoration: BoxDecoration(
              color: const Color(0xFFF0F7F3),
              border: Border.all(color: const Color(0xFFD6E9DF)),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(
                child: SelectableText(_bridge.pairingKey,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12, color: _teal))),
            IconButton(
                onPressed: () => unawaited(_copy(_bridge.pairingKey, '配对密钥')),
                tooltip: '复制完整密钥',
                icon: const Icon(Icons.copy_outlined, size: 18, color: _teal))
          ]),
        ),
        const SizedBox(height: 9),
        const Text('仅与要连接的电脑共享此密钥。重新等待会生成新密钥。',
            style: TextStyle(color: _muted, fontSize: 11)),
        const SizedBox(height: 18),
        OutlinedButton.icon(
            onPressed: () => unawaited(_run(_bridge.disconnect)),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('停止等待')),
      ] else ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: _canvas, borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.vpn_key_outlined, color: _muted, size: 23),
            SizedBox(width: 12),
            Expanded(
                child: Text('开始等待时会生成新的配对密钥，验证通过后允许对方控制本机。',
                    style: TextStyle(color: _muted, fontSize: 12)))
          ]),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
            onPressed: _canStart ? () => unawaited(_run(_bridge.listen)) : null,
            icon: const Icon(Icons.sensors, size: 19),
            label: const Text('开始等待连接')),
      ],
    ]);
  }

  Widget _connectedContent() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: const Color(0xFFEAF6F0),
            borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          const Icon(Icons.check_circle_outline, color: _teal, size: 30),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('连接已建立',
                    style:
                        TextStyle(color: _teal, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                SelectableText(_bridge.peerAddress ?? '已配对设备',
                    style: const TextStyle(color: _muted, fontSize: 12))
              ]))
        ]),
      ),
      const SizedBox(height: 20),
      Text(
          _bridge.remoteActive
              ? '键鼠正在控制被控电脑。移回相邻屏幕边缘即可返回。'
              : '松开按键和鼠标按钮，再将主机鼠标移至设定边缘，即可跨屏控制。',
          style: const TextStyle(color: _muted, fontSize: 13)),
      const SizedBox(height: 24),
      OutlinedButton.icon(
          onPressed: () => unawaited(_run(_bridge.disconnect)),
          icon: const Icon(Icons.link_off, size: 19),
          label: const Text('断开连接')),
    ]);
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
