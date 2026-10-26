import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/core/screen_layout.dart';

void main() {
  test('resolution matrix keeps normalized positions through all shared seams',
      () {
    const screens = [
      ScreenRect(-3840, -300, 3840, 2160),
      ScreenRect(100, 50, 1920, 1080),
      ScreenRect(0, 0, 7680, 4320),
      ScreenRect(-1512, 0, 1512, 982),
      ScreenRect(0, 0, 3440, 1440),
      ScreenRect(0, 0, 1080, 1920),
      ScreenRect(0, 0, 1366, 768),
      ScreenRect(0, 0, 8192, 1024)
    ];
    for (final source in screens) {
      for (final target in screens) {
        final mapped = source.mapDeltaTo(target, 123.5, -57.25);
        final roundTrip = target.mapDeltaTo(source, mapped.dx, mapped.dy);
        expect(roundTrip.dx, closeTo(123.5, 1e-9));
        expect(roundTrip.dy, closeTo(-57.25, 1e-9));
        for (final side in PeerSide.values) {
          for (final offset in [-.9, -.5, 0.0, .5, .9]) {
            final layout = ScreenArrangement(side, offset);
            final low = offset > 0 ? offset : 0.0,
                high = offset < 0 ? 1 + offset : 1.0;
            for (var i = 0; i <= 20; i++) {
              final fraction = low + (high - low) * i / 20;
              final entry = layout.point(target, fraction - offset);
              final reverse = layout.tangent(target, entry.x, entry.y);
              expect(layout.overlaps(reverse, reverse: true), isTrue,
                  reason: '$side $offset $fraction');
              final back =
                  layout.point(source, reverse + offset, returning: true);
              expect(layout.tangent(source, back.x, back.y),
                  closeTo(fraction, 1e-9));
            }
          }
        }
      }
    }
  });

  test('crossing preserves vertical fraction across different DPI and origins',
      () {
    const source = ScreenRect(-1920, 0, 1920, 1080);
    const target = ScreenRect(0, -100, 2560, 1440);
    final y = target.atY(source.fractionY(539.5));
    expect(y, 619.5);
    expect(source.atY(target.fractionY(y)), closeTo(539.5, 0.001));
    expect(source.atExit(-1, PeerSide.right), true);
    expect(target.entryX(PeerSide.right), 1);
    expect(target.atReturn(0, PeerSide.right), true);
    expect(source.returnX(PeerSide.right), -13);
  });
  test('left side is symmetric and movement clamps at unrelated edges', () {
    const screen = ScreenRect(0, 0, 1920, 1080);
    expect(screen.atExit(0, PeerSide.left), true);
    expect(screen.entryX(PeerSide.left), 1918);
    expect(screen.atReturn(1919, PeerSide.left), true);
    expect(screen.returnX(PeerSide.left), 12);
    expect(screen.clampY(-50), 0);
    expect(screen.clampX(2500), 1919);
  });
  test('all sides map overlapping seams symmetrically across DPI', () {
    const source = ScreenRect(-1920, -100, 1920, 1080);
    const target = ScreenRect(0, 50, 2560, 1440);
    for (final side in PeerSide.values) {
      for (final offset in [-.9, -.25, 0.0, .25, .9]) {
        final layout = ScreenArrangement(side, offset);
        final sourceFraction = (1 + offset) / 2;
        final remoteFraction = sourceFraction - offset;
        expect(layout.overlaps(sourceFraction), isTrue);
        expect(layout.overlaps(remoteFraction, reverse: true), isTrue);
        final point = layout.point(target, remoteFraction);
        expect(layout.tangent(target, point.x, point.y),
            closeTo(remoteFraction, 1e-9));
        final back =
            layout.point(source, remoteFraction + offset, returning: true);
        expect(layout.tangent(source, back.x, back.y),
            closeTo(sourceFraction, 1e-9));
        if (offset > 0) expect(layout.overlaps(0), isFalse);
        if (offset < 0) expect(layout.overlaps(1), isFalse);
      }
    }
  });
  test('rejects invalid or unbounded remote screen metadata', () {
    for (final width in [double.nan, double.infinity, 0, -5, 100000]) {
      expect(
          () => ScreenRect.fromMap(
              {'x': 0, 'y': 0, 'width': width, 'height': 1080}),
          throwsFormatException);
    }
  });
}
