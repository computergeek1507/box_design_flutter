import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import '../models/box_project.dart';
import '../models/vec2.dart';
import 'dxf_export.dart';
import 'template_library.dart';

const double _mmToPt = PdfPageFormat.mm;

/// Renders a [BoxProject] as a single-page, 1:1 scale vector PDF (stroke
/// only) suitable for a printed cut/reference sheet.
Future<Uint8List> exportProjectAsPdfBytes(BoxProject project, TemplateLibrary library) async {
  final entities = assembleProjectEntities(project, library);
  final notes = assembleProjectNotes(project, library);
  final pageWidthPt = project.boxWidth * _mmToPt;
  final pageHeightPt = project.boxHeight * _mmToPt;

  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(pageWidthPt, pageHeightPt, marginAll: 0),
      build: (context) {
        final noteFont = pw.Font.helvetica().getFont(context);
        return pw.CustomPaint(
          size: PdfPoint(pageWidthPt, pageHeightPt),
          painter: (canvas, size) {
            canvas
              ..setStrokeColor(PdfColors.black)
              ..setLineWidth(0.5);
            for (final entity in entities) {
              final points = entity.toPoints();
              if (points.isEmpty) continue;
              _moveTo(canvas, points.first);
              for (final p in points.skip(1)) {
                _lineTo(canvas, p);
              }
            }
            canvas.strokePath();

            // Drawing-layer notes (reference only), in a distinct colour.
            canvas
              ..setStrokeColor(PdfColors.deepOrange700)
              ..setFillColor(PdfColors.deepOrange700)
              ..setLineWidth(0.4);
            for (final entity in notes.shapes) {
              final points = entity.toPoints();
              if (points.isEmpty) continue;
              _moveTo(canvas, points.first);
              for (final p in points.skip(1)) {
                _lineTo(canvas, p);
              }
            }
            canvas.strokePath();
            for (final t in notes.texts) {
              if (t.text.isEmpty) continue;
              canvas
                ..saveContext()
                ..setTransform(Matrix4.identity()
                  ..translateByDouble(t.anchor.x * _mmToPt, t.anchor.y * _mmToPt, 0, 1)
                  ..rotateZ(t.rotationDeg * math.pi / 180))
                ..drawString(noteFont, t.height * _mmToPt, t.text, 0, 0)
                ..restoreContext();
            }
          },
        );
      },
    ),
  );

  return doc.save();
}

// PdfGraphics's own coordinate system already puts the origin at the page's
// bottom-left with Y increasing upward (see pw.CustomPaint, which passes the
// canvas through untransformed apart from that origin translation) --
// exactly mm-space's own Y-up convention, so points map straight across with
// no flip.
void _moveTo(PdfGraphics canvas, Vec2 p) {
  canvas.moveTo(p.x * _mmToPt, p.y * _mmToPt);
}

void _lineTo(PdfGraphics canvas, Vec2 p) {
  canvas.lineTo(p.x * _mmToPt, p.y * _mmToPt);
}
