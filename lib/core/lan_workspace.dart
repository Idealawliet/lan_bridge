import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lan_input/lan_input.dart';
import 'bridge_controller.dart';
import 'lan_discovery.dart';
import 'routed_input.dart';
import 'secure_transport.dart' show defaultSecurePort;

class ControlledComputer {
  ControlledComputer(this.device, this.controller);
  final LanDevice device;
  final BridgeController controller;
}

class LanWorkspace extends ChangeNotifier {
  LanWorkspace(this.local,
      {LanInput? input, LanDiscovery? discovery, this.enableSharing = true})
      : discovery = discovery ?? LanDiscovery(),
        router = InputRouter(input ?? LanInput()) {
    this.discovery.addListener(_notify);
    local.addListener(_localChanged);
    router.beforeEvent = _route;
  }
  final BridgeController local;
  final LanDiscovery discovery;
  final InputRouter router;
  final bool enableSharing;
  final Map<String, ControlledComputer> computers = {};
  bool running = false,
      serving = false,
      busy = false,
      _stopping = false,
      _closed = false;
  String? error;
  ControlledComputer? get active => computers[router.focused];
  Future<void> setSwitchShortcutEnabled(bool enabled) async {
    if (serving && computers.values.any((m) => m.controller.connected)) {
      await router.native.configureSwitchShortcut(enabled);
    }
    local.setSwitchShortcutEnabled(enabled);
  }
  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _localChanged() {
    if (running &&
        !serving &&
        !busy &&
        !_stopping &&
        local.phase == ConnectionPhase.idle) {
      unawaited(_resumeClient());
    }
    _notify();
  }

