import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../geometry/placed_annotations.dart';
import '../geometry/placed_entities.dart';
import '../geometry/tessellate.dart';
import '../models/box_project.dart';
import '../models/dxf_entity.dart';
import '../models/vec2.dart';
import '../services/units.dart';
import 'design_controller.dart';
import 'note_paint.dart';

/// Paints a [BoxProject] at [pixelsPerMm] scale. The canvas itself uses
/// screen (Y-down) pixels, so every mm-space point is flipped in Y before
/// drawing (mm-space is math/Y-up, matching DXF convention).
class DesignPainter extends CustomPainter {
  final DesignController controller;
  final double pixelsPerMm;
  final bool isDark;

  /// Room (mm) the canvas leaves around the box on every side; everything is
  /// drawn shifted by this much so items hanging off the box stay visible.
  final double marginMm;

  DesignPainter(this.controller, {required this.pixelsPerMm, this.isDark = false, this.marginMm = 0})
      : super(repaint: controller);

  Color get _outlineColor => isDark ? Colors.white : Colors.black;
  Color get _templateColor => isDark ? Colors.white70 : Colors.black87;
  Color get _holeColor => isDark ? Colors.redAccent.shade100 : Colors.red;
  Color get _selectedColor => isDark ? Colors.lightBlueAccent.shade100 : Colors.blue;
  Color get _measureColor => isDark ? Colors.deepPurple.shade300 : Colors.deepPurple;

  Offset _toPx(Vec2 p, double boxHeightMm) => Offset(p.x * pixelsPerMm, (boxHeightMm - p.y) * pixelsPerMm);

  @override
  void paint(Canvas canvas, Size size) {
    final project = controller.project;
    final boxHeightMm = project.boxHeight;

    canvas.save();
    canvas.translate(marginMm * pixelsPerMm, marginMm * pixelsPerMm);
    _drawGrid(canvas, project, boxHeightMm);
    _drawEntities(canvas, project.sheetOutline, boxHeightMm, color: _outlineColor, width: 2);
    if (project.dualLayer) {
      final boxes = project.plateBoxes;
      for (var i = 0; i < boxes.length; i++) {
        final label = TextPainter(
          text: TextSpan(text: 'Layer ${i + 1}', style: TextStyle(color: _outlineColor.withValues(alpha: 0.6), fontSize: 11, fontWeight: FontWeight.bold)),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, _toPx(Vec2(boxes[i].minX, boxes[i].maxY), boxHeightMm) + const Offset(6, 6));
      }
    }

    for (final placed in project.placedTemplates) {
      final template = controller.library.byId(placed.templateId);
      if (template == null) continue;
      final entities = placedTemplateEntities(template, placed);
      final selected = controller.selectedId == placed.id;
      _drawEntities(canvas, entities, boxHeightMm, color: selected ? _selectedColor : _templateColor, width: selected ? 1.6 : 1.0);
      _drawNameLabel(canvas, template.name, entitiesBoundingBox(entities), boxHeightMm, selected: selected);
      final notes = placedTemplateNotes(template, placed);
      if (notes.shapes.isNotEmpty) {
        _drawEntities(canvas, notes.shapes, boxHeightMm, color: noteColor(isDark: isDark), width: 1.0);
      }
      for (final t in notes.texts) {
        paintNoteText(canvas, t, _toPx(t.anchor, boxHeightMm), pixelsPerMm, noteColor(isDark: isDark));
      }
    }

    for (final hole in project.holes) {
      final selected = controller.selectedId == hole.id;
      _drawEntities(canvas, hole.toEntities(), boxHeightMm, color: selected ? _selectedColor : _holeColor, width: selected ? 1.6 : 1.0);
    }

    _drawMeasurement(canvas, boxHeightMm);
    canvas.restore();
  }

  void _drawMeasurement(Canvas canvas, double boxHeightMm) {
    final start = controller.measureStart;
    final end = controller.measureEnd;
    if (start == null) return;

    if (end == null) {
      // First click placed; waiting for the second.
      canvas.drawCircle(_toPx(start, boxHeightMm), 4, Paint()..color = _measureColor);
      return;
    }

    final p1 = _toPx(start, boxHeightMm);
    final p2 = _toPx(end, boxHeightMm);
    final color = _measureColor;
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    canvas.drawLine(p1, p2, linePaint);

    // Perpendicular tick marks at each end, like a dimension line.
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length > 0.001) {
      final perpX = -dy / length * 5;
      final perpY = dx / length * 5;
      canvas.drawLine(Offset(p1.dx - perpX, p1.dy - perpY), Offset(p1.dx + perpX, p1.dy + perpY), linePaint);
      canvas.drawLine(Offset(p2.dx - perpX, p2.dy - perpY), Offset(p2.dx + perpX, p2.dy + perpY), linePaint);
    }

    for (final p in [p1, p2]) {
      canvas.drawCircle(p, 3, Paint()..color = color);
    }

    final deltaMm = end.subtract(start);
    final distanceMm = math.sqrt(deltaMm.x * deltaMm.x + deltaMm.y * deltaMm.y);
    final label = 'ΔX ${mmWithInches(deltaMm.x)}  ΔY ${mmWithInches(deltaMm.y)}\n'
        '${mmWithInches(distanceMm)}';
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();

    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final labelRect = Rect.fromCenter(
      center: mid,
      width: textPainter.width + 8,
      height: textPainter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = color,
    );
    textPainter.paint(canvas, Offset(labelRect.left + 4, labelRect.top + 2));
  }

  void _drawNameLabel(Canvas canvas, String name, BoundingBox bbox, double boxHeightMm, {required bool selected}) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          color: selected ? (isDark ? Colors.lightBlue.shade200 : Colors.blue.shade900) : (isDark ? Colors.white60 : Colors.black54),
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      ellipsis: '…',
    )..layout(maxWidth: (bbox.width * pixelsPerMm - 4).clamp(0, double.infinity));

    // Top-left corner of the item's own bounding box (mm space is Y-up, so
    // that's the box's max-Y edge), inset a couple pixels from the corner.
    final corner = _toPx(Vec2(bbox.minX, bbox.maxY), boxHeightMm);
    textPainter.paint(canvas, Offset(corner.dx + 2, corner.dy + 2));
  }

  void _drawGrid(Canvas canvas, BoxProject project, double boxHeightMm) {
    final paint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    const step = 10.0;
    for (double x = 0; x <= project.boxWidth; x += step) {
      canvas.drawLine(_toPx(Vec2(x, 0), boxHeightMm), _toPx(Vec2(x, project.boxHeight), boxHeightMm), paint);
    }
    for (double y = 0; y <= project.boxHeight; y += step) {
      canvas.drawLine(_toPx(Vec2(0, y), boxHeightMm), _toPx(Vec2(project.boxWidth, y), boxHeightMm), paint);
    }
  }

  void _drawEntities(
    Canvas canvas,
    List<DxfEntity> entities,
    double boxHeightMm, {
    required Color color,
    required double width,
  }) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final entity in entities) {
      final points = entity.toPoints();
      if (points.isEmpty) continue;
      final start = _toPx(points.first, boxHeightMm);
      final path = Path()..moveTo(start.dx, start.dy);
      for (final p in points.skip(1)) {
        final px = _toPx(p, boxHeightMm);
        path.lineTo(px.dx, px.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DesignPainter oldDelegate) => true;
}
