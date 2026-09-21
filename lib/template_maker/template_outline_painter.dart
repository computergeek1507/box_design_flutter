import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design/note_paint.dart';
import '../models/annotation.dart';
import '../models/dxf_entity.dart';
import '../models/vec2.dart';
import 'template_maker_controller.dart';

/// Scale-to-fit preview of a template being built: the outline rectangle
/// (optionally corner-filleted, corner-chamfered, or corner-notched) plus
/// every hole, round or slot, each labeled with its size. mm-space is
/// math/Y-up (matching the rest of the app's DXF convention); the canvas is
/// screen Y-down, so points are flipped in Y before drawing.
class TemplateOutlinePainter extends CustomPainter {
  final double outlineWidth;
  final double outlineHeight;
  final TemplateMakerCornerStyle cornerStyle;
  final double cornerSize;
  final List<
      ({
        TemplateMakerHoleShape shape,
        Vec2 center,
        double diameter,
        double slotLength,
        double slotWidth,
        double rotationDeg,
        bool selected,
      })> holes;

  /// Optional tracing image, placed by [imageRectMm] (left/top = its
  /// bottom-left corner in template mm, width/height = its size in mm).
  final ui.Image? image;
  final Rect imageRectMm;
  final double imageOpacity;

  /// The mm region shown (left/right = X range, top/bottom = min/max Y).
  /// Rect.zero frames just the outline.
  final Rect viewRectMm;
  final bool isDark;

  /// Drawing-layer mode: the plate is drawn faded as a reference and the
  /// [notes] are drawn on top; otherwise no notes are shown.
  final bool drawingMode;
  final List<TemplateMakerNote> notes;
  final String? selectedNoteId;

  /// Every selected note (a superset of [selectedNoteId]); all are highlighted.
  final Set<String> selectedNoteIds;

  /// A drag-selection box in template mm (min-Y as top), drawn in drawing mode.
  final Rect? selectionRectMm;

  /// Drag handles of the selected note (template mm), drawn in drawing mode.
  final List<Vec2> noteHandles;

  /// Drag handles of the selected hole/slot/rectangle (template mm).
  final List<Vec2> holeHandles;

  /// Outside drawing mode, draw the [notes] dimmed underneath the holes as a
  /// reference (never selected, never hit-tested).
  final bool ghostNotes;

  /// Grid lines every [gridMm] (major line every fifth), anchored at (0, 0),
  /// and the alignment guides ([guideX]/[guideY], template mm) shown while a
  /// dragged item is snapped to another object.
  final bool showGrid;
  final double gridMm;
  final double? guideX;
  final double? guideY;

  /// Measurement overlay (template mm); [measureHover] is the snap target
  /// under the cursor while measuring.
  final Vec2? measureStart;
  final Vec2? measureEnd;
  final Vec2? measureHover;

