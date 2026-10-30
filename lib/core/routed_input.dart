import 'dart:async';
import 'package:lan_input/lan_input.dart';
import 'package:flutter/services.dart';
import 'input_event_queue.dart';

// 每条事件采集时的状态快照，用记录值相等性阻止跨状态合并。
typedef _RouteContext = ({int generation, int focus, int suspension});

/// 将多个加密会话接到同一个系统输入钩子，只向当前焦点会话转发普通事件。
/// 每个事件记录捕获代数、焦点版本和暂停版本，异步处理前后检查版本，
/// 防止旧的按键或鼠标事件在切换电脑后被错误地发送给新设备。
class InputRouter {
  InputRouter(this.native);
  // 所有会话共用的系统输入接口，只有首个会话负责启动捕获。
  final LanInput native;
  // 按设备 ID 保存会话接口，用于焦点路由及安全事件广播。
  final Map<String, RoutedInput> channels = {};
  // 记录正在使用捕获的会话，Set 同时避免重复登记。
  final Set<String> _capturing = {};
  // 当前获得输入所有权的会话；null 表示没有选中会话。
  String? _focused;
  // 焦点、捕获和暂停分别计数，状态恢复原值也不会复用旧版本。
  int _focusVersion = 0, _generation = 0, _suspensionVersion = 0;
  String? get focused => _focused;
  set focused(String? value) {
    // 同一焦点的重复赋值不使事件失效；只有实际切换才递增版本。
    if (_focused != value) {
      // 更新路由目标，再使旧焦点采集的待处理输入失效。
      _focused = value;
      // 即使稍后切回同一设备，旧按键也不能越过这次切换。
      _focusVersion++;
    }
  }

  bool _suspended = false;
  bool get suspended => _suspended;
  set suspended(bool value) {
    // 进入和离开暂停都算状态变化，丢弃暂停之前排队的输入。
    if (_suspended != value) {
      // 保存当前是否暂停普通事件转发。
      _suspended = value;
      // 为这次暂停状态变更生成新版本。
      _suspensionVersion++;
    }
  }

  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 发送前执行屏幕边缘检测；它可能异步切换焦点，因此返回后需再次检查状态。
  Future<void> Function(Map<String, dynamic>)? beforeEvent;
  // 串行消费事件并合并相邻移动，避免高采样率鼠标积压。
  late final _queue = InputEventQueue<_RouteContext>(
      consume: _deliver,
      onError: (error, stack, context) {
        // 只处理本轮捕获的失败，旧任务不能中断重新建立的输入会话。
        if (context.generation == _generation) _lost();
      });
  // 捕获异常时统一作废输入，并让所有控制器执行安全释放。
  void _lost() {
    _generation++;
    _queue.clear();
    // 遍历全部会话，确保非焦点设备也收到清理通知。
    for (final channel in channels.values) {
      // 通知控制器捕获已丢失，而不是继续回放排队的输入。
      channel.emit({'type': 'captureLost'});
    }
  }

  Future<void> _deliver(
      Map<String, dynamic> event, _RouteContext context) async {
    // 消费开始前检查状态快照，直接丢弃暂停或已过期的输入。
    if (suspended ||
        context.generation != _generation ||
        context.focus != _focusVersion ||
        context.suspension != _suspensionVersion) {
      return;
    }
    // 等待屏幕切换逻辑完成，随后再决定本条事件真正的接收方。
    await beforeEvent?.call(event);
    // 跨屏移动本身可以切换焦点：允许把触发切换的这一条移动交给新会话。
    // focus() 内部会暂时暂停输入，所以该特例允许暂停版本变化；
    // 捕获代数仍必须有效，按键和按钮则必须保持原焦点、原暂停版本。
    if (!suspended &&
        context.generation == _generation &&
        ((context.focus == _focusVersion &&
                context.suspension == _suspensionVersion) ||
            (event['type'] == 'move' && context.focus != _focusVersion))) {
      // 目标可能已移除，空值访问可安全丢弃该事件。
      channels[focused]?.emit(event);
    }
  }

