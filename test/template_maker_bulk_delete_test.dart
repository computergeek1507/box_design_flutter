import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/annotation.dart';
import 'package:box_design_flutter/models/controller_template.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';
import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

void main() {
  group('multi-selection on the drawing layer', () {
    late TemplateMakerController c;
    late TemplateMakerNote line, box, circle, text;

    setUp(() {
      c = TemplateMakerController();
      line = TemplateMakerNote(id: 'l', type: AnnotationType.line, x: 0, y: 0, x2: 10, y2: 10);
      box = TemplateMakerNote(id: 'b', type: AnnotationType.rect, x: 20, y: 20, width: 5, height: 5);
      circle = TemplateMakerNote(id: 'c', type: AnnotationType.circle, x: 40, y: 40, radius: 3);
      text = TemplateMakerNote(id: 't', type: AnnotationType.text, text: 'Hi', x: 60, y: 60, height: 5);
      c.notes.addAll([line, box, circle, text]);
    });

    test('a selection box picks notes it touches, not just ones it contains', () {
      expect(c.notesInRect(const Rect.fromLTRB(4, 4, 6, 6)), {'l'}); // crosses the diagonal line
      expect(c.notesInRect(const Rect.fromLTRB(0, 8, 2, 10)), isEmpty); // beside the diagonal, only its bbox
      expect(c.notesInRect(const Rect.fromLTRB(-1, -1, 30, 30)), {'l', 'b'});
      expect(c.notesInRect(const Rect.fromLTRB(36, 36, 38, 38)), {'c'}); // inside the circle's reach
      expect(c.notesInRect(const Rect.fromLTRB(59, 59, 61, 61)), {'t'});
      expect(c.notesInRect(const Rect.fromLTRB(-100, -100, 100, 100)), {'l', 'b', 'c', 't'});
    });

    test('toggle, set, select all and delete', () {
      c.selectNote('l');
      c.toggleNoteSelection('c');
      expect(c.selectedNoteIds, {'l', 'c'});
      expect(c.selectedNoteId, 'c');

      c.toggleNoteSelection('c');
      expect(c.selectedNoteIds, {'l'});
      expect(c.selectedNoteId, 'l');

      c.selectAllNotes();
      expect(c.selectedNoteIds, {'l', 'b', 'c', 't'});

      c.setSelectedNotes({'b', 't'});
      expect(c.deleteSelectedNotes(), 2);
      expect(c.notes.map((n) => n.id), ['l', 'c']);
      expect(c.selectedNoteIds, isEmpty);
      expect(c.selectedNoteId, isNull);
      expect(c.deleteSelectedNotes(), 0);
    });

    test('removing one note of a selection keeps the rest selected', () {
      c.setSelectedNotes({'l', 'b', 'c'});
      c.removeNote('c');
      expect(c.selectedNoteIds, {'l', 'b'});
      expect(c.selectedNoteId, isIn({'l', 'b'}));
    });

    test('moving the selection moves every selected note', () {
      c.setSelectedNotes({'l', 'b'});
      c.moveSelectedNotesBy(2, 3);
      expect((line.x, line.y, line.x2, line.y2), (2, 3, 12, 13));
      expect((box.x, box.y), (22, 23));
      expect((circle.x, circle.y), (40, 40));
    });

    test('selecting a single note again narrows a multi-selection', () {
      c.setSelectedNotes({'l', 'b'});
      c.selectNote(c.selectedNoteId);
      expect(c.selectedNoteIds, hasLength(1));
    });
  });

  testWidgets('drag a box around lines, or Ctrl+click them, then Delete removes them all', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      onError!(details);
    };
    addTearDown(() => FlutterError.onError = onError);

    await tester.pumpWidget(const MaterialApp(home: TemplateMakerScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<TemplateCategory>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('controller').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drawing'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    final center = tester.getCenter(canvas);

    Future<void> drag(Offset from, Offset to) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(6, 0));
      await g.moveTo(to);
      await g.up();
      await tester.pumpAndSettle();
    }

    Future<void> toggleLineTool() async {
      await tester.tap(find.byIcon(Icons.horizontal_rule));
      await tester.pumpAndSettle();
    }

    // The tool stays armed, so one arming draws all three lines, well apart.
    await toggleLineTool();
    for (final dy in [-100.0, 0.0, 100.0]) {
      await drag(center + Offset(-60, dy), center + Offset(60, dy));
    }
    expect(painter().notes, hasLength(3));
    await toggleLineTool(); // back to selecting

    // A box around the top two lines selects them; the third is left alone.
    await drag(center + const Offset(-110, -140), center + const Offset(110, 30));
    expect(painter().selectedNoteIds, hasLength(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(painter().notes, hasLength(1));

    // Ctrl+click: draw two more lines, add both plus the survivor by clicking.
    await toggleLineTool();
    for (final dy in [-100.0, 0.0]) {
      await drag(center + Offset(-60, dy), center + Offset(60, dy));
    }
    await toggleLineTool();
    expect(painter().notes, hasLength(3));

    // Lines snap to the 5 mm grid, so click where they actually ended up.
    final size = tester.getSize(canvas);
    final view = painter().viewRectMm; // the plate plus the room left around it
    final mmPx = (size.width - 64) / view.width < (size.height - 64) / view.height
        ? (size.width - 64) / view.width
        : (size.height - 64) / view.height;
    final ys = [for (final n in painter().notes) n.y]..sort();
    Offset onLine(double yMm) => center + Offset(0, -(yMm - painter().outlineHeight / 2) * mmPx);
    await tester.tapAt(onLine(ys.last), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(onLine(ys.first), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(painter().selectedNoteIds, hasLength(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(painter().notes, hasLength(1));
  });

  testWidgets('a draw tool stays armed for several shapes and each stays selected as drawn until Esc; leaving the canvas ends a drag', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      onError!(details);
    };
    addTearDown(() => FlutterError.onError = onError);

    await tester.pumpWidget(const MaterialApp(home: TemplateMakerScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<TemplateCategory>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('controller').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drawing'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    final center = tester.getCenter(canvas);

    Future<void> drag(Offset from, Offset to) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(6, 0));
      await g.moveTo(to);
      await g.up();
      await tester.pumpAndSettle();
    }

    // The tool stays armed: two drags draw two lines, and the latest is selected.
    await tester.tap(find.byIcon(Icons.horizontal_rule));
    await tester.pumpAndSettle();
    await drag(center + const Offset(-60, -100), center + const Offset(60, -100));
    expect(painter().notes, hasLength(1));
    expect(painter().selectedNoteIds, hasLength(1));
    await drag(center + const Offset(-60, 100), center + const Offset(60, 100));
    expect(painter().notes, hasLength(2));
    expect(painter().selectedNoteIds, hasLength(1));

    // Esc disarms the tool: the next drag is a selection box, not a third line.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await drag(center + const Offset(-200, 40), center + const Offset(200, 160));
    expect(painter().notes, hasLength(2));

    // Dragging a selection box out of the canvas (e.g. off the window) ends it,
    // even if no pointer-up ever comes.
    final g = await tester.startGesture(center + const Offset(-200, 160), kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(10, -10));
    await g.moveTo(center + const Offset(200, -200));
    await tester.pump();
    expect(painter().selectionRectMm, isNotNull);
    await g.moveTo(const Offset(20, 500)); // over the side panel: still dragging
    await tester.pump();
    expect(painter().selectionRectMm, isNotNull);
    await g.moveTo(center + const Offset(300, 0)); // back into the canvas
    await tester.pump();
    await g.moveTo(const Offset(1700, 500)); // off the window
    await tester.pump();
    expect(painter().selectionRectMm, isNull);
    await g.up();
    await tester.pumpAndSettle();
  });
}
