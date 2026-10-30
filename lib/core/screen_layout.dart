/// 对端屏幕相对于本机的排列方向。
enum PeerSide { left, right, top, bottom }

extension PeerSideGeometry on PeerSide {
  /// 左右排列时横向跨屏；共享边界上的位置由纵坐标决定。
  bool get horizontal => this == PeerSide.left || this == PeerSide.right;

  /// 从对端返回本机时，需要检测与本机出口相反的一侧。
  PeerSide get opposite => switch (this) {
        PeerSide.left => PeerSide.right, // 本机左侧对应对端右侧。
        PeerSide.right => PeerSide.left, // 本机右侧对应对端左侧。
        PeerSide.top => PeerSide.bottom, // 本机上侧对应对端下侧。
        PeerSide.bottom => PeerSide.top, // 本机下侧对应对端上侧。
      };
}

/// 用等大的逻辑屏幕描述排列；真实分辨率和 DPI 留给坐标映射处理。
/// 仅共享边界的重叠区允许切换，避免从没有相邻屏幕的位置穿出。
class ScreenArrangement {
  const ScreenArrangement(this.side, this.offset);

  /// 对端位于本机的哪一侧，决定跨屏时检测哪个边界。
  final PeerSide side;

  /// 对端沿共享边界的偏移量，以一个逻辑屏幕的边长为单位。
  /// 左右排列时正值表示向下偏移，上下排列时正值表示向右偏移。
  final double offset;

  /// 将鼠标沿边界的位置转成 0～1 的比例，消除两端尺寸差异。
  double tangent(ScreenRect rect, double x, double y) => side.horizontal
      ? rect.fractionY(y) // 左右跨屏保留纵向比例。
      : ((x - rect.x) / (rect.width - 1)).clamp(0, 1); // 上下跨屏保留横向比例。

  /// 检查当前位置是否落在允许切换的共享边界内。
  /// [fraction] 使用当前所在屏幕的边界比例；返回时设 [reverse] 为 true。
  /// [triggerRange] 限制在 0～1，表示启用重叠边界中间的多大比例。
  bool overlaps(double fraction,
      {bool reverse = false, double triggerRange = 1}) {
    // 去往对端时减去偏移；返回本机时加回偏移，得到另一端的比例。
    final mapped = fraction + (reverse ? offset : -offset);
    // 映射后落在另一块屏幕之外，说明这里没有可连接的边界。
    if (mapped < 0 || mapped > 1) return false;
    // 在本机坐标中，正偏移会截掉重叠区起点之前的部分。
    final start = (offset > 0 ? offset : 0.0).clamp(0.0, 1.0);
    // 负偏移会截掉重叠区末端之后的部分，终点仍限制在本机范围内。
    final end = (offset < 0 ? 1 + offset : 1.0).clamp(0.0, 1.0);
    // 无论行进方向如何，统一使用本机比例与上述区间比较。
    final coordinate = reverse ? mapped : fraction;
    // 将未启用的边界长度均分到两侧，使触发区域保持居中。
    final margin = (end - start) * (1 - triggerRange.clamp(0.0, 1.0)) / 2;
    // 区间端点也允许触发，避免共享边界端点出现无法切换的缝隙。
    return coordinate >= start + margin && coordinate <= end - margin;
  }

  /// 判断鼠标是否触达出口边缘；返回时检测对端的相反边缘。
  bool edge(ScreenRect rect, double x, double y, {bool reverse = false}) {
    // 正向使用布局方向，反向使用对端朝向本机的边缘。
    final edge = reverse ? side.opposite : side;
    // 右/下边界为起点加尺寸减一，匹配可用坐标的最后一个位置。
    return switch (edge) {
      PeerSide.left => x <= rect.x,
      PeerSide.right => x >= rect.x + rect.width - 1,
      PeerSide.top => y <= rect.y,
      PeerSide.bottom => y >= rect.y + rect.height - 1,
    };
  }

  /// 求一次相对移动与返回边界的交点，保留斜向移动真实的跨屏位置。
  /// 使用终点代替交点会使批量鼠标事件在跨屏时产生切向偏移。
  ({double x, double y}) returnIntersection(
      ScreenRect rect, double x, double y, double dx, double dy) {
    // 只用垂直于共享边界的位移求交点比例。
    final delta = side.horizontal ? dx : dy;
    // 对端在本机右侧时从对端左边返回，其余方向依此对应。
    final boundary = switch (side) {
      PeerSide.right => rect.x,
      PeerSide.left => rect.x + rect.width - 1,
      PeerSide.bottom => rect.y,
      PeerSide.top => rect.y + rect.height - 1,
    };
    // 取与跨屏方向相同的起点坐标，与上面的位移和边界配对。
    final start = side.horizontal ? x : y;
    // t 表示走完整段位移的比例；无垂直位移时取起点，且不外推线段。
    final t = delta == 0 ? 0.0 : ((boundary - start) / delta).clamp(0.0, 1.0);
    // 同时插值两个坐标，并裁剪到屏幕范围，保留交点的切向位置。
    return (x: rect.clampX(x + dx * t), y: rect.clampY(y + dy * t));
  }

