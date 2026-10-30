import 'dart:async';
import 'dart:collection';

/// 保存一条输入及其采集时的会话上下文；只有同一上下文的尾部事件可合并。
class _InputItem<T> {
  _InputItem(this.event, this.context);
  // 允许用合并结果替换待处理事件，但不改变它所属的会话。
  Map<String, dynamic> event;
  final T context;
}

/// 两次非零位移符号相反就发生了转向；零位移不改变方向。
/// 往返移动可能经过屏幕边界，不能仅凭净位移为零就丢掉轨迹。
bool _changesDirection(num previous, num next) =>
    (previous < 0 && next > 0) || (previous > 0 && next < 0);

/// 串行消费输入，用相邻鼠标移动合并降低高采样率设备的发送压力。
/// 按键、按钮、滚轮和上下文变化都是顺序边界，不能跨越它们合并。
class InputEventQueue<T> {
  InputEventQueue(
      {required this.consume,
      required this.onError,
      this.limit = 512,
      this.mergeMoves,
      this.motionInterval = Duration.zero});

  /// 执行一条输入；完成后才会处理下一条，避免按下与抬起乱序。
  final Future<void> Function(Map<String, dynamic>, T) consume;

  /// 处理消费异常，并让调用方按上下文停止控制或释放按键。
  final FutureOr<void> Function(Object, StackTrace, T) onError;

  /// 最多保留的待处理事件数；达到上限后报告积压，避免无限占用内存。
  final int limit;

  /// 可选合并策略：返回 null 表示必须保留为两条独立事件。
  final Map<String, dynamic>? Function(
      Map<String, dynamic>, Map<String, dynamic>)? mergeMoves;

  /// 两次移动消费之间的最小间隔；默认零表示不额外等待。
  final Duration motionInterval;
  // 使用单调时钟计时，避免系统时间校准影响发送间隔。
  final _clock = Stopwatch()..start();
  // 初始负值使常用毫秒级限速下的第一次移动无需等待。
  int _lastMove = -1000000;
  // 双端队列支持尾部合并和头部消费，无需搬移中间元素。
  final _items = ListQueue<_InputItem<T>>();
  // 非空表示已有消费循环；同时供外部等待本轮处理完成。
  Completer<void>? _idle;
  // 累计合并次数及最大等待深度，用于测试输入合并效果。
  int merged = 0, peakDepth = 0;

  /// 等待当前消费和排队事件全部结束；空队列直接返回已完成的 Future。
  Future<void> get idle => _idle?.future ?? Future<void>.value();

  /// 只丢弃未开始的事件；调用方仍需通过上下文使正在等待的事件失效。
  void clear() => _items.clear();

  /// 添加输入，优先合并，否则排队；始终只启动一个消费循环。
  void add(Map<String, dynamic> event, T context) {
    // 只有队尾尚未消费的事件可以安全替换。
    if (_tryMergePendingEvent(event, context)) {
      // 记录省去的一次独立消费。
      merged++;
      // 合并成功后已有消费循环负责处理，不再追加队列。
      return;
    }
    // 积压超限时丢弃旧输入，避免稍后回放过时的键鼠操作。
    if (_items.length >= limit) {
      _items.clear();
      // 错误也交给同一消费循环处理，避免并发执行清理回调。
      _items.add(_InputItem({'type': '_overflow'}, context));
    } else {
      // 复制事件容器，避免调用方入队后修改原 Map 影响待处理输入。
      _items.add(_InputItem(Map<String, dynamic>.of(event), context));
    }
    // 统计待处理队列峰值，不计当前已经取出的事件。
    if (_items.length > peakDepth) peakDepth = _items.length;
    // 仅空闲时启动消费，已有循环会继续读取新追加的事件。
    if (_idle == null) {
      // 在启动异步循环前设置标记，防止重入时开启第二个循环。
      _idle = Completer<void>();
      // 入队不等待发送结束；需要等待的调用方使用 idle。
      unawaited(_drain());
    }
  }

