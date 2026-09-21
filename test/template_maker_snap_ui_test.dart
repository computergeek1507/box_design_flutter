import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/controller_template.dart';
import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

void main() {
  testWidgets('dragging a hole snaps it to the grid; Alt drags freely', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The test font is much wider than the real one, so the existing side
    // panel overflows; that's not what this test is about.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      onError!(details);
    };
    addTearDown(() => FlutterError.onError = onError);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: const MaterialApp(home: TemplateMakerScreen())));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add round hole'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    expect(painter().showGrid, isTrue);
    final start = tester.getCenter(canvas);

    Future<void> dragBy(Offset from, Offset d) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(3, 2));
      await g.moveBy(d - const Offset(3, 2));
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    // Move the (centred) hole well away from any plate edge / centre line.
    await dragBy(start, const Offset(37, 23));
    var c = painter().holes.single.center;
    expect((c.x % 5).abs() < 1e-6 || (5 - c.x % 5).abs() < 1e-6, isTrue, reason: 'x=${c.x}');
    expect((c.y % 5).abs() < 1e-6 || (5 - c.y % 5).abs() < 1e-6, isTrue, reason: 'y=${c.y}');

    // Holding Alt: no snapping, so the position is no longer on the grid.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    // Grab the hole where it now sits (the preview fits the plate inside a 32 px margin).
    final size = tester.getSize(canvas);
    final p = painter();
    final scale = ((size.width - 64) / p.viewRectMm.width).clamp(0, (size.height - 64) / p.viewRectMm.height).toDouble();
    final hole = start + Offset((c.x - p.outlineWidth / 2) * scale, -(c.y - p.outlineHeight / 2) * scale);
    await dragBy(hole, const Offset(13, 7));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    c = painter().holes.single.center;
    expect(((c.x / 5) - (c.x / 5).round()).abs() > 1e-3 || ((c.y / 5) - (c.y / 5).round()).abs() > 1e-3, isTrue, reason: 'x=${c.x} y=${c.y}');

    await tester.runAsync(() async {
      final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final img = await ro.toImage(pixelRatio: 1);
      File('C:/Users/scoot/AppData/Local/Temp/claude/C--software-box-design/27c24883-a51d-40e8-95c1-b1633746effb/scratchpad/grid.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  });

  testWidgets('drawing layer: a selected rectangle can be resized by dragging its corner handle', (tester) async {
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

    // Box templates have no drawing layer, so switch the category first.
    await tester.tap(find.byType(DropdownButtonFormField<TemplateCategory>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('controller').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drawing'));
    await tester.pumpAndSettle();
    // The side panel is a lazy list: scroll until the Rectangle button is built.
    final panel = find.byType(ListView).first;
    for (var i = 0; i < 30 && find.text('Rectangle').evaluate().isEmpty; i++) {
      await tester.drag(panel, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Rectangle'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    expect(painter().noteHandles.length, 4);

    Offset px(Vec2 mm) {
      final size = tester.getSize(canvas);
      final p = painter();
      final scale = ((size.width - 64) / p.viewRectMm.width).clamp(0, (size.height - 64) / p.viewRectMm.height).toDouble();
      return tester.getCenter(canvas) + Offset((mm.x - p.outlineWidth / 2) * scale, -(mm.y - p.outlineHeight / 2) * scale);
    }

    final before = painter().noteHandles;
    final sw = before[0], ne = before[3];
    final g = await tester.startGesture(px(ne), kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(60, -40)); // one fast move, straight off the handle
    await tester.pump();
    await g.up();
    await tester.pump();

    final after = painter().noteHandles;
    expect(after[0], sw, reason: 'the opposite corner stays put');
    expect(after[3].x > ne.x && after[3].y > ne.y, isTrue, reason: 'the grabbed corner moved outward');
    expect((after[3].x % 5).abs() < 1e-6 || (5 - after[3].x % 5).abs() < 1e-6, isTrue, reason: 'snapped to the grid: ${after[3]}');
    expect(after[1].y, after[0].y);
    expect(after[2].x, after[0].x);
  });

  testWidgets('drawing layer: dragging the start and end points of a line, even with a fast drag', (tester) async {
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
    final panel = find.byType(ListView).first;
    for (var i = 0; i < 30 && find.text('Line').evaluate().isEmpty; i++) {
      await tester.drag(panel, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Line'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    Offset px(Vec2 mm) {
      final size = tester.getSize(canvas);
      final p = painter();
      final scale = ((size.width - 64) / p.viewRectMm.width).clamp(0, (size.height - 64) / p.viewRectMm.height).toDouble();
      return tester.getCenter(canvas) + Offset((mm.x - p.outlineWidth / 2) * scale, -(mm.y - p.outlineHeight / 2) * scale);
    }

    expect(painter().noteHandles.length, 2);
    var (start, end) = (painter().noteHandles[0], painter().noteHandles[1]);

    // One big, fast move straight off the end point.
    var g = await tester.startGesture(px(end), kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(120, -90));
    await tester.pump();
    await g.up();
    await tester.pump();
    var now = painter().noteHandles;
    expect(now[0], start, reason: 'the start point stays put');
    expect(now[1] != end, isTrue, reason: 'the end point moved: ${now[1]}');
    expect(now[1].x > end.x && now[1].y > end.y, isTrue);
    end = now[1];

    // And the start point, dragged the other way.
    g = await tester.startGesture(px(start), kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(-100, 60));
    await tester.pump();
    await g.up();
    await tester.pump();
    now = painter().noteHandles;
    expect(now[1], end, reason: 'the end point stays put');
    expect(now[0].x < start.x && now[0].y < start.y, isTrue, reason: 'start moved: ${now[0]}');
  });

  for (final (label, button, handles) in [('slot', 'Add slot', 4), ('rectangle', 'Add rectangle', 4), ('round hole', 'Add round hole', 1)]) {
    testWidgets('a $label can be resized by a fast drag on its handle', (tester) async {
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
      await tester.tap(find.byTooltip(button));
      await tester.pumpAndSettle();

      final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
      TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
      Offset px(Vec2 mm) {
        final size = tester.getSize(canvas);
        final p = painter();
        final scale = ((size.width - 64) / p.viewRectMm.width).clamp(0, (size.height - 64) / p.viewRectMm.height).toDouble();
        return tester.getCenter(canvas) + Offset((mm.x - p.outlineWidth / 2) * scale, -(mm.y - p.outlineHeight / 2) * scale);
      }

      expect(painter().holeHandles.length, handles);
      final centre = painter().holes.single.center;
      final before = painter().holes.single;
      // The east-most handle (a slot's length end, a rectangle's corner, a hole's radius).
      final grab = painter().holeHandles.reduce((a, b) => a.x >= b.x ? a : b);
      final g = await tester.startGesture(px(grab), kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(90, 0)); // one fast move, straight off the handle
      await tester.pump();
      await g.up();
      await tester.pump();

      final after = painter().holes.single;
      expect(after.center, centre, reason: 'the centre stays put');
      final grew = label == 'round hole' ? after.diameter > before.diameter : after.slotLength > before.slotLength;
      expect(grew, isTrue, reason: '$label did not grow');
    });
  }
}
