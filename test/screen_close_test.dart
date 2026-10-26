import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_bridge/screen_workspace.dart';
import 'package:lan_bridge/core/screen_layout.dart';

void main() {
  testWidgets('close releases only its own screen without selecting it',
      (tester) async {
    final nodes = [
      const ScreenNode('a', '电脑 A', PeerSide.left, 0),
      const ScreenNode('b', '电脑 B', PeerSide.right, 0)
    ];
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, update) => ScreenWorkspace(
                    nodes: nodes,
                    available: const [],
                    onArrange: (id, side, offset) {},
                    onRequest: (device, side, offset) {},
                    onSelect: (_) => selected++,
                    onClose: (id) =>
                        update(() => nodes.removeWhere((n) => n.id == id)))))));
    await tester.tap(find.byKey(const ValueKey('close-a')));
    await tester.pumpAndSettle();
    expect(find.text('电脑 A'), findsNothing);
    expect(find.text('电脑 B'), findsOneWidget);
    expect(selected, 0);
  });
}
