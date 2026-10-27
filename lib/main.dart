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
import 'core/github_updates.dart';
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
  const LanBridgeApp({super.key, this.home});
  final Widget? home;

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
          'sans-serif',
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            side: const BorderSide(color: _border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: home ?? const BridgeDashboard(),
    );
  }
}

class BridgeDashboard extends StatefulWidget {
  const BridgeDashboard({
    super.key,
    this.controller,
    this.workspace,
    this.updates,
  });
  final BridgeController? controller;
  final LanWorkspace? workspace;
  final GitHubUpdates? updates;

  @override
  State<BridgeDashboard> createState() => _BridgeDashboardState();
}

class _BridgeDashboardState extends State<BridgeDashboard> {
  late final _localBridge =
      widget.workspace?.local ?? widget.controller ?? BridgeController();
  late final _workspace = widget.workspace ?? LanWorkspace(_localBridge);
  late final _updates = widget.updates ?? GitHubUpdates();
  String? _dismissedUpdate;
  bool _installingUpdate = false;
  BridgeController get _bridge => _workspace.active?.controller ?? _localBridge;
  final _address = TextEditingController();
  late final AppLifecycleListener _lifecycle;
  late final DesktopLifecycle _desktopLifecycle;
  bool _initializing = true;
  bool _pairingDialogOpen = false;

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
    _updates.addListener(_refresh);
    _desktopLifecycle = DesktopLifecycle(_prepareQuit)..install();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _prepareQuit();
        return AppExitResponse.exit;
      },
    );
    _updateTray();
    unawaited(_initialize());
    unawaited(_updates.initialize());
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
    unawaited(
      _desktopLifecycle.updateStatus(
        control: control,
        signal: signal,
        bars: bridge.signalBars ?? 0,
      ),
    );
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
          content: Text('已复制$label'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _desktopLifecycle.dispose();
    _workspace.removeListener(_refresh);
    _updates.removeListener(_refresh);
    _updates.dispose();
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
              if (_updates.available != null &&
                  _updates.available!.version.compareTo(
                        ReleaseVersion.parse(_updates.currentVersion)!,
                      ) >
                      0 &&
                  _dismissedUpdate != _updates.available!.tag &&
                  _updates.skippedTag != _updates.available!.tag) ...[
                const SizedBox(height: 16),
                _updateBanner(),
              ],
              const SizedBox(height: 24),
              _Panel(child: _multiComputerPanel()),
              if (_workspace.running) ...[
                const SizedBox(height: 16),
                _devicesPanel(),
              ],
              const SizedBox(height: 16),
              _screenLayout(),
              const SizedBox(height: 16),
              if (!_initializing && !_bridge.supported)
                _notice(
                  Icons.desktop_access_disabled_outlined,
                  '当前平台不可用',
                  '请在 Windows 或 macOS 上运行。',
                  warning: true,
                )
              else if (!_initializing && !_bridge.permissionsGranted)
                _permissionNotice(),
              if (_bridge.error != null)
                _notice(
                  Icons.error_outline,
                  '连接异常',
                  _bridge.error!,
                  warning: true,
                ),
              if (_bridge.files != null) ...[
                const SizedBox(height: 16),
                _sharingPanel(),
              ],
              if (_bridge.connected || _workspace.running) ...[
                const SizedBox(height: 16),
                _recoveryBar(),
              ],
            ],
          ),
        ),
      ),
    ),
  );

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
            borderRadius: BorderRadius.circular(30),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.computer_outlined, size: 16, color: _muted),
              const SizedBox(width: 7),
              Text(
                _bridge.platformName,
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: Listenable.merge([_workspace, _updates]),
        builder: (context, _) => AlertDialog(
          title: const Text('设置'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _preferencesPanel(),
                  const SizedBox(height: 16),
                  _connectionPanel(),
                  const SizedBox(height: 16),
                  _updatesPanel(),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _joinDevice(
    LanDevice device, {
    PeerSide? initialSide,
    double initialOffset = 0,
  }) async {
    if (_pairingDialogOpen || !_workspace.running || !_workspace.serving) {
      return;
    }
    if (device.busy) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该客户端正在连接中，请稍后再试')));
      return;
    }
    _pairingDialogOpen = true;
    final key = TextEditingController();
    var side =
        initialSide ??
        PeerSide.values.firstWhere(
          (side) => !_workspace.computers.values.any(
            (m) => m.controller.side == side,
          ),
          orElse: () => PeerSide.right,
        );
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
                    Text('${device.host}:${device.port} · ${device.platform}'),
                    const SizedBox(height: 12),
                    const Text('核对客户端名称与地址，输入该客户端显示的6 位 PIN 码。'),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: key,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      validator: (value) =>
                          RegExp(r'^\d{6}$').hasMatch(value ?? '')
                          ? null
                          : '请输入 6 位数字 PIN 码',
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: '客户端 PIN 码'),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final entry in const {
                          PeerSide.left: '左',
                          PeerSide.right: '右',
                          PeerSide.top: '上',
                          PeerSide.bottom: '下',
                        }.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: side == entry.key,
                            onSelected: (_) => update(() => side = entry.key),
                          ),
                      ],
                    ),
                    const Text('相对于服务端主屏幕的位置'),
                    Slider(
                      value: offset,
                      min: -.9,
                      max: .9,
                      label: '${(offset * 100).round()}%',
                      onChanged: (value) => update(() => offset = value),
                    ),
                    const Text(
                      '相接区域重叠时，优先进入当前选中的客户端。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (pinForm.currentState!.validate()) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('加入控制组'),
            ),
          ],
        ),
      ),
    );
    _pairingDialogOpen = false;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!workspace.running) ...[
          const Text(
            '开始协作',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            '键鼠所在的电脑启动服务端，需要被控制的电脑启动客户端。',
            style: TextStyle(color: _muted),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: !_canStart || workspace.busy || _locked
                    ? null
                    : () => unawaited(_run(workspace.startServer)),
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('启动服务端'),
              ),
              OutlinedButton.icon(
                onPressed: !_canStart || workspace.busy || _locked
                    ? null
                    : () => unawaited(_run(workspace.startClient)),
                icon: const Icon(Icons.desktop_windows_outlined),
                label: const Text('启动客户端'),
              ),
            ],
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  workspace.serving
                      ? '服务端 · 已连接 ${workspace.computers.values.where((m) => m.controller.connected).length} 台客户端'
                      : '客户端 · ${_localBridge.connected ? '已加入服务端' : _localBridge.statusText}',
                ),
              ),
              TextButton(
                onPressed: workspace.busy
                    ? null
                    : () => unawaited(_run(workspace.stop)),
                child: const Text('停止服务'),
              ),
            ],
          ),
          if (!workspace.serving && _localBridge.connected)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                onPressed: workspace.busy
                    ? null
                    : () => unawaited(_run(workspace.leaveServer)),
                icon: const Icon(Icons.logout),
                label: const Text('离开服务端'),
              ),
            ),
          if (!workspace.serving && _localBridge.listening)
            Row(
              children: [
                const Text('配对 PIN 码  '),
                SelectableText(
                  _localBridge.pairingKey,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 24,
                    letterSpacing: 6,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      unawaited(_copy(_localBridge.pairingKey, 'PIN 码')),
                  tooltip: '复制 PIN 码',
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
        ],
        if (_bridge.connected)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.mouse, color: _teal, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _bridge.remoteActive
                        ? '当前控制：${workspace.serving ? (workspace.active?.device.name ?? '客户端') : '本机客户端'}'
                        : '当前控制：${workspace.serving ? '本机服务端' : '服务端电脑'}',
                    style: const TextStyle(
                      color: _teal,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (workspace.busy) const LinearProgressIndicator(),
        if (workspace.error != null)
          Text(workspace.error!, style: const TextStyle(color: Colors.red)),
      ],
    );
  }

  Future<void> _pairRequest(
    ConnectionRequest request, {
    bool incoming = false,
  }) async {
    if (!_workspace.running || !_workspace.serving || _workspace.busy) return;
    await _joinDevice(request.device);
    if (!mounted) return;
    if (_workspace.computers[request.device.id]?.controller.connected ??
        false) {
      if (incoming) _workspace.discovery.respond(request, true);
      _workspace.discovery.dismissRequest(request.id);
    }
  }

  Widget _deviceRow(String name, String detail, List<Widget> actions) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(detail, style: const TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
      );

  Widget _devicesPanel() {
    final workspace = _workspace;
    final discovery = workspace.discovery;
    final serving = workspace.serving;
    final enabled = !workspace.busy && !_pairingDialogOpen;
    final available = discovery.devices.values.where(
      (device) =>
          device.isServer != serving &&
          !(workspace.computers[device.id]?.controller.connected ?? false),
    );
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            serving ? '客户端与控制申请' : '服务端与加入申请',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            serving
                ? '选择客户端申请控制，或处理客户端的加入申请。'
                : '选择服务端申请加入；服务端同意后输入本机显示的 PIN 即可连接。',
            style: const TextStyle(color: _muted),
          ),
          if (serving)
            for (final member in workspace.computers.values)
              _deviceRow(
                member.device.name,
                !member.controller.connected
                    ? '客户端已离开'
                    : member.controller.remoteActive
                    ? '正在控制'
                    : '已连接，键鼠在本机',
                [
                  if (member.controller.connected)
                    FilledButton.tonalIcon(
                      onPressed: !enabled || member.controller.remoteActive
                          ? null
                          : () => unawaited(
                              _run(() => workspace.control(member.device.id)),
                            ),
                      icon: const Icon(Icons.mouse_outlined),
                      label: const Text('开始控制'),
                    ),
                  OutlinedButton.icon(
                    onPressed: !enabled
                        ? null
                        : () => unawaited(
                            _run(() => workspace.remove(member.device.id)),
                          ),
                    icon: const Icon(Icons.link_off),
                    label: Text(member.controller.connected ? '解除控制' : '移除设备'),
                  ),
                ],
              ),
          for (final request in discovery.incomingRequests.values)
            _deviceRow(
              request.device.name,
              request.status == 'pending'
                  ? '${request.device.host} · ${serving ? '申请加入本服务端' : '申请控制本机'}'
                  : request.status == 'accepted'
                  ? '已同意，请将本机 PIN 告知服务端完成配对'
                  : '已拒绝此申请',
              [
                if (request.status == 'pending') ...[
                  FilledButton.tonal(
                    onPressed: !enabled || (!serving && !_localBridge.listening)
                        ? null
                        : () => serving
                              ? unawaited(_pairRequest(request, incoming: true))
                              : discovery.respond(request, true),
                    child: Text(serving ? '同意并配对' : '允许控制'),
                  ),
                  TextButton(
                    onPressed: !enabled
                        ? null
                        : () => discovery.respond(request, false),
                    child: const Text('拒绝'),
                  ),
                ] else
                  TextButton(
                    onPressed: () => discovery.dismissRequest(request.id),
                    child: const Text('关闭'),
                  ),
              ],
            ),
          for (final request in discovery.outgoingRequests.values)
            _deviceRow(
              request.device.name,
              switch (request.status) {
                'accepted' => serving ? '客户端已同意，请输入其 PIN 完成连接' : '服务端已同意加入',
                'rejected' => '对方已拒绝，可稍后重新申请',
                _ => '申请已发送，等待对方处理（60 秒后过期）',
              },
              [
                if (serving && request.status == 'accepted')
                  FilledButton.tonal(
                    onPressed: enabled
                        ? () => unawaited(_pairRequest(request))
                        : null,
                    child: const Text('输入 PIN 并连接'),
                  ),
                TextButton(
                  onPressed: () => discovery.dismissRequest(request.id),
                  child: const Text('关闭提示'),
                ),
              ],
            ),
          if (serving || _localBridge.listening) ...[
            const Divider(height: 24),
            Text(
              serving ? '可用客户端' : '可用服务端',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (available.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  serving ? '等待局域网内的客户端启动…' : '等待局域网内的服务端启动…',
                  style: const TextStyle(color: _muted),
                ),
              ),
            for (final device in available)
              _deviceRow(
                device.name,
                '${device.host} · ${device.platform}${device.busy ? ' · 忙碌中' : ''}',
                [
                  OutlinedButton.icon(
                    onPressed:
                        !enabled ||
                            device.busy ||
                            discovery.outgoingRequests.values.any(
                              (r) =>
                                  r.device.id == device.id &&
                                  r.status == 'pending',
                            )
                        ? null
                        : () => unawaited(
                            _run(
                              () async => workspace.requestConnection(device),
                            ),
                          ),
                    icon: Icon(
                      serving ? Icons.touch_app_outlined : Icons.login,
                    ),
                    label: Text(serving ? '申请控制' : '申请加入'),
                  ),
                  if (serving)
                    TextButton(
                      onPressed: !enabled || device.busy
                          ? null
                          : () => unawaited(_joinDevice(device)),
                      child: const Text('已有 PIN，直接连接'),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _screenLayout() {
    final multi = _workspace.running && _workspace.serving;
    final nodes = multi
        ? [
            for (final m in _workspace.computers.values)
              if (m.controller.connected)
                ScreenNode(
                  m.device.id,
                  m.device.name,
                  m.controller.side,
                  m.controller.screenOffset,
                  selected: _workspace.active == m,
                  controlling: m.controller.remoteActive,
                ),
          ]
        : _bridge.connected
        ? [
            ScreenNode(
              'local-peer',
              _bridge.role == BridgeRole.target ? '本机 · 被控电脑' : '被控电脑',
              _bridge.side,
              _bridge.screenOffset,
              controlling: _bridge.remoteActive,
            ),
          ]
        : <ScreenNode>[];
    return _Panel(
      child: Column(
        children: [
          ScreenWorkspace(
            nodes: nodes,
            referenceActive: !_bridge.remoteActive,
            referenceName: _bridge.role == BridgeRole.target
                ? _bridge.connected
                      ? '键鼠主机 · 另一台电脑'
                      : '本机 · 被控电脑'
                : '本机 · 键鼠主机',
            available: multi
                ? _workspace.discovery.devices.values
                      .where(
                        (d) =>
                            !d.isServer &&
                            !(_workspace
                                    .computers[d.id]
                                    ?.controller
                                    .connected ??
                                false),
                      )
                      .toList()
                : [],
            enabled: multi
                ? !_workspace.busy
                : !_initializing &&
                      !_bridge.busy &&
                      _bridge.role == BridgeRole.source,
            onArrange: (id, side, offset) => unawaited(
              _run(
                () => multi
                    ? _workspace.arrange(id, side, offset)
                    : _bridge.updateArrangement(side, offset),
              ),
            ),
            onRequest: (device, side, offset) => unawaited(
              _joinDevice(device, initialSide: side, initialOffset: offset),
            ),
            closeEnabled: !_workspace.busy && !_bridge.busy,
            onClose: multi
                ? (id) => unawaited(_run(() => _workspace.remove(id)))
                : _bridge.connected
                ? (_) => unawaited(_run(_bridge.disconnect))
                : null,
            onSelect: (id) {
              if (multi) unawaited(_run(() => _workspace.focus(id)));
            },
          ),
        ],
      ),
    );
  }

  Widget _updateBanner() => _Panel(
    padding: const EdgeInsets.all(16),
    child: Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Icon(Icons.system_update_alt, color: _teal),
        Text(
          '发现新版本 ${_updates.available!.tag}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        TextButton(onPressed: _openSettings, child: const Text('查看更新')),
        TextButton(
          onPressed: () =>
              setState(() => _dismissedUpdate = _updates.available!.tag),
          child: const Text('稍后提醒'),
        ),
      ],
    ),
  );

  Widget _updatesPanel() {
    final release = _updates.available;
    final busy = _updates.checking || _updates.downloading || _installingUpdate;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            number: '03',
            title: '软件更新',
            subtitle: '发现更新后由你选择下载和安装。',
          ),
          const SizedBox(height: 12),
          Text('当前版本 v${_updates.currentVersion}'),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('启动时检查更新'),
            subtitle: const Text('包含 GitHub 预览版；不会自动下载或安装。'),
            value: _updates.autoCheck,
            onChanged: !_updates.supported
                ? null
                : (value) => unawaited(_updates.setAutoCheck(value)),
          ),
          Text(_updates.supported ? _updates.status : '更新支持 Windows 和 macOS'),
          if (_updates.skippedTag != null)
            TextButton(
              onPressed: () => unawaited(_updates.skipVersion(null)),
              child: Text('恢复 ${_updates.skippedTag} 的更新提醒'),
            ),
          if (_updates.versions.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('versions-${release?.tag}'),
              initialValue: release?.tag,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '版本管理 · 升级 / 降级 / 重装',
              ),
              items: [
                for (final version in _updates.versions)
                  DropdownMenuItem(
                    value: version.tag,
                    child: Text(
                      '${version.tag}${version.tag == 'v${_updates.currentVersion}' ? '（当前）' : ''}${version.prerelease ? ' · 预览版' : ''}',
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (tag) {
                      if (tag != null) _updates.selectVersion(tag);
                    },
            ),
            const Text(
              '仅列出已发布且提供本平台安装包及校验文件的版本。两端请使用相同版本；旧版可能不具备版本校验。',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          ],
          if (_updates.downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _updates.progress),
            Text(
              '${(_updates.received / 1024 / 1024).toStringAsFixed(1)} MiB / ${((release?.installer.size ?? 0) / 1024 / 1024).toStringAsFixed(1)} MiB',
            ),
          ],
          if (release != null) ...[
            const SizedBox(height: 12),
            Text(
              '${release.tag}${release.prerelease ? ' · 预览版' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (release.notes.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: SelectableText(
                    release.notes,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: !_updates.supported || busy
                    ? null
                    : () => unawaited(_updates.check()),
                icon: const Icon(Icons.refresh),
                label: Text(_updates.checking ? '正在检查…' : '检查更新'),
              ),
              if (release != null &&
                  _updates.downloadedFile == null &&
                  !_updates.downloading)
                FilledButton.icon(
                  onPressed: busy ? null : () => unawaited(_updates.download()),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                    release.version.compareTo(
                              ReleaseVersion.parse(_updates.currentVersion)!,
                            ) >
                            0
                        ? '下载更新'
                        : '下载此版本',
                  ),
                ),
              if (release != null && release.tag != _updates.skippedTag)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => unawaited(_updates.skipVersion(release.tag)),
                  child: const Text('跳过此版本提醒'),
                ),
              if (_updates.downloading)
                TextButton(
                  onPressed: _updates.cancelDownload,
                  child: const Text('取消下载'),
                ),
              if (_updates.downloadedFile != null)
                FilledButton.icon(
                  onPressed: busy ? null : () => unawaited(_installUpdate()),
                  icon: const Icon(Icons.install_desktop),
                  label: const Text('安装更新…'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _installUpdate() async {
    if (_installingUpdate) return;
    setState(() => _installingUpdate = true);
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('安装更新'),
          content: Text(
            '将断开所有控制连接，打开 ${_updates.available?.tag ?? '新版本'} 安装包并退出 LAN Bridge。\n\n${_updates.operatingSystem == 'macos' ? '请在打开的磁盘镜像中将 LAN Bridge 拖入 Applications，替换旧版本后重新打开。' : '请按安装向导完成更新，安装后重新打开应用。'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后安装'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('打开安装包并退出'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      await _run(() async {
        await _prepareQuit();
        await _updates.openInstaller();
        await _desktopLifecycle.quit();
      });
    } finally {
      if (mounted) setState(() => _installingUpdate = false);
    }
  }

  Widget _preferencesPanel() {
    final local = _localBridge;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            number: '01',
            title: '常规设置',
            subtitle: '在主界面选择并启动服务端或客户端。',
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('开机自启'),
            subtitle: const Text('登录后打开应用，连接需手动启动。'),
            value: local.loginStartup,
            onChanged: !local.supported || local.startupBusy
                ? null
                : (value) => unawaited(local.setLoginStartup(value)),
          ),
          if (local.settingsError != null)
            Text(
              local.settingsError!,
              style: const TextStyle(color: Colors.red),
            ),
        ],
      ),
    );
  }

  Widget _connectionPanel() {
    final local = _localBridge;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            number: '02',
            title: '连接设置',
            subtitle: '两端启动后，服务端拖入客户端并输入其 6 位 PIN 码。',
          ),
          const SizedBox(height: 16),
          Text('本机局域网地址：${local.localAddresses.join('、')}'),
          if (local.role == BridgeRole.source) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '客户端 IP 地址',
                hintText: '例如 192.168.1.24',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  !_workspace.running || !_workspace.serving || _workspace.busy
                  ? null
                  : () async {
                      final host = _address.text.trim();
                      if (host.isEmpty || host == '0.0.0.0') {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请输入客户端实际的局域网 IP 地址')),
                        );
                        return;
                      }
                      await _joinDevice(
                        LanDevice(
                          id: 'manual-$host',
                          name: host,
                          platform: 'desktop',
                          host: host,
                          port: local.port,
                          busy: false,
                          seen: DateTime.now(),
                        ),
                      );
                    },
              icon: const Icon(Icons.link),
              label: const Text('通过 IP 添加客户端'),
            ),
          ],
        ],
      ),
    );
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
                Text(
                  '先允许系统输入权限',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 4),
                Text(
                  'macOS 需开启“辅助功能”和“输入监控”；授权后重新打开客户端。',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: () => unawaited(_run(_bridge.requestPermissions)),
            child: const Text('检查 / 请求权限'),
          ),
        ],
      ),
    );
  }

  Widget _notice(
    IconData icon,
    String title,
    String message, {
    bool warning = false,
  }) {
    final color = warning ? const Color(0xFF966326) : _teal;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: warning ? const Color(0xFFFFF5E7) : const Color(0xFFEAF6F0),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  message,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recoveryBar() => Row(
    children: [
      const Icon(Icons.keyboard_outlined, size: 18, color: _muted),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          _bridge.platformName == 'macOS'
              ? 'Control + Option + Esc 返回本机'
              : 'Ctrl + Alt + Esc 返回本机',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      ),
      TextButton.icon(
        onPressed: () => unawaited(
          _run(
            _workspace.running
                ? _workspace.serving
                      ? _workspace.returnToLocal
                      : _workspace.leaveServer
                : _bridge.emergencyReturn,
          ),
        ),
        icon: const Icon(Icons.undo, size: 18),
        label: const Text('返回本机'),
      ),
    ],
  );

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '剪贴板与文件互通',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
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
            style: TextStyle(color: _muted, fontSize: 13),
          ),
          if (_bridge.dragStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _bridge.dragStatus!,
                style: const TextStyle(color: _teal),
              ),
            ),
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
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                children: [
                  Icon(
                    Icons.drive_folder_upload_outlined,
                    color: _teal,
                    size: 30,
                  ),
                  SizedBox(height: 8),
                  Text('也可把文件或文件夹拖到这里发送'),
                  Text(
                    '对方确认后，保存到下载目录 / LAN Bridge',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: files.sending
                    ? null
                    : () async {
                        final selected = await openFiles();
                        await sendPaths(selected.map((f) => f.path).toList());
                      },
                icon: const Icon(Icons.attach_file),
                label: const Text('选择文件'),
              ),
              OutlinedButton.icon(
                onPressed: files.sending
                    ? null
                    : () async {
                        final selected = await getDirectoryPath();
                        if (selected != null) await sendPaths([selected]);
                      },
                icon: const Icon(Icons.folder_outlined),
                label: const Text('选择文件夹'),
              ),
              if (files.sending || files.receiving)
                TextButton(
                  onPressed: () => unawaited(_run(files.cancel)),
                  child: const Text('取消传输'),
                ),
            ],
          ),
          if (files.offer != null && !files.receiving) ...[
            const SizedBox(height: 12),
            Text(
              '对方发送：${files.offer!.name} · ${bytes(files.offer!.bytes)} · ${files.offer!.count} 个条目',
            ),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: () => unawaited(_run(files.accept)),
                  child: const Text('接收'),
                ),
                TextButton(
                  onPressed: () => unawaited(_run(files.reject)),
                  child: const Text('拒绝'),
                ),
              ],
            ),
          ],
          if (files.sending) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: files.sendTotal == 0
                  ? null
                  : files.sentBytes / files.sendTotal,
            ),
            Text('发送 ${bytes(files.sentBytes)} / ${bytes(files.sendTotal)}'),
          ],
          if (files.receiving) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: files.receiveTotal == 0
                  ? null
                  : files.receivedBytes / files.receiveTotal,
            ),
            Text(
              '接收 ${bytes(files.receivedBytes)} / ${bytes(files.receiveTotal)}',
            ),
          ],
          const SizedBox(height: 10),
          SelectableText(
            files.status,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: _teal,
          borderRadius: BorderRadius.circular(11),
        ),
        child: const Icon(
          Icons.swap_horiz_rounded,
          color: Colors.white,
          size: 25,
        ),
      ),
      const SizedBox(width: 10),
      const Text(
        'LAN Bridge',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: _ink,
        ),
      ),
    ],
  );
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
          color: Color(0x06242A4A),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.number,
    required this.title,
    required this.subtitle,
  });
  final String number;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            number,
            style: const TextStyle(
              color: _teal,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      const SizedBox(height: 7),
      Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12)),
    ],
  );
}
