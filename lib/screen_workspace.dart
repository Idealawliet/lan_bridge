import 'package:flutter/material.dart';
import 'core/screen_layout.dart';
import 'core/lan_discovery.dart';

class ScreenNode {
  const ScreenNode(this.id, this.name, this.side, this.offset,
      {this.selected = false});
  final String id, name;
  final PeerSide side;
  final double offset;
  final bool selected;
}

class EdgeSnap {
  const EdgeSnap(this.position, this.side, this.offset);
  final Offset position;
  final PeerSide side;
  final double offset;
  static EdgeSnap? near(Offset p, Size tile, {double threshold = 24}) {
    final candidates = <EdgeSnap>[];
    for (final side in PeerSide.values) {
      final horizontal = side.horizontal;
      final extent = horizontal ? tile.height : tile.width;
      var tangent = horizontal ? p.dy : p.dx;
      // Align centres or near corners; retain a 10% crossing passage.
      for (final line in [-extent * .9, 0.0, extent * .9]) {
        if ((tangent - line).abs() < threshold) {
          tangent = line;
          break;
        }
      }
      if (tangent.abs() > extent * .9 + threshold) continue;
      tangent = tangent.clamp(-extent * .9, extent * .9);
      final point = switch (side) {
        PeerSide.left => Offset(-tile.width, tangent),
        PeerSide.right => Offset(tile.width, tangent),
        PeerSide.top => Offset(tangent, -tile.height),
        PeerSide.bottom => Offset(tangent, tile.height),
      };
      if ((point - p).distance <= threshold * 1.5) {
        candidates.add(EdgeSnap(point, side, tangent / extent));
      }
    }
    candidates.sort((a, b) =>
        (a.position - p).distance.compareTo((b.position - p).distance));
    return candidates.isEmpty ? null : candidates.first;
  }

  static Offset forLayout(PeerSide side, double offset, Size size) =>
      switch (side) {
        PeerSide.left => Offset(-size.width, offset * size.height),
        PeerSide.right => Offset(size.width, offset * size.height),
        PeerSide.top => Offset(offset * size.width, -size.height),
        PeerSide.bottom => Offset(offset * size.width, size.height),
      };
}

class ScreenWorkspace extends StatefulWidget {
  const ScreenWorkspace(
      {super.key,
      required this.nodes,
      required this.available,
      required this.onArrange,
      required this.onRequest,
      required this.onSelect,
      this.onClose,
      this.closeEnabled = true,
      this.enabled = true,
      this.referenceName = '本机 · 键鼠主机'});
  final List<ScreenNode> nodes;
  final List<LanDevice> available;
  final void Function(String id, PeerSide side, double offset) onArrange;
  final void Function(LanDevice device, PeerSide side, double offset) onRequest;
  final void Function(String id) onSelect;
  final void Function(String id)? onClose;
  final bool enabled;
  final bool closeEnabled;
  final String referenceName;
  @override
  State<ScreenWorkspace> createState() => _ScreenWorkspaceState();
}

