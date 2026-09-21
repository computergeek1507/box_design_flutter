import 'package:flutter_test/flutter_test.dart';
import 'package:box_design_flutter/models/annotation.dart';

import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';

void main() {
  TemplateMakerController make() => TemplateMakerController()
    ..setOutlineWidth(200)
    ..setOutlineHeight(100);

  test('snaps to the grid when nothing else is near', () {
    final c = make()
      ..setGridMm(5)
      ..setSnapToObjects(false);
    final r = c.snapDragPoint(const Vec2(12.4, 47.6), toleranceMm: 3);
    expect((r.point.x, r.point.y, r.guideX, r.guideY), (10.0, 50.0, null, null));

    c.setGridMm(2);
    expect(c.snapDragPoint(const Vec2(13.1, 7.9), toleranceMm: 3).point, const Vec2(14, 8));
  });

  test('objects win over the grid within tolerance, per axis, and report guides', () {
    final c = make()..setGridMm(10);
    // x is within tolerance of the plate's centre line (100); y is not near anything.
    final r = c.snapDragPoint(const Vec2(101.5, 23), toleranceMm: 3);
    expect((r.point.x, r.point.y, r.guideX, r.guideY), (100.0, 20.0, 100.0, null));

    // Plate edges snap too.
    final edge = c.snapDragPoint(const Vec2(2, 99), toleranceMm: 3);
    expect((edge.point.x, edge.point.y, edge.guideX, edge.guideY), (0.0, 100.0, 0.0, 100.0));
  });

  test('aligns to another hole but never to the dragged one itself', () {
    final c = make()..setGridMm(10);
    c.addHole();
    final id = c.holes.single.id;
    c.updateHole(id, x: 32.5, y: 21.5);

    final other = c.snapDragPoint(const Vec2(33, 60), toleranceMm: 3);
    expect((other.point.x, other.guideX), (32.5, 32.5));
    expect(c.snapDragPoint(const Vec2(60, 23), toleranceMm: 3).point.y, 21.5);

    final self = c.snapDragPoint(const Vec2(33, 23), excludeHoleId: id, toleranceMm: 3);
    expect((self.point.x, self.point.y, self.guideX, self.guideY), (30.0, 20.0, null, null));
  });

  test('a dragged note aligns with other notes', () {
    final c = make()..setGridMm(10);
    final a = c.addNote(AnnotationType.rect);
    final b = c.addNote(AnnotationType.rect);
    c.moveNoteBy(a.id, 41.3 - a.x, 0);
    final r = c.snapDragPoint(Vec2(42, 77), excludeNoteId: b.id, toleranceMm: 3);
    expect((r.point.x, r.guideX), (41.3, 41.3));
  });

  test('with snapping off the point passes through', () {
    final c = make()
      ..setSnapToGrid(false)
      ..setSnapToObjects(false);
    final r = c.snapDragPoint(const Vec2(12.34, 56.78), toleranceMm: 3);
    expect((r.point, r.guideX, r.guideY), (const Vec2(12.34, 56.78), null, null));
  });

  group('dragging the handles of a drawing-layer note', () {
    test('a line moves either end without touching the other', () {
      final c = make();
      final n = c.addNote(AnnotationType.line);
      final (x2, y2) = (n.x2, n.y2);
      c.dragNoteHandle(n.id, NoteHandle.start, const Vec2(10, 20));
      expect((n.x, n.y, n.x2, n.y2), (10.0, 20.0, x2, y2));
      c.dragNoteHandle(n.id, NoteHandle.end, const Vec2(60, 70));
      expect((n.x, n.y, n.x2, n.y2), (10.0, 20.0, 60.0, 70.0));
      expect(c.noteHandles(n).map((h) => h.handle), [NoteHandle.start, NoteHandle.end]);
    });

    test('a rectangle resizes about the opposite corner, and flips when dragged past it', () {
      final c = make();
      final n = c.addNote(AnnotationType.rect);
      c.dragNoteHandle(n.id, NoteHandle.cornerSW, const Vec2(10, 10));
      c.dragNoteHandle(n.id, NoteHandle.cornerNE, const Vec2(40, 35));
      expect((n.x, n.y, n.width, n.height), (10.0, 10.0, 30.0, 25.0));
      expect(c.noteHandles(n).map((h) => h.point), [
        const Vec2(10, 10),
        const Vec2(40, 10),
        const Vec2(10, 35),
        const Vec2(40, 35),
      ]);

      // Drag the SW corner past the fixed NE corner: the box flips over it.
      final fixed = c.noteRectFixedCorner(n, NoteHandle.cornerSW);
      expect(fixed, const Vec2(40, 35));
      c.dragNoteHandle(n.id, NoteHandle.cornerSW, const Vec2(50, 45), fixed: fixed);
      expect((n.x, n.y, n.width, n.height), (40.0, 35.0, 10.0, 10.0));
    });

    test('a circle takes its radius from the pointer, a text note its size from the baseline end', () {
      final c = make();
      final circle = c.addNote(AnnotationType.circle);
      c.dragNoteHandle(circle.id, NoteHandle.radius, Vec2(circle.x + 12, circle.y));
      expect(circle.radius, 12);

      final text = c.addNote(AnnotationType.text); // 'Note': 4 characters
      expect(noteTextWidthMm(text), closeTo(4 * text.height * 0.6, 1e-9));
      c.dragNoteHandle(text.id, NoteHandle.textSize, Vec2(text.x + 24, text.y));
      expect(text.height, closeTo(10, 1e-9));

      // Rotated 90 degrees the baseline runs up the sheet.
      text.rotationDeg = 90;
      final handle = c.noteHandles(text).single.point;
      expect((handle.x - text.x).abs() < 1e-9, isTrue);
      expect(handle.y - text.y, closeTo(noteTextWidthMm(text), 1e-9));
      c.dragNoteHandle(text.id, NoteHandle.textSize, Vec2(text.x, text.y + 12));
      expect(text.height, closeTo(5, 1e-9));
    });

    test('nothing can be dragged to zero size', () {
      final c = make();
      final r = c.addNote(AnnotationType.rect);
      c.dragNoteHandle(r.id, NoteHandle.cornerNE, Vec2(r.x, r.y));
      expect(r.width > 0 && r.height > 0, isTrue);
      final circle = c.addNote(AnnotationType.circle);
      c.dragNoteHandle(circle.id, NoteHandle.radius, Vec2(circle.x, circle.y));
      expect(circle.radius > 0, isTrue);
    });
  });

  group('dragging the handles of a hole, slot or rectangle', () {
    test('a round hole gets its diameter from the pointer, keeping its centre', () {
      final c = make();
      c.addHole();
      final h = c.holes.single;
      final (cx, cy) = (h.x, h.y);
      expect(c.holeHandles(h).single.point, Vec2(cx + h.diameter / 2, cy));
      c.dragHoleHandle(h.id, HoleHandle.radius, Vec2(cx + 5, cy + 0));
      expect((h.diameter, h.x, h.y), (10.0, cx, cy));
    });

    test('a slot resizes length and width separately, and follows its rotation', () {
      final c = make();
      c.addSlot();
      final h = c.holes.single;
      c.dragHoleHandle(h.id, HoleHandle.lengthPos, Vec2(h.x + 15, h.y));
      expect((h.slotLength, h.slotWidth), (30.0, 4.0));
      c.dragHoleHandle(h.id, HoleHandle.widthNeg, Vec2(h.x, h.y - 3));
      expect((h.slotLength, h.slotWidth), (30.0, 6.0));
      expect(c.holeHandles(h).length, 4);

      // Rotated 90 degrees the length runs up the sheet.
      h.rotationDeg = 90;
      final end = c.holeHandles(h).first.point;
      expect((end.x - h.x).abs() < 1e-9, isTrue);
      expect(end.y - h.y, closeTo(15, 1e-9));
      c.dragHoleHandle(h.id, HoleHandle.lengthPos, Vec2(h.x, h.y + 10));
      expect(h.slotLength, closeTo(20, 1e-9));
    });

    test('a rectangle resizes from any corner, symmetrically, and never collapses', () {
      final c = make();
      c.addRect();
      final h = c.holes.single;
      expect(h.shape, TemplateMakerHoleShape.rect);
      expect(c.holeHandles(h).length, 4);
      c.dragHoleHandle(h.id, HoleHandle.cornerSW, Vec2(h.x - 10, h.y - 7));
      expect((h.slotLength, h.slotWidth), (20.0, 14.0));
      c.dragHoleHandle(h.id, HoleHandle.cornerNE, Vec2(h.x, h.y));
      expect(h.slotLength > 0 && h.slotWidth > 0, isTrue);
    });
  });
}