  const TemplateOutlinePainter({
    this.viewRectMm = Rect.zero,
    this.isDark = false,
    this.drawingMode = false,
    this.notes = const [],
    this.selectedNoteId,
    this.selectedNoteIds = const {},
    this.selectionRectMm,
    this.noteHandles = const [],
    this.holeHandles = const [],
    this.ghostNotes = false,
    this.showGrid = false,
    this.gridMm = 5,
    this.guideX,
    this.guideY,
    this.measureStart,
    this.measureEnd,
    this.measureHover,
    this.image,
    this.imageRectMm = Rect.zero,
    this.imageOpacity = 0.5,
    required this.outlineWidth,
    required this.outlineHeight,
    this.cornerStyle = TemplateMakerCornerStyle.fillet,
    this.cornerSize = 0,
    required this.holes,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (outlineWidth <= 0 || outlineHeight <= 0) return;
    const margin = 32.0;
    final availableW = size.width - margin * 2;
    final availableH = size.height - margin * 2;
    if (availableW <= 0 || availableH <= 0) return;
    final view = viewRectMm.isEmpty ? Rect.fromLTRB(0, 0, outlineWidth, outlineHeight) : viewRectMm;
    final scale = math.min(availableW / view.width, availableH / view.height);
    final originX = (size.width - view.width * scale) / 2;
    final originY = (size.height - view.height * scale) / 2;

    Offset toPx(Vec2 p) => Offset(originX + (p.x - view.left) * scale, originY + (view.bottom - p.y) * scale);

    final img = image;
    if (img != null && imageRectMm.width > 0 && imageRectMm.height > 0) {
      final dst = Rect.fromPoints(
        toPx(Vec2(imageRectMm.left, imageRectMm.top)),
        toPx(Vec2(imageRectMm.right, imageRectMm.bottom)),
      );
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        dst,
        Paint()
          ..color = Colors.white.withValues(alpha: imageOpacity)
          ..filterQuality = FilterQuality.medium,
      );
      canvas.drawRect(dst, Paint()..color = Colors.teal..style = PaintingStyle.stroke..strokeWidth = 1);
      final handlePaint = Paint()..color = Colors.teal;
      for (final corner in [dst.topLeft, dst.topRight, dst.bottomLeft, dst.bottomRight]) {
        canvas.drawRect(Rect.fromCenter(center: corner, width: 9, height: 9), handlePaint);
      }
    }

    if (showGrid) _paintGrid(canvas, toPx, scale, view);
    if (!drawingMode && ghostNotes) _paintNotes(canvas, toPx, scale, ghost: true);

    final outlinePaint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withValues(alpha: drawingMode ? 0.3 : 1.0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final cornerAmount = cornerSize <= 0 ? 0.0 : math.min(cornerSize, math.min(outlineWidth, outlineHeight) / 2);
    if (cornerAmount <= 0) {
      canvas.drawRect(Rect.fromPoints(toPx(const Vec2(0, 0)), toPx(Vec2(outlineWidth, outlineHeight))), outlinePaint);
    } else if (cornerStyle == TemplateMakerCornerStyle.fillet) {
      final outlineRect = Rect.fromPoints(toPx(const Vec2(0, 0)), toPx(Vec2(outlineWidth, outlineHeight)));
      canvas.drawRRect(RRect.fromRectAndRadius(outlineRect, Radius.circular(cornerAmount * scale)), outlinePaint);
    } else {
      final vertices = cornerStyle == TemplateMakerCornerStyle.chamfer
          ? chamferedRectVertices(outlineWidth, outlineHeight, cornerAmount)
          : notchedRectVertices(outlineWidth, outlineHeight, cornerAmount);
      final pts = vertices.map((v) => toPx(v.point)).toList();
      canvas.drawPath(Path()..addPolygon(pts, true), outlinePaint);
    }

    final holePaint = Paint()
      ..color = (isDark ? Colors.redAccent.shade100 : Colors.red).withValues(alpha: drawingMode ? 0.3 : 1.0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final selectedPaint = Paint()
      ..color = Colors.lightBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final selectedFill = Paint()..color = Colors.lightBlue.withValues(alpha: 0.35);
    // Selected hole last so it sits on top of any overlapping neighbour.
    final ordered = drawingMode ? holes : [...holes.where((h) => !h.selected), ...holes.where((h) => h.selected)];
    for (final hole in ordered) {
      final paint = hole.selected && !drawingMode ? selectedPaint : holePaint;
      if (hole.shape == TemplateMakerHoleShape.round) {
        final center = toPx(hole.center);
        final radiusPx = hole.diameter / 2 * scale;
        if (hole.selected && !drawingMode) canvas.drawCircle(center, radiusPx, selectedFill);
        canvas.drawCircle(center, radiusPx, paint);
        _drawLabel(canvas, '\u2300${hole.diameter.toStringAsFixed(1)}', center + Offset(radiusPx + 4, -radiusPx - 4),
            bold: hole.selected);
      } else {
        final outline = DxfPolyline(
          hole.shape == TemplateMakerHoleShape.rect
              ? rectVertices(hole.slotLength, hole.slotWidth)
              : stadiumVertices(hole.slotLength, hole.slotWidth),
          closed: true,
        ).transformed(delta: hole.center, rotationDeg: hole.rotationDeg);
        final path = Path()..addPolygon(outline.toPoints().map(toPx).toList(), true);
        if (hole.selected && !drawingMode) canvas.drawPath(path, selectedFill);
        canvas.drawPath(path, paint);
        final center = toPx(hole.center);
        _drawLabel(canvas, '${hole.slotLength.toStringAsFixed(1)}x${hole.slotWidth.toStringAsFixed(1)}', center + const Offset(6, -6),
            bold: hole.selected);
      }
    }

    if (drawingMode) _paintNotes(canvas, toPx, scale);
    _paintHandles(canvas, toPx, drawingMode ? noteHandles : holeHandles);
    if (drawingMode) _paintSelectionRect(canvas, toPx);
    _paintGuides(canvas, toPx, view);
    _paintMeasure(canvas, toPx);
  }

  void _paintSelectionRect(Canvas canvas, Offset Function(Vec2) toPx) {
    final r = selectionRectMm;
    if (r == null) return;
    final box = Rect.fromPoints(toPx(Vec2(r.left, r.top)), toPx(Vec2(r.right, r.bottom)));
    canvas.drawRect(box, Paint()..color = Colors.lightBlue.withValues(alpha: 0.15));
    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.lightBlue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _paintHandles(Canvas canvas, Offset Function(Vec2) toPx, List<Vec2> handles) {
    final fill = Paint()..color = isDark ? Colors.black : Colors.white;
    final border = Paint()
      ..color = Colors.lightBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final h in handles) {
      final r = Rect.fromCenter(center: toPx(h), width: 9, height: 9);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, border);
    }
  }

  void _paintGrid(Canvas canvas, Offset Function(Vec2) toPx, double scale, Rect view) {
    // The view Rect is built as (left, minY, right, maxY): top = min Y, bottom = max Y.
    final minY = view.top, maxY = view.bottom;
    if (gridMm <= 0) return;
    final stepPx = gridMm * scale;
    // Too dense to read: thin it to the major lines, or drop it altogether.
    if (stepPx * 5 < 6) return;
    final drawMinor = stepPx >= 5;
    final base = isDark ? Colors.white : Colors.black;
    final minor = Paint()
      ..color = base.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = base.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    final firstX = (view.left / gridMm).ceil(), lastX = (view.right / gridMm).floor();
    final firstY = (minY / gridMm).ceil(), lastY = (maxY / gridMm).floor();
    for (var i = firstX; i <= lastX; i++) {
      final isMajor = i % 5 == 0;
      if (!isMajor && !drawMinor) continue;
      final x = i * gridMm;
      canvas.drawLine(toPx(Vec2(x, minY)), toPx(Vec2(x, maxY)), isMajor ? major : minor);
    }
    for (var j = firstY; j <= lastY; j++) {
      final isMajor = j % 5 == 0;
      if (!isMajor && !drawMinor) continue;
      final y = j * gridMm;
      canvas.drawLine(toPx(Vec2(view.left, y)), toPx(Vec2(view.right, y)), isMajor ? major : minor);
    }
  }

  void _paintGuides(Canvas canvas, Offset Function(Vec2) toPx, Rect view) {
    final minY = view.top, maxY = view.bottom;
    final paint = Paint()
      ..color = (isDark ? Colors.pinkAccent.shade100 : Colors.pink).withValues(alpha: 0.85)
      ..strokeWidth = 1;
    final gx = guideX, gy = guideY;
    if (gx != null) canvas.drawLine(toPx(Vec2(gx, minY)), toPx(Vec2(gx, maxY)), paint);
    if (gy != null) canvas.drawLine(toPx(Vec2(view.left, gy)), toPx(Vec2(view.right, gy)), paint);
  }

  void _paintNotes(Canvas canvas, Offset Function(Vec2) toPx, double scale, {bool ghost = false}) {
    for (final n in notes) {
      final selected = !ghost && (n.id == selectedNoteId || selectedNoteIds.contains(n.id));
      final color = selected ? Colors.lightBlue : noteColor(isDark: isDark).withValues(alpha: ghost ? 0.35 : 1.0);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : 1.5;
      switch (n.type) {
        case AnnotationType.text:
          paintNoteText(canvas, PlacedText(n.text, Vec2(n.x, n.y), n.height, n.rotationDeg), toPx(Vec2(n.x, n.y)), scale, color);
        case AnnotationType.line:
          canvas.drawLine(toPx(Vec2(n.x, n.y)), toPx(Vec2(n.x2, n.y2)), paint);
        case AnnotationType.rect:
          canvas.drawRect(Rect.fromPoints(toPx(Vec2(n.x, n.y)), toPx(Vec2(n.x + n.width, n.y + n.height))), paint);
        case AnnotationType.circle:
          canvas.drawCircle(toPx(Vec2(n.x, n.y)), n.radius * scale, paint);
      }
    }
  }

  void _paintMeasure(Canvas canvas, Offset Function(Vec2) toPx) {
    final color = isDark ? Colors.deepPurple.shade300 : Colors.deepPurple;
    final hover = measureHover;
    if (hover != null) {
      canvas.drawCircle(
        toPx(hover),
        7,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final start = measureStart;
    if (start == null) return;
    final p1 = toPx(start);
    final end = measureEnd;
    if (end == null) {
      canvas.drawCircle(p1, 4, Paint()..color = color);
      return;
    }
    final p2 = toPx(end);
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, linePaint);
    final dx = p2.dx - p1.dx, dy = p2.dy - p1.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length > 0.001) {
      final px = -dy / length * 5, py = dx / length * 5;
      canvas.drawLine(Offset(p1.dx - px, p1.dy - py), Offset(p1.dx + px, p1.dy + py), linePaint);
      canvas.drawLine(Offset(p2.dx - px, p2.dy - py), Offset(p2.dx + px, p2.dy + py), linePaint);
    }
    for (final p in [p1, p2]) {
      canvas.drawCircle(p, 3, Paint()..color = color);
    }
    final d = end.subtract(start);
    final label = '\u0394X ${d.x.toStringAsFixed(2)}  \u0394Y ${d.y.toStringAsFixed(2)}\n'
        '${math.sqrt(d.x * d.x + d.y * d.y).toStringAsFixed(2)} mm';
    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final rect = Rect.fromCenter(center: mid, width: tp.width + 8, height: tp.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), Paint()..color = color);
    tp.paint(canvas, Offset(rect.left + 4, rect.top + 2));
  }

