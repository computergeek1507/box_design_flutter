import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/annotation.dart';
import 'package:box_design_flutter/models/controller_template.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';
import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

void main() {
  setUp(TemplateMakerController.clearClipboard);

  TemplateMakerController make() => TemplateMakerController()
    ..setOutlineWidth(200)
    ..setOutlineHeight(100);

  group('controller clipboard', () {
    test('nothing selected means nothing to copy, and an empty clipboard pastes nothing', () {
      final c = make();
      expect((c.canCopy, c.canPaste, c.copySelection(), c.paste()), (false, false, false, null));
    });

    test('a pasted hole nudges off the original, then off each earlier paste', () {
      final c = make()..addSlot();
      final h = c.holes.single;
      c.updateHole(h.id, x: 40, y: 30, slotLength: 20, slotWidth: 6, rotationDeg: 30);
      expect(c.copySelection(), isTrue);

      final first = c.paste();
      final second = c.paste();
      expect(c.holes.length, 3);
      final a = c.holes[1], b = c.holes[2];
      expect((a.id == first, b.id == second, c.selectedHoleId), (true, true, second));
      expect((a.x, a.y), (45.0, 35.0));
      expect((b.x, b.y), (50.0, 40.0));
      expect((b.shape, b.slotLength, b.slotWidth, b.rotationDeg), (TemplateMakerHoleShape.slot, 20.0, 6.0, 30.0));
      expect({h.id, a.id, b.id}.length, 3);
    });

    test('the clipboard is a snapshot: later edits to the original do not change what is pasted', () {
      final c = make()..addHole();
      final h = c.holes.single;
      c.updateHole(h.id, x: 10, y: 10, diameter: 6);
      c.copySelection();
      c.updateHole(h.id, x: 99, y: 99, diameter: 20);
      c.paste();
      final pasted = c.holes.last;
      expect((pasted.x, pasted.y, pasted.diameter), (10.0, 10.0, 6.0));
    });

    test('a hole copied on layer 1 pastes onto layer 2 at the same spot', () {
      final c = make()..setDualLayer(true); // layer 2 starts as a copy of layer 1
      c.addHole();
      final h = c.holes.single;
      c.updateHole(h.id, x: 33, y: 22, diameter: 7);
      c.copySelection();

      c.selectLayer(TemplateMakerLayer.layer2);
      final before = c.holes.length;
      c.paste();
      final pasted = c.holes.last;
      expect(c.holes.length, before + 1);
      expect((pasted.x, pasted.y, pasted.diameter), (33.0, 22.0, 7.0));

      // Back on layer 1 the original is untouched and there is only the one.
      c.selectLayer(TemplateMakerLayer.layer1);
      expect(c.holes.where((e) => e.x == 33 && e.y == 22).length, 1);
    });

    test('a copied hole cannot be pasted onto the drawing layer', () {
      final c = make()..setCategory(TemplateCategory.controller);
      c.addHole();
      c.copySelection();
      c.selectLayer(TemplateMakerLayer.drawing);
      expect((c.canPaste, c.paste()), (false, null));
    });

    test('notes copy and paste on the drawing layer, moving a line by both ends', () {
      final c = make()..setCategory(TemplateCategory.controller);
      c.selectLayer(TemplateMakerLayer.drawing);
      final line = c.addNote(AnnotationType.line);
      final (x, y, x2, y2) = (line.x, line.y, line.x2, line.y2);
      expect(c.copySelection(), isTrue);
      c.paste();
      final copy = c.notes.last;
      expect(copy.id == line.id, isFalse);
      expect((copy.x, copy.y, copy.x2, copy.y2), (x + 5, y + 5, x2 + 5, y2 + 5));
      expect(c.selectedNoteId, copy.id);

      // A hole layer can't take a note.
      c.selectLayer(TemplateMakerLayer.layer1);
      expect(c.canPaste, isFalse);
    });

    test('the clipboard is shared: an item copied in one template maker pastes into another', () {
      final a = make()..addRect();
      a.updateHole(a.holes.single.id, x: 70, y: 20, slotLength: 16, slotWidth: 9);
      a.copySelection();

      final b = make();
      expect(b.canPaste, isTrue);
      b.paste();
      final pasted = b.holes.single;
      expect((pasted.shape, pasted.x, pasted.y, pasted.slotLength, pasted.slotWidth), (TemplateMakerHoleShape.rect, 70.0, 20.0, 16.0, 9.0));
    });
  });

  group('keyboard', () {
    Future<void> pump(WidgetTester tester) async {
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
    }

    Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter(WidgetTester tester) => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;

    testWidgets('Ctrl+C then Ctrl+V pastes the selected hole', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Add slot'));
      await tester.pumpAndSettle();
      expect(painter(tester).holes.length, 1);

      await ctrl(tester, LogicalKeyboardKey.keyC);
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(painter(tester).holes.length, 2);
      final holes = painter(tester).holes;
      expect((holes[1].center.x - holes[0].center.x, holes[1].center.y - holes[0].center.y), (5.0, 5.0));
      expect(holes[1].selected, isTrue);

      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(painter(tester).holes.length, 3);
    });

    testWidgets('while typing in a text field, Ctrl+V is left to the text and pastes no hole', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Add round hole'));
      await tester.pumpAndSettle();
      await ctrl(tester, LogicalKeyboardKey.keyC);

      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      await ctrl(tester, LogicalKeyboardKey.keyV);
      expect(painter(tester).holes.length, 1);
    });
  });
}