  // 复用同一设备接口，避免生成多个事件流和重复捕获引用。
  RoutedInput channel(String id) =>
      channels.putIfAbsent(id, () => RoutedInput(this, id));

  /// 会话按 ID 共享原生捕获；同一会话重复启动不会增加引用次数。
  Future<void> start(String id) async {
    // 重复启动或已有其他使用者时只登记引用，不重复安装系统钩子。
    if (!_capturing.add(id) || _capturing.length > 1) return;
    _generation++;
    // 先订阅再启动捕获，避免丢失原生启动阶段立即产生的事件。
    _subscription = native.events.listen((event) {
      // 紧急退出和捕获丢失绕过普通队列，通知全部会话释放各自的远端按键。
      if (event['type'] == 'emergency' || event['type'] == 'captureLost') {
        _generation++;
        for (final channel in channels.values) {
          // 逐个广播安全事件，不受当前焦点限制。
          channel.emit(event);
        }
        return;
      }
      // 暂停期间不积累普通事件，恢复后无需回放旧操作。
      if (suspended) return;
      // 入队时冻结三项状态版本，消费时据此识别过期输入。
      _queue.add(event, (
        generation: _generation,
        focus: _focusVersion,
        suspension: _suspensionVersion
      ));
    }, onError: (Object _) {
      _lost();
    });
    try {
      // 安装原生捕获；失败时回滚本次登记与订阅。
      await native.startCapture();
    } catch (_) {
      // 撤销启动失败会话的引用，允许后续重新启动。
      _capturing.remove(id);
      // 不再接收本次失败捕获产生的系统事件。
      await _subscription?.cancel();
      _subscription = null;
      try {
        await native.stopCapture();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> stop(String id) async {
    // 未启动或已停止的会话无需重复释放。
    if (!_capturing.remove(id)) return;
    // 只有最后一个会话停止时才释放原生捕获，避免中断其他客户端。
    if (_capturing.isEmpty) {
      _generation++;
      // 保存旧订阅，清理时只取消这次停止对应的订阅。
      final subscription = _subscription;
      _subscription = null;
      try {
        await native.stopCapture();
      } finally {
        // 原生停止即使失败，也必须切断旧事件来源。
        await subscription?.cancel();
      }
    }
  }

  Future<void> removeChannel(String id) async {
    // 删除前要求停止捕获，防止引用计数残留。
    if (_capturing.contains(id)) throw StateError('输入会话仍在捕获');
    // 先移出注册表，让后续事件无法再找到该会话。
    final channel = channels.remove(id);
    // 删除当前会话时一并清除焦点并递增焦点版本。
    if (focused == id) focused = null;
    // 结束会话流，等待其订阅方收到关闭通知。
    await channel?._events.close();
  }

  /// 关闭所有会话，并释放共享的系统输入捕获。
  /// 即使调用者没有逐个停止会话，也不能把系统钩子留在捕获状态。
  Future<void> close() async {
    // 先使已经进入异步处理的旧事件失效，避免关闭期间继续发送输入。
    _generation++;
    // 停止接收新的系统事件；已开始的处理由代数检查拦截。
    await _subscription?.cancel();
    // 清除订阅引用，避免后续停止会话时重复取消。
    _subscription = null;
    // 丢弃尚未执行的输入，关机清理无需回放积压的鼠标轨迹。
    _queue.clear();
    try {
      // 所有会话共用一个系统钩子，因此只需停止一次。
      if (_capturing.isNotEmpty) await native.stopCapture();
    } finally {
      // 原生停止失败也必须清理 Dart 状态，同时将错误交给调用方处理。
      _capturing.clear();
      // 清空焦点，使旧会话无法继续通过 active 检查修改光标。
      focused = null;
      // 等待已经开始的事件处理退出，再关闭它可能访问的事件流。
      await _queue.idle;
      // 逐个结束会话事件流，让订阅方收到结束通知。
      for (final channel in channels.values) {
        await channel._events.close();
      }
      // 释放会话注册表，后续重复关闭不会再次停止原生捕获。
      channels.clear();
    }
  }
}

/// 单个会话的输入接口：捕获和权限查询共享原生插件，光标操作必须持有焦点。
/// 无焦点会话的清理操作直接忽略，避免影响当前正在控制的另一台电脑。
class RoutedInput extends LanInput {
  RoutedInput(this.router, this.id);
  final InputRouter router;
  final String id;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  // 所有影响光标与注入的操作均以此判断输入所有权。
  bool get active => router.focused == id;
  void emit(Map<String, dynamic> event) {
    // 异步关闭后到达的事件直接忽略，避免向已关闭流写入。
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<InputStatus> getStatus() => router.native.getStatus();
  @override
  Future<void> requestPermissions() => router.native.requestPermissions();
  @override
  Future<void> startCapture() => router.start(id);
  @override
  Future<void> configureSwitchShortcut(bool enabled) =>
      router.native.configureSwitchShortcut(enabled);
  @override
  Future<void> stopCapture() => router.stop(id);
  @override
  Future<void> setRemoteCapture(bool enabled) async {
    // 未获得焦点的会话不能开启捕获，也不能关闭另一会话的捕获。
    if (!active) {
      if (enabled) {
        // 显式报告无法取得输入所有权，让调用方显示实际失败原因。
        throw PlatformException(code: 'input_busy', message: '客户端未获焦点');
      }
      return;
    }
    await router.native.setRemoteCapture(enabled);
  }

  @override
  Future<void> setCursorVisible(bool visible) async {
    // 只允许当前会话改变系统光标可见性，避免后台会话显示双鼠标。
    if (active) await router.native.setCursorVisible(visible);
  }

  @override
  Future<void> heartbeat() async {
    await router.native.heartbeat();
  }

  @override
  Future<void> inject(Map<String, dynamic> event) async {
    // 只向当前控制会话注入事件，忽略后台设备的迟到输入。
    if (active) await router.native.inject(event);
  }

  @override
  Future<void> warp(double x, double y) async {
    // 跳转系统鼠标位置同样要求焦点，避免旧会话把光标拉回。
    if (active) await router.native.warp(x, y);
  }

  @override
  Future<void> releaseAll() async {
    // 仅焦点会话释放当前系统按键，避免干扰其他会话正在拖拽的操作。
    if (active) await router.native.releaseAll();
  }

  @override
  Future<int> clipboardRevision() => router.native.clipboardRevision();
  @override
  Future<bool> clipboardHasFiles() => router.native.clipboardHasFiles();
  @override
  Future<void> configureFileEdge(bool enabled, bool left) async {
    if (active) await router.native.configureFileEdge(enabled, left);
  }

  @override
  Future<void> configureFileEdgeLayout(
      bool enabled, String edge, double start, double end) async {
    if (active) {
      await router.native.configureFileEdgeLayout(enabled, edge, start, end);
    }
  }

  @override
  Future<void> prepareFileDrag() async {
    // 拖放准备必须持有输入所有权，否则直接报告失败。
    if (!active) throw StateError('客户端未获焦点');
    await router.native.prepareFileDrag();
  }

  @override
  Future<void> cancelLocalDrag() async {
    if (active) await router.native.cancelLocalDrag();
  }

  @override
  Future<void> beginFileDrag(List<String> paths) async {
    // 开始系统拖放前要求用户已选中这台客户端。
    if (!active) throw StateError('请先选择此客户端');
    await router.native.beginFileDrag(paths);
  }

  @override
  Future<void> cancelFileDrag() async {
    if (active) await router.native.cancelFileDrag();
  }
}