  void _drawLabel(Canvas canvas, String text, Offset at, {bool bold = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: bold ? (isDark ? Colors.lightBlue.shade200 : Colors.lightBlue.shade900) : (isDark ? Colors.white70 : Colors.black87),
          fontSize: 11,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant TemplateOutlinePainter oldDelegate) {
    return oldDelegate.drawingMode != drawingMode ||
        oldDelegate.selectedNoteId != selectedNoteId ||
        oldDelegate.selectedNoteIds != selectedNoteIds ||
        oldDelegate.selectionRectMm != selectionRectMm ||
        oldDelegate.ghostNotes != ghostNotes ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.gridMm != gridMm ||
        oldDelegate.guideX != guideX ||
        oldDelegate.guideY != guideY ||
        oldDelegate.measureStart != measureStart ||
        oldDelegate.measureEnd != measureEnd ||
        oldDelegate.measureHover != measureHover ||
        oldDelegate.viewRectMm != viewRectMm ||
        oldDelegate.isDark != isDark ||
        oldDelegate.image != image ||
        oldDelegate.imageRectMm != imageRectMm ||
        oldDelegate.imageOpacity != imageOpacity ||
        oldDelegate.outlineWidth != outlineWidth ||
        oldDelegate.outlineHeight != outlineHeight ||
        oldDelegate.cornerStyle != cornerStyle ||
        oldDelegate.cornerSize != cornerSize ||
        oldDelegate.holes != holes;
  }
}