class _ScreenWorkspaceState extends State<ScreenWorkspace> {
  final _canvas = GlobalKey();
  String? _dragging;
  Offset _draft = Offset.zero;
  String _hint = '';
  Widget _card(String name,
          {bool selected = false,
          bool host = false,
          String subtitle = '拖动排列',
          double width = 160}) =>
      Container(
          width: width,
          height: 112,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: selected && !host
                      ? const Color(0xFF8179E7)
                      : const Color(0xFFDADCE5),
                  width: selected && !host ? 1.5 : 1),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF292740).withValues(alpha: .08),
                    blurRadius: 14,
                    offset: const Offset(0, 5))
              ]),
          child: Column(children: [
            Expanded(
                child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: host
                                ? const [Color(0xFF3E4358), Color(0xFF242836)]
                                : selected
                                    ? const [
                                        Color(0xFF9C92ED),
                                        Color(0xFF635BDB)
                                      ]
                                    : const [
                                        Color(0xFFECEBF6),
                                        Color(0xFFD9DBEA)
                                      ])),
                    child: Icon(
                        host
                            ? Icons.laptop_mac_rounded
                            : Icons.desktop_windows_rounded,
                        size: 25,
                        color: host || selected
                            ? Colors.white.withValues(alpha: .85)
                            : const Color(0xFF9B9DB2)))),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF303345))),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 9,
                    color: selected && !host
                        ? const Color(0xFF635BDB)
                        : const Color(0xFF989BA8))),
          ]));

  Widget _availableCard(LanDevice device) => Container(
      width: 218,
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE6E7EF)),
          borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
                color: const Color(0xFFF1F0FB),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(
                device.platform.toLowerCase().contains('mac')
                    ? Icons.laptop_mac_rounded
                    : Icons.desktop_windows_rounded,
                size: 21,
                color: const Color(0xFF7973B0))),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF303345))),
              const SizedBox(height: 3),
              Text(device.host,
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFF979BA9))),
            ])),
        const SizedBox(width: 6),
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: device.busy ? Colors.orange : const Color(0xFF54B795))),
      ]));

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('屏幕布局',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
                color: Color(0xFF292D40))),
        if (_dragging != null)
          Text(_hint,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9B9EAB))),
        const SizedBox(height: 16),
        if (widget.available.isNotEmpty) ...[
          Text('可用设备 · ${widget.available.length}',
              style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                  color: Color(0xFF858995))),
          const SizedBox(height: 10),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(spacing: 10, children: [
                for (final device in widget.available)
                  Draggable<LanDevice>(
                      data: device,
                      maxSimultaneousDrags:
                          widget.enabled && !device.busy ? 1 : 0,
                      feedback: Material(
                          color: Colors.transparent,
                          child: Opacity(
                              opacity: .85, child: _availableCard(device))),
                      childWhenDragging:
                          Opacity(opacity: .35, child: _availableCard(device)),
                      child: Tooltip(
                          message: '${device.host}:${device.port}',
                          child: _availableCard(device))),
              ])),
          const SizedBox(height: 16),
        ],
        LayoutBuilder(builder: (context, c) {
          final tile = Size((c.maxWidth / 3.3).clamp(90.0, 180.0), 112);
          final origin = Offset((c.maxWidth - tile.width) / 2, 139);
          return DragTarget<LanDevice>(
              onWillAcceptWithDetails: (d) => widget.enabled && !d.data.busy,
              onAcceptWithDetails: (d) {
                final box =
                    _canvas.currentContext!.findRenderObject()! as RenderBox;
                final local = box.globalToLocal(d.offset) -
                    origin -
                    Offset(tile.width / 2, tile.height / 2);
                final snap = EdgeSnap.near(local, tile, threshold: 30);
                final side = snap?.side ??
                    (local.dx.abs() > local.dy.abs()
                        ? (local.dx < 0 ? PeerSide.left : PeerSide.right)
                        : (local.dy < 0 ? PeerSide.top : PeerSide.bottom));
                widget.onRequest(d.data, side, snap?.offset ?? 0);
              },
              builder: (context, candidates, rejected) => Container(
                  key: _canvas,
                  height: 390,
                  width: double.infinity,
                  decoration: BoxDecoration(
                      color: candidates.isEmpty
                          ? const Color(0xFFF8F9FC)
                          : const Color(0xFFF0EDFC),
                      border: Border.all(
                          color: candidates.isEmpty
                              ? const Color(0xFFE9EAF1)
                              : const Color(0xFF8179E7)),
                      borderRadius: BorderRadius.circular(14)),
                  child: Stack(clipBehavior: Clip.hardEdge, children: [
                    const Positioned.fill(
                        child: IgnorePointer(
                            child: CustomPaint(painter: _GridPainter()))),
                    const Positioned(
                        top: 14,
                        left: 16,
                        child: Text('被控区域',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF9B9EAB)))),
                    Positioned(
                        left: origin.dx,
                        top: origin.dy,
                        child: _card(widget.referenceName,
                            selected: true,
                            host: true,
                            subtitle: '键鼠主机',
                            width: tile.width)),
                    if (_dragging != null &&
                        EdgeSnap.near(_draft, tile) != null)
                      Positioned(
                          left: origin.dx +
                              EdgeSnap.near(_draft, tile)!.position.dx,
                          top: origin.dy +
                              EdgeSnap.near(_draft, tile)!.position.dy,
                          child: IgnorePointer(
                              child: Container(
                                  width: tile.width,
                                  height: tile.height,
                                  decoration: BoxDecoration(
                                      color: const Color(0x22087F77),
                                      border: Border.all(
                                          color: const Color(0xFF8179E7),
                                          width: 3),
                                      borderRadius:
                                          BorderRadius.circular(12))))),
                    for (final node in widget.nodes)
                      Builder(builder: (context) {
                        final p = _dragging == node.id
                            ? _draft
                            : EdgeSnap.forLayout(node.side, node.offset, tile);
                        return Positioned(
                            left: origin.dx + p.dx,
                            top: origin.dy + p.dy,
                            child: GestureDetector(
                                key: ValueKey('screen-${node.id}'),
                                behavior: HitTestBehavior.opaque,
                                onTap: () => widget.onSelect(node.id),
                                onPanStart: !widget.enabled
                                    ? null
                                    : (_) => setState(() {
                                          _dragging = node.id;
                                          _draft = p;
                                        }),
                                onPanUpdate: !widget.enabled
                                    ? null
                                    : (d) => setState(() {
                                          _draft += d.delta;
                                          final snap =
                                              EdgeSnap.near(_draft, tile);
                                          _hint = snap == null
                                              ? '手动排列中 · 靠近主机边缘或角点后松开'
                                              : '吸附预览 · 松开应用布局（保留至少 10% 穿越通道）';
                                        }),
                                onPanEnd: !widget.enabled
                                    ? null
                                    : (_) {
                                        final snap =
                                            EdgeSnap.near(_draft, tile);
                                        setState(() {
                                          _dragging = null;
                                          _hint = snap == null
                                              ? '未靠近相接边缘，已恢复原位置'
                                              : '已吸附边缘并应用排列';
                                        });
                                        if (snap != null) {
                                          widget.onArrange(
                                              node.id, snap.side, snap.offset);
                                        }
                                      },
                                onPanCancel: () =>
                                    setState(() => _dragging = null),
                                child: Stack(children: [
                                  _card(node.name,
                                      selected: node.selected,
                                      width: tile.width,
                                      subtitle: _dragging == node.id &&
                                              EdgeSnap.near(_draft, tile) !=
                                                  null
                                          ? '吸附就绪'
                                          : node.selected
                                              ? '当前控制'
                                              : '已连接'),
                                  if (widget.onClose != null)
                                    Positioned(
                                        top: 2,
                                        right: 2,
                                        child: IconButton(
                                            key: ValueKey('close-${node.id}'),
                                            tooltip: '放弃控制',
                                            padding: EdgeInsets.zero,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                    width: 24, height: 24),
                                            iconSize: 16,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: widget.closeEnabled
                                                ? () => widget.onClose!(node.id)
                                                : null,
                                            style: IconButton.styleFrom(
                                                backgroundColor: Colors.white
                                                    .withValues(alpha: .92),
                                                foregroundColor:
                                                    const Color(0xFF74758A)),
                                            icon: const Icon(Icons.close))),
                                ])));
                      }),
                    if (widget.nodes.isEmpty)
                      const Positioned(
                          bottom: 20,
                          left: 16,
                          right: 16,
                          child: Text('将设备拖到这里',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12, color: Color(0xFF9B9EAB)))),
                  ])));
        }),
      ]);
}

class _GridPainter extends CustomPainter {
  const _GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFDFE1EA);
    for (double x = 12; x < size.width; x += 20) {
      for (double y = 12; y < size.height; y += 20) {
        canvas.drawCircle(Offset(x, y), .7, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}
