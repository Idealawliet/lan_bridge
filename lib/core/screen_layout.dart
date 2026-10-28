enum PeerSide { left, right, top, bottom }

extension PeerSideGeometry on PeerSide {
  bool get horizontal => this == PeerSide.left || this == PeerSide.right;
  PeerSide get opposite => switch (this) {
        PeerSide.left => PeerSide.right,
        PeerSide.right => PeerSide.left,
        PeerSide.top => PeerSide.bottom,
        PeerSide.bottom => PeerSide.top,
      };
}

/// Equal-sized logical tiles; offset is the tangent displacement in tile units.
/// Only overlapping edges connect. Native display sizes remain independent.
class ScreenArrangement {
  const ScreenArrangement(this.side, this.offset);
  final PeerSide side;
  final double offset;
  double tangent(ScreenRect rect, double x, double y) => side.horizontal
      ? rect.fractionY(y)
      : ((x - rect.x) / (rect.width - 1)).clamp(0, 1);
  /// [fraction] is normalized along the edge in the current screen's units.
  /// The offset maps it to the other tile; reverse crossings use the inverse
  /// mapping. A restricted trigger range is centered within the shared seam.
  bool overlaps(double fraction, {bool reverse = false, double triggerRange = 1}) {
    final mapped = fraction + (reverse ? offset : -offset);
    if (mapped < 0 || mapped > 1) return false;
    final start = (offset > 0 ? offset : 0.0).clamp(0.0, 1.0);
    final end = (offset < 0 ? 1 + offset : 1.0).clamp(0.0, 1.0);
    final coordinate = reverse ? mapped : fraction;
    final margin = (end - start) * (1 - triggerRange.clamp(0.0, 1.0)) / 2;
    return coordinate >= start + margin && coordinate <= end - margin;
  }

  bool edge(ScreenRect rect, double x, double y, {bool reverse = false}) {
    final edge = reverse ? side.opposite : side;
    return switch (edge) {
      PeerSide.left => x <= rect.x,
      PeerSide.right => x >= rect.x + rect.width - 1,
      PeerSide.top => y <= rect.y,
      PeerSide.bottom => y >= rect.y + rect.height - 1,
    };
  }

  /// Where a relative segment first reaches the return seam. Using the
  /// segment end would shift the tangent position on diagonal / batched moves.
  ({double x, double y}) returnIntersection(
      ScreenRect rect, double x, double y, double dx, double dy) {
    final delta = side.horizontal ? dx : dy;
    final boundary = switch (side) {
      PeerSide.right => rect.x,
      PeerSide.left => rect.x + rect.width - 1,
      PeerSide.bottom => rect.y,
      PeerSide.top => rect.y + rect.height - 1,
    };
    final start = side.horizontal ? x : y;
    final t = delta == 0 ? 0.0 : ((boundary - start) / delta).clamp(0.0, 1.0);
    return (x: rect.clampX(x + dx * t), y: rect.clampY(y + dy * t));
  }

  ({double x, double y}) point(ScreenRect rect, double fraction,
      {bool returning = false}) {
    final edge = returning ? side : side.opposite;
    final f = fraction.clamp(0.0, 1.0);
    // Re-enter the host away from the seam to prevent an immediate recross.
    // Entry to the target uses only one unit so movement feels continuous.
    final inset = returning
        ? ((side.horizontal ? rect.width : rect.height) / 4).clamp(1.0, 12.0)
        : 1.0;
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

/// Coordinates are native primary-display units; never assume equal DPI or size.
class ScreenRect {
  const ScreenRect(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
  factory ScreenRect.fromMap(Map<String, dynamic> map) {
    final values = ['x', 'y', 'width', 'height'].map((key) {
      final value = map[key];
      if (value is! num || !value.toDouble().isFinite) {
        throw const FormatException('无效的屏幕坐标');
      }
      return value.toDouble();
    }).toList();
    if (values[2] < 2 ||
        values[3] < 2 ||
        values[2] > 65536 ||
        values[3] > 65536) {
      throw const FormatException('无效的屏幕尺寸');
    }
    return ScreenRect(values[0], values[1], values[2], values[3]);
  }
  Map<String, double> toMap() =>
      {'x': x, 'y': y, 'width': width, 'height': height};

  /// Coordinates and deltas use the same native display units. Normalizing
  /// by the usable span also bridges Windows physical pixels and macOS points.
  ({double dx, double dy}) mapDeltaTo(
          ScreenRect target, double dx, double dy) =>
      (
        dx: dx * (target.width - 1) / (width - 1),
        dy: dy * (target.height - 1) / (height - 1)
      );
  double clampX(double value) => value.clamp(x, x + width - 1);
  double clampY(double value) => value.clamp(y, y + height - 1);
  double fractionY(double value) => ((value - y) / (height - 1)).clamp(0, 1);
  double atY(double fraction) => y + fraction.clamp(0, 1) * (height - 1);
  bool atExit(double value, PeerSide side) =>
      side == PeerSide.right ? value >= x + width - 1 : value <= x;
  double entryX(PeerSide side) =>
      side == PeerSide.right ? x + 1 : x + width - 2;
  bool atReturn(double value, PeerSide side) =>
      side == PeerSide.right ? value <= x : value >= x + width - 1;
  double returnX(PeerSide side) => side == PeerSide.right
      ? x + width - 1 - (width / 4).clamp(1, 12)
      : x + (width / 4).clamp(1, 12);
}
