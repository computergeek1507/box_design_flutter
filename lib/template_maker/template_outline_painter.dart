import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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

  const TemplateOutlinePainter({
    this.viewRectMm = Rect.zero,
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

    final outlinePaint = Paint()
      ..color = Colors.black
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
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final selectedPaint = Paint()
      ..color = Colors.lightBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final selectedFill = Paint()..color = Colors.lightBlue.withValues(alpha: 0.35);
    // Selected hole last so it sits on top of any overlapping neighbour.
    final ordered = [...holes.where((h) => !h.selected), ...holes.where((h) => h.selected)];
    for (final hole in ordered) {
      final paint = hole.selected ? selectedPaint : holePaint;
      if (hole.shape == TemplateMakerHoleShape.round) {
        final center = toPx(hole.center);
        final radiusPx = hole.diameter / 2 * scale;
        if (hole.selected) canvas.drawCircle(center, radiusPx, selectedFill);
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
        if (hole.selected) canvas.drawPath(path, selectedFill);
        canvas.drawPath(path, paint);
        final center = toPx(hole.center);
        _drawLabel(canvas, '${hole.slotLength.toStringAsFixed(1)}x${hole.slotWidth.toStringAsFixed(1)}', center + const Offset(6, -6),
            bold: hole.selected);
      }
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset at, {bool bold = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: bold ? Colors.lightBlue.shade900 : Colors.black87,
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
    return oldDelegate.viewRectMm != viewRectMm ||
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