  /// 将目标屏幕的边界比例换成实际落点；[returning] 表示回到本机。
  ({double x, double y}) point(ScreenRect rect, double fraction,
      {bool returning = false}) {
    // 去往对端从其相反边缘进入，回到本机从布局指定的边缘进入。
    final edge = returning ? side : side.opposite;
    // 限定切向比例，避免鼠标落在屏幕有效坐标之外。
    final f = fraction.clamp(0.0, 1.0);
    // 返回本机时向内退入屏幕尺寸的四分之一，限制为 1～12 个单位，
    // 减少立即再次跨屏；进入对端仅退入一个单位，保持移动连贯。
    final inset = returning
        ? ((side.horizontal ? rect.width : rect.height) / 4).clamp(1.0, 12.0)
        : 1.0;
    // 法向坐标由边缘和退入量决定，切向坐标由比例映射决定。
    return switch (edge) {
      PeerSide.left => (x: rect.x + inset, y: rect.atY(f)),
      PeerSide.right => (x: rect.x + rect.width - 1 - inset, y: rect.atY(f)),
      PeerSide.top => (x: rect.x + f * (rect.width - 1), y: rect.y + inset),
      PeerSide.bottom => (
          x: rect.x + f * (rect.width - 1),
          y: rect.y + rect.height - 1 - inset
        ),
    };
  }
}

/// 主显示器的原生坐标范围；Windows 像素和 macOS 点不能直接混用。
class ScreenRect {
  const ScreenRect(this.x, this.y, this.width, this.height);

  /// 屏幕原点和尺寸；原点可为负数，直接调用构造函数时需由调用方保证尺寸有效。
  final double x, y, width, height;

  /// 验证收到的屏幕信息，防止非法尺寸进入归一化和鼠标注入公式。
  factory ScreenRect.fromMap(Map<String, dynamic> map) {
    // 固定字段顺序，后续按下标构造坐标和宽高。
    final values = ['x', 'y', 'width', 'height'].map((key) {
      // 网络数据使用 dynamic，读取后必须逐项检查类型。
      final value = map[key];
      // 拒绝缺失字段、非数字、NaN 和无穷大，避免传播非法坐标。
      if (value is! num || !value.toDouble().isFinite) {
        throw const FormatException('无效的屏幕坐标');
      }
      // 统一为 double，让整数和小数形式的原生坐标使用同一套计算。
      return value.toDouble();
    }).toList();
    // 至少两个坐标单位，确保尺寸减一不为零；上限约束异常远端数据。
    if (values[2] < 2 ||
        values[3] < 2 ||
        values[2] > 65536 ||
        values[3] > 65536) {
      throw const FormatException('无效的屏幕尺寸');
    }
    // 校验通过后按 x、y、width、height 的顺序创建矩形。
    return ScreenRect(values[0], values[1], values[2], values[3]);
  }

  /// 使用协议约定的字段名发送屏幕信息，保留原点与原生尺寸。
  Map<String, double> toMap() =>
      {'x': x, 'y': y, 'width': width, 'height': height};

  /// 先把位移转为本机可用跨度的比例，再换算为目标屏幕的原生单位。
  /// 两轴独立缩放，支持不同分辨率、纵横比及 DPI 的屏幕组合。
  ({double dx, double dy}) mapDeltaTo(
          ScreenRect target, double dx, double dy) =>
      (
        // 横向保留位移占屏幕宽度的比例，原点偏移不影响相对位移。
        dx: dx * (target.width - 1) / (width - 1),
        // 纵向使用高度比例，不能复用宽度比例以免竖屏出现失真。
        dy: dy * (target.height - 1) / (height - 1)
      );

  /// 把横坐标限制在首尾有效坐标之间，避免注入到显示器范围之外。
  double clampX(double value) => value.clamp(x, x + width - 1);

  /// 把纵坐标限制在首尾有效坐标之间，避免超出上下边缘。
  double clampY(double value) => value.clamp(y, y + height - 1);

  /// 将绝对纵坐标转为屏幕内比例，原点可能不为零。
  double fractionY(double value) => ((value - y) / (height - 1)).clamp(0, 1);

  /// 将纵向比例还原为绝对坐标，先裁剪比例再补回屏幕原点。
  double atY(double fraction) => y + fraction.clamp(0, 1) * (height - 1);

  /// 左右排列专用：检测本机朝向对端的出口。
  bool atExit(double value, PeerSide side) =>
      side == PeerSide.right ? value >= x + width - 1 : value <= x;

  /// 左右排列专用：从对端入口向内一个单位，避免正好停在边界。
  double entryX(PeerSide side) =>
      side == PeerSide.right ? x + 1 : x + width - 2;

  /// 左右排列专用：检测对端朝向本机的返回边缘。
  bool atReturn(double value, PeerSide side) =>
      side == PeerSide.right ? value <= x : value >= x + width - 1;

  /// 左右排列专用：返回本机时退入 1～12 个单位，降低立即回切的概率。
  double returnX(PeerSide side) => side == PeerSide.right
      ? x + width - 1 - (width / 4).clamp(1, 12)
      : x + (width / 4).clamp(1, 12);
}