  Future<void> _resumeClient() async {
    busy = true;
    try {
      await Future<void>.delayed(Duration.zero);
      if (!running || _stopping || local.phase != ConnectionPhase.idle) return;
      await local.listen(discoveredClient: true);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> startServer() async {
    if (running || busy || _stopping || local.phase != ConnectionPhase.idle) {
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      await local.setRole(BridgeRole.source);
      local.setConnectionMode(ConnectionMode.server);
      discovery.advertisement = () => {
            'op': 'server',
            'name': Platform.localHostname.length > 80
                ? Platform.localHostname.substring(0, 80)
                : Platform.localHostname,
            'platform': Platform.operatingSystem,
            'port': local.port == 0 ? defaultSecurePort : local.port,
            'busy': busy || computers.length >= 16,
          };
      await discovery.start();
      running = true;
      serving = true;
    } catch (e) {
      error = '无法启动发现服务：$e';
    } finally {
      busy = false;
      _notify();
    }
  }

  void requestConnection(LanDevice device) {
    if (!running || busy || _stopping || (!serving && !local.listening)) {
      throw StateError('请先启动服务并等待当前操作完成');
    }
    discovery.requestConnection(device);
  }

  Future<void> leaveServer() async {
    if (!running || serving || busy || _stopping) return;
    busy = true;
    _notify();
    try {
      await local.disconnect();
      if (!_stopping && running) await local.listen(discoveredClient: true);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> control(String id) async {
    await focus(id);
    if (busy || _stopping || router.focused != id) return;
    final controller = computers[id]?.controller;
    if (controller == null) throw StateError('客户端已离开');
    busy = true;
    router.suspended = true;
    try {
      await controller.suspendInput();
      await controller.beginControl();
    } finally {
      controller.resumeInput();
      router.suspended = false;
      busy = false;
      _notify();
    }
  }

  Future<void> returnToLocal() async {
    final controller = active?.controller;
    if (!serving || busy || controller == null) return;
    busy = true;
    router.suspended = true;
    try {
      await controller.suspendInput();
      await controller.returnToLocal();
    } finally {
      controller.resumeInput();
      router.suspended = false;
      busy = false;
      _notify();
    }
  }

  Future<void> startClient() async {
    if (running || busy || _stopping || local.phase != ConnectionPhase.idle) {
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      await local.setRole(BridgeRole.target);
      local.setConnectionMode(ConnectionMode.client);
      await local.listen(discoveredClient: true);
      if (!local.listening) throw StateError(local.error ?? '客户端监听失败');
      discovery.advertisement = () => {
            'name': Platform.localHostname.length > 80
                ? Platform.localHostname.substring(0, 80)
                : Platform.localHostname,
            'platform': Platform.operatingSystem,
            'port': local.port,
            'busy': !local.listening,
          };
      await discovery.start();
      running = true;
      serving = false;
    } catch (e) {
      await local.disconnect();
      error = '无法启动客户端：$e';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> add(LanDevice device, String key, PeerSide side,
      {double offset = 0}) async {
    if (!running || !serving || busy || _stopping) return;
    final previous = computers[device.id];
    if (previous != null) {
      if (previous.controller.connected || previous.controller.busy) return;
      await remove(device.id);
      if (!running || !serving || busy || _stopping) return;
    }
    if (computers.length >= 16) throw StateError('最多同时加入 16 台客户端');
    busy = true;
    error = null;
    _notify();
    final controller = BridgeController(
        input: router.channel(device.id),
        triggerRangeProvider: () => local.edgeTriggerRange,
        switchDelayProvider: () => local.switchDelayMs,
        shortcutEnabledProvider: () => local.switchShortcutEnabled,
        port: device.port,
        enableSharing: enableSharing);
    controller.setArrangement(side, offset);
    final member = ControlledComputer(device, controller);
    computers[device.id] = member;
    controller.addListener(_sessionChanged);
    // First session gets native focus before capture begins.
    router.focused ??= device.id;
    try {
      await controller.connect(device.host, key);
      if (!controller.connected) throw StateError(controller.error ?? '连接失败');
      if (router.focused != device.id) {
        await controller.suspendInput();
        controller.clipboard?.setEnabled(false);
      }
    } catch (e) {
      error = '无法加入 ${device.name}：$e';
      controller.removeListener(_sessionChanged);
      await controller.disconnect();
      controller.dispose();
      computers.remove(device.id);
      await router.removeChannel(device.id);
      if (router.focused == device.id) router.focused = null;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _sessionChanged() {
    for (final member in computers.values) {
      if (member.device.id != router.focused &&
          (member.controller.clipboard?.enabled ?? false)) {
        member.controller.clipboard?.setEnabled(false);
      }
    }
    _notify();
  }

  Future<void> focus(String id) async {
    if (busy || _stopping || id == router.focused) return;
    final next = computers[id];
    if (next == null || !next.controller.connected) throw StateError('客户端未连接');
    if (active?.controller.sharingBusy ?? false) {
      throw StateError('请先完成或取消当前文件传输');
    }
    busy = true;
    router.suspended = true;
    try {
      final previous = active?.controller;
      await previous?.suspendInput();
      if (previous != null && !previous.connected) await previous.disconnect();
      try {
        await previous?.returnToLocal();
      } catch (_) {
        // A failed old peer must not retain input ownership or prevent a
        // healthy peer from being selected.
        await previous?.disconnect();
      }
      await previous?.clipboard?.pause();
      await router.native.cancelFileDrag();
      await router.native.configureFileEdge(false, false);
      await router.native.setRemoteCapture(false);
      await router.native.releaseAll();
      router.focused = id;
      next.controller.resumeInput();
      next.controller.clipboard?.setEnabled(true);
      await next.controller.refreshFileEdge();
    } finally {
      if (!_stopping) active?.controller.resumeInput();
      router.suspended = false;
      busy = false;
      _notify();
    }
  }

  Future<void> _route(Map<String, dynamic> event) async {
    if (busy ||
        _stopping ||
        (active?.controller.remoteActive ?? false) ||
        (active?.controller.sharingBusy ?? false)) {
      return;
    }
    if (active?.controller.matchesLocalEdge(event) ?? false) return;
    for (final member in computers.values) {
      if (member.controller.matchesLocalEdge(event)) {
        await focus(member.device.id);
        return;
      }
    }
  }

  Future<void> arrange(String id, PeerSide side, double offset) async {
    if (busy || _stopping) return;
    final member = computers[id];
    if (member == null || !member.controller.connected) {
      throw StateError('客户端未连接');
    }
    busy = true;
    router.suspended = true;
    try {
      await member.controller.updateArrangement(side, offset);
    } finally {
      router.suspended = false;
      busy = false;
      _notify();
    }
  }

  Future<void> remove(String id) async {
    if (busy || _stopping) return;
    final member = computers[id];
    if (member == null) return;
    busy = true;
    try {
      member.controller.removeListener(_sessionChanged);
      await member.controller.disconnect();
      member.controller.dispose();
      computers.remove(id);
      await router.removeChannel(id);
      if (router.focused == id) router.focused = null;
    } finally {
      busy = false;
      _notify();
    }
    for (final remaining in computers.values) {
      if (router.focused == null && remaining.controller.connected) {
        await focus(remaining.device.id);
        break;
      }
    }
  }

  Future<void>? _stopTask;
  Future<void> stop() {
    if (_stopTask != null) return _stopTask!;
    final task = _stop();
    _stopTask = task;
    return task.whenComplete(() => _stopTask = null);
  }

  Future<void> _stop() async {
    _stopping = true;
    router.suspended = true;
    try {
      await Future.wait(computers.values
          .toList()
          .map((member) => member.controller.disconnect()));
      // Let a pending join finish before disposing its controller.
      while (busy) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      for (final member in computers.values.toList()) {
        member.controller.removeListener(_sessionChanged);
        await member.controller.disconnect();
        member.controller.dispose();
      }
      computers.clear();
      for (final id in router.channels.keys.toList()) {
        await router.removeChannel(id);
      }
      router.focused = null;
      await discovery.close();
      discovery.advertisement = null;
      if (running && !serving) await local.disconnect();
      running = false;
    } finally {
      _stopping = false;
      router.suspended = false;
      _notify();
    }
  }

  Future<void> close() async {
    await stop();
    _closed = true;
    local.removeListener(_localChanged);
    discovery.removeListener(_notify);
    await router.close();
    discovery.dispose();
  }
}
