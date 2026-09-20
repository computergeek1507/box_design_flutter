import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';

Future<ui.Image> _image(int w, int h) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint());
  return recorder.endRecording().toImage(w, h);
}

void main() {
  _selectionTests();
  _imageOpsTests();
  _detectionTests();
}

void _imageOpsTests() {
  testWidgets('reference image fits, scales from a corner and keeps aspect', (tester) async {
    final c = TemplateMakerController()..setOutlineWidth(200)..setOutlineHeight(100);
    c.refImage = await tester.runAsync(() => _image(400, 200));

    c.fitImageToOutline();
    expect((c.imageWidth, c.imageHeight, c.imageX, c.imageY), (200.0, 100.0, 0.0, 0.0));

    c.setImageSize(width: 100);
    expect(c.imageHeight, 50.0);

    // Drag the top-right corner out to (150, 999): locked aspect ignores Y.
    c.scaleImageFromCorner(const Vec2(0, 0), const Vec2(150, 999));
    expect((c.imageWidth, c.imageHeight), (150.0, 75.0));

    // Drag the bottom-left corner (fixed = top-right at 150,75) up-left.
    c.scaleImageFromCorner(const Vec2(150, 75), const Vec2(50, -10));
    expect((c.imageX, c.imageY, c.imageWidth, c.imageHeight), (50.0, 25.0, 100.0, 50.0));

    c.setImageLockAspect(false);
    c.setImageSize(height: 80);
    expect((c.imageWidth, c.imageHeight), (100.0, 80.0));
  });
}

Future<ui.Image> _drawing() {
  const w = 600.0, h = 400.0;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(const ui.Rect.fromLTWH(0, 0, w, h), ui.Paint()..color = const ui.Color(0xFFF8F9FB));
  final fill = ui.Paint()..color = const ui.Color(0xFFD3DEF7);
  final white = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
  final stroke = ui.Paint()
    ..color = const ui.Color(0xFF2B5BD7)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  void shape(ui.Rect r, {bool round = false, bool board = false}) {
    final rr = round ? ui.RRect.fromRectAndRadius(r, ui.Radius.circular(r.height / 2)) : ui.RRect.fromRectAndRadius(r, ui.Radius.zero);
    c.drawRRect(rr, board ? fill : white);
    c.drawRRect(rr, stroke);
  }

  shape(const ui.Rect.fromLTRB(50, 50, 550, 350), board: true); // 500 x 300 px
  shape(const ui.Rect.fromLTRB(100, 80, 140, 120), round: true); // 40px circle at (120,100)
  shape(const ui.Rect.fromLTRB(400, 75, 460, 105), round: true); // 60x30 slot at (430,90)
  shape(const ui.Rect.fromLTRB(100, 280, 130, 310)); // 30px square at (115,295)
  // A tinted, gridded (non-ink) patch outside the board must not confuse it.
  c.drawRect(const ui.Rect.fromLTWH(560, 360, 40, 40), ui.Paint()..color = const ui.Color(0xFFE0E0E0));
  return rec.endRecording().toImage(w.toInt(), h.toInt());
}

void _detectionTests() {
  testWidgets('auto-fit scales the image onto the outline and finds round, slot and rect holes', (tester) async {
    final c = TemplateMakerController()..setOutlineWidth(250)..setOutlineHeight(150);
    c.refImage = await tester.runAsync(_drawing);

    final mismatch = await tester.runAsync(c.autoFitImageToOutline);
    expect(mismatch, lessThan(1));
    // 500px outline -> 250mm: 0.5 mm/px; image origin so that px (50,350) -> mm (0,0).
    expect(c.imageWidth, closeTo(300, 1.5));
    expect(c.imageX, closeTo(-25, 1));
    expect(c.imageY, closeTo(-25, 1));

    final added = await tester.runAsync(c.detectHolesFromImage);
    expect(added, 3);
    final round = c.holes.singleWhere((h) => h.shape == TemplateMakerHoleShape.round);
    expect((round.x, round.y), (35.0, 125.0));
    expect(round.diameter, closeTo(20, 1));
    final slot = c.holes.singleWhere((h) => h.shape == TemplateMakerHoleShape.slot);
    expect(slot.x, closeTo(190, 1));
    expect(slot.y, closeTo(130, 1));
    expect(slot.slotLength, closeTo(30, 1.5));
    expect(slot.slotWidth, closeTo(15, 1.5));
    final rect = c.holes.singleWhere((h) => h.shape == TemplateMakerHoleShape.rect);
    expect(rect.x, closeTo(32.5, 1));
    expect(rect.y, closeTo(27.5, 1));

    // Running it again doesn't duplicate anything.
    expect(await tester.runAsync(c.detectHolesFromImage), 0);
  });

  test('rectangle holes survive export and re-load', () {
    final c = TemplateMakerController()..setOutlineWidth(100)..setOutlineHeight(80);
    c.holes.add(TemplateMakerHole(id: 'r', x: 30, y: 40, shape: TemplateMakerHoleShape.rect, slotLength: 10, slotWidth: 6, rotationDeg: 90));
    final back = TemplateMakerController()..loadFromTemplate(c.toTemplate());
    expect((back.outlineWidth, back.outlineHeight), (100.0, 80.0));
    final r = back.holes.single;
    expect(r.shape, TemplateMakerHoleShape.rect);
    expect((r.x, r.y), (30.0, 40.0));
    expect((r.slotLength, r.slotWidth), (10.0, 6.0));
    expect(r.rotationDeg, closeTo(90, 1e-6));
  });
}

void _selectionTests() {
  test('adding selects the new hole; removing the selected hole clears the selection', () {
    final c = TemplateMakerController();
    c.addHole();
    final first = c.holes.single.id;
    expect(c.selectedHoleId, first);
    c.addSlot();
    final second = c.holes.last.id;
    expect(c.selectedHoleId, second);
    c.selectHole(first);
    c.removeHole(second);
    expect(c.selectedHoleId, first);
    c.removeHole(first);
    expect(c.selectedHoleId, isNull);
  });
}
