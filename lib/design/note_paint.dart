import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/annotation.dart';

/// Colour used for drawing-layer notes (distinct from cut geometry). Teal in
/// light mode: the orange it used to be read as much the same as the red holes.
Color noteColor({required bool isDark}) => isDark ? Colors.orangeAccent.shade100 : Colors.teal.shade700;

/// Paints [text] with its bottom-left at [anchorPx] (screen px), rotated
/// counter-clockwise by the note's own angle, sized so a letter is about
/// [PlacedText.height] mm tall at [pxPerMm].
void paintNoteText(Canvas canvas, PlacedText text, Offset anchorPx, double pxPerMm, Color color) {
  if (text.text.isEmpty) return;
  final painter = TextPainter(
    text: TextSpan(text: text.text, style: TextStyle(color: color, fontSize: math.max(text.height * pxPerMm, 4))),
    textDirection: TextDirection.ltr,
  )..layout();
  canvas.save();
  canvas.translate(anchorPx.dx, anchorPx.dy);
  canvas.rotate(-text.rotationDeg * math.pi / 180);
  painter.paint(canvas, Offset(0, -painter.height));
  canvas.restore();
}