  /// 判断尾部合并并保存结果；不触碰已经交给 consume 的事件。
  bool _tryMergePendingEvent(Map<String, dynamic> event, T context) {
    // 焦点或捕获代数不同意味着两个事件属于不同输入状态。
    if (_items.isEmpty || _items.last.context != context) return false;
    // 保存队尾引用，后续只替换此条目的事件内容。
    final pending = _items.last;
    // 固定自定义回调引用，便于空值检查和后续调用。
    final merger = mergeMoves;
    if (merger != null) {
      // 自定义策略完全负责判断；返回 null 时不再尝试默认策略。
      final mergedEvent = merger(pending.event, event);
      // 保留调用方定义的顺序边界。
      if (mergedEvent == null) return false;
      // 用新的合并结果替换尚未消费的尾部事件。
      pending.event = mergedEvent;
      return true;
    }

    // 默认策略只处理捕获模式一致的相邻鼠标移动。
    final previous = pending.event;
    if (previous['type'] != 'move' ||
        event['type'] != 'move' ||
        previous['captured'] != event['captured']) {
      return false;
    }
    // 缺失某个轴的位移按零处理，兼容只报告一个轴的输入。
    final dx = event['dx'] ?? 0;
    final dy = event['dy'] ?? 0;
    // 尾部事件可能已经累计过多次同方向位移。
    final previousDx = previous['dx'] ?? 0;
    final previousDy = previous['dy'] ?? 0;
    // 非数值、无穷值以及任一轴转向都保留原始事件，不参与合并。
    if (dx is! num ||
        dy is! num ||
        previousDx is! num ||
        previousDy is! num ||
        !dx.isFinite ||
        !dy.isFinite ||
        !previousDx.isFinite ||
        !previousDy.isFinite ||
        _changesDirection(previousDx, dx) ||
        _changesDirection(previousDy, dy)) {
      // 中间位置可能触发跨屏或边缘钳制，不能把转向轨迹抵消掉。
      return false;
    }
    // 保留最新绝对坐标及元数据，相对位移则累加以保持移动距离。
    pending.event = {
      ...event,
      'dx': previousDx + dx,
      'dy': previousDy + dy,
    };
    return true;
  }

  /// 按队列顺序执行输入，并统一处理限速、失败及空闲通知。
  Future<void> _drain() async {
    // 保存本轮通知对象；结束时必须唤醒等待此轮消费完成的调用方。
    final completion = _idle!;
    try {
      // 每轮重新检查长度，也会处理等待期间新加入的事件。
      while (_items.isNotEmpty) {
        // 仅移动事件额外限速；按键等事件仍保持原有队列顺序。
        if (_items.first.event['type'] == 'move' &&
            motionInterval > Duration.zero) {
          // 目标间隔减去距上次移动已过去的时间，得到剩余等待时长。
          final remaining = motionInterval.inMicroseconds -
              (_clock.elapsedMicroseconds - _lastMove);
          if (remaining > 0) {
            // 等待期间允许新移动继续并入队尾，减少后续发送次数。
            await Future<void>.delayed(Duration(microseconds: remaining));
          }
          // 等待期间可能被 clear 清空，不能直接 removeFirst。
          if (_items.isEmpty) continue;
        }
        // 消费前移出队首，保证入队合并不会修改正在执行的事件。
        final item = _items.removeFirst();
        try {
          if (item.event['type'] == 'move') {
            // 在实际开始消费时记时，让发送耗时计入下一次间隔。
            _lastMove = _clock.elapsedMicroseconds;
          }
          // 内部积压标记通过统一错误回调通知，不传给系统输入层。
          if (item.event['type'] == '_overflow') throw StateError('输入事件积压');
          // 等待此次输入处理结束，确保后续按键或移动不会抢先执行。
          await consume(item.event, item.context);
        } catch (error, stack) {
          // 只清除失败上下文的待处理项，保留其他上下文的独立输入。
          _items.removeWhere((pending) => pending.context == item.context);
          // 等待调用方完成故障处理后再继续消费。
          await onError(error, stack, item.context);
        }
      }
    } finally {
      // 此处没有 await，清空运行标记与通知完成之间不会插入新的 add。
      _idle = null;
      // 正常结束或异常退出都释放 idle 的等待者。
      completion.complete();
    }
  }
}
