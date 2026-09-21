import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/note_paint.dart';
import '../geometry/placed_annotations.dart';
import '../geometry/tessellate.dart';
import '../geometry/transform.dart';
import '../models/annotation.dart';
import '../models/box_project.dart' show kLayerGapMm;
import '../models/controller_template.dart';
import '../models/dxf_entity.dart';
import '../models/hole.dart';
import '../models/hole_preset.dart';
import '../models/vec2.dart';

/// What a palette item looks like, for the hover popup: cut geometry, the
/// drawing-layer notes drawn dimmer over it, and a one-line size caption.
class PreviewGeometry {
  final String title;
  final String caption;
  final List<DxfEntity> shapes;
  final List<DxfEntity> noteShapes;
  final List<PlacedText> noteTexts;

  const PreviewGeometry({
    required this.title,
    required this.caption,
    required this.shapes,
    this.noteShapes = const [],
    this.noteTexts = const [],
  });
}

String _mm(double v) => v.toStringAsFixed(v.roundToDouble() == v ? 0 : 1);

/// A two-layer box template is shown the way it lands in a project: layer 1
/// above layer 2.
PreviewGeometry templatePreview(ControllerTemplate t) {
  final layer2 = t.layer2Entities;
  if (layer2 != null && layer2.isNotEmpty) {
    List<DxfEntity> atOrigin(List<DxfEntity> e, [double lift = 0]) {
      final b = entitiesBoundingBox(e);
      return placeEntities(e, delta: Vec2(-b.minX, -b.minY + lift));
    }

    final b2 = entitiesBoundingBox(layer2);
    return PreviewGeometry(
      title: t.name,
      caption: '2 layers',
      shapes: [
        ...atOrigin(layer2),
        ...atOrigin(t.entities, b2.height + kLayerGapMm),
      ],
    );
  }
  final b = t.boundingBox;
  final notes = placeAnnotations(t.annotations);
  return PreviewGeometry(
    title: t.name,
    caption: '${_mm(b.width)} × ${_mm(b.height)} mm',
    shapes: t.entities,
    noteShapes: notes.shapes,
    noteTexts: notes.texts,
  );
}

PreviewGeometry holePresetPreview(HolePreset p) {
  final hole = Hole(
    id: 'preview',
    type: p.type,
    position: const Vec2(0, 0),
    diameter: p.diameter,
    slotLength: p.slotLength,
    slotWidth: p.slotWidth,
  );
  final caption = switch (p.type) {
    HoleType.screw => '⌀${_mm(p.diameter)} mm',
    HoleType.zipTie => 'Zip tie ${_mm(p.slotLength)} × ${_mm(p.slotWidth)} mm',
    HoleType.slot => 'Slot ${_mm(p.slotLength)} × ${_mm(p.slotWidth)} mm',
    HoleType.rectangle =>
      'Rectangle ${_mm(p.slotLength)} × ${_mm(p.slotWidth)} mm',
  };
  return PreviewGeometry(
    title: p.name,
    caption: caption,
    shapes: hole.toEntities(),
  );
}

/// Shows [preview] in a popup beside [child] once the pointer has rested on
/// it for [delay]. The popup ignores the pointer (so it never gets in the way
/// of the list underneath) and goes away on exit, click/drag start or scroll.
class HoverPreview extends StatefulWidget {
  final PreviewGeometry Function() preview;
  final Widget child;
  final Duration delay;

  const HoverPreview({
    super.key,
    required this.preview,
    required this.child,
    this.delay = const Duration(milliseconds: 350),
  });

  @override
  State<HoverPreview> createState() => _HoverPreviewState();
}

class _HoverPreviewState extends State<HoverPreview> {
  static const _width = 260.0;
  static const _canvasHeight = 180.0;
  static const _height = _canvasHeight + 56;

  Timer? _timer;
  OverlayEntry? _entry;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(widget.delay, _show);
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  void _show() {
    if (!mounted || _entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox;
    final rect =
        box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    final screen = overlayBox.size;

    var left = rect.right + 8;
    if (left + _width > screen.width - 8) {
      left = math.max(8, rect.left - _width - 8);
    }
    final top = (rect.center.dy - _height / 2)
        .clamp(8.0, math.max(8.0, screen.height - _height - 8))
        .toDouble();

    final data = widget.preview();
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        width: _width,
        height: _height,
        child: IgnorePointer(
          child: _PreviewCard(data: data, canvasHeight: _canvasHeight),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _schedule(),
      onExit: (_) => _hide(),
      child: Listener(
        onPointerDown: (_) => _hide(),
        onPointerSignal: (_) => _hide(),
        child: widget.child,
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final PreviewGeometry data;
  final double canvasHeight;

  const _PreviewCard({required this.data, required this.canvasHeight});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surfaceTint,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge,
            ),
            Text(
              data.caption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: canvasHeight,
              width: double.infinity,
              child: CustomPaint(
                painter: _PreviewPainter(
                  data: data,
                  lineColor: theme.colorScheme.onSurface,
                  noteColorValue: noteColor(
                    isDark: isDark,
                  ).withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  final PreviewGeometry data;
  final Color lineColor;
  final Color noteColorValue;

  /// Small items (a single hole) are not blown up to fill the popup.
  static const _maxPxPerMm = 12.0;
  static const _pad = 6.0;

  _PreviewPainter({
    required this.data,
    required this.lineColor,
    required this.noteColorValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final all = [...data.shapes, ...data.noteShapes];
    if (all.isEmpty) return;
    final bb = entitiesBoundingBox(all);
    final availW = size.width - _pad * 2, availH = size.height - _pad * 2;
    final scale = math.min(
      math.min(
        bb.width > 0 ? availW / bb.width : _maxPxPerMm,
        bb.height > 0 ? availH / bb.height : _maxPxPerMm,
      ),
      _maxPxPerMm,
    );
    final ox = (size.width - bb.width * scale) / 2;
    final oy = (size.height - bb.height * scale) / 2;
    Offset toPx(Vec2 p) =>
        Offset(ox + (p.x - bb.minX) * scale, oy + (bb.maxY - p.y) * scale);

    void draw(List<DxfEntity> entities, Color color) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      for (final e in entities) {
        final pts = e.toPoints();
        if (pts.isEmpty) continue;
        final first = toPx(pts.first);
        final path = Path()..moveTo(first.dx, first.dy);
        for (final p in pts.skip(1)) {
          final px = toPx(p);
          path.lineTo(px.dx, px.dy);
        }
        canvas.drawPath(path, paint);
      }
    }

    draw(data.shapes, lineColor);
    draw(data.noteShapes, noteColorValue);
    for (final t in data.noteTexts) {
      paintNoteText(canvas, t, toPx(t.anchor), scale, noteColorValue);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) =>
      old.data != data ||
      old.lineColor != lineColor ||
      old.noteColorValue != noteColorValue;
}
