import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/screen_workspace.dart';
import 'package:lan_bridge/core/screen_layout.dart';

void main() {
  test('edges and corners snap with a remaining crossing passage', () {
    const tile = Size(150, 92);
    final right = EdgeSnap.near(const Offset(157, 4), tile)!;
    expect(right.side, PeerSide.right);
    expect(right.offset, 0);
    final corner = EdgeSnap.near(const Offset(151, 92), tile)!;
    expect(corner.side, PeerSide.right);
    expect(corner.offset, .9);
    final top = EdgeSnap.near(const Offset(0, -100), tile)!;
    expect(top.side, PeerSide.top);
  });
  test('distant and overlapping free positions do not silently apply a layout',
      () {
    expect(EdgeSnap.near(const Offset(350, 200), const Size(150, 92)), isNull);
    expect(EdgeSnap.near(Offset.zero, const Size(150, 92)), isNull);
  });
}
