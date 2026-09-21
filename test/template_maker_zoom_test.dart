import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

void main() {
  testWidgets('zoom with the wheel about the cursor, buttons and keys; pan with the middle button; fit resets', (tester) async {
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

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    final fit = painter().viewRectMm;
    final origin = tester.getTopLeft(canvas);
    expect(find.text('100%'), findsOneWidget);

    // Wheel up over a point zooms in and keeps the mm under the cursor put.
    final cursor = tester.getCenter(canvas) + const Offset(120, -80);
    Offset mmAt(Offset px) {
      final v = painter().viewRectMm;
      final size = tester.getSize(canvas);
      final scale = ((size.width - 64) / v.width).clamp(0, (size.height - 64) / v.height).toDouble();
      final local = px - origin;
      return Offset(
        v.left + (local.dx - (size.width - v.width * scale) / 2) / scale,
        v.bottom - (local.dy - (size.height - v.height * scale) / 2) / scale,
      );
    }

    final before = mmAt(cursor);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(cursor));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -400)));
    await tester.pump();
    final zoomed = painter().viewRectMm;
    expect(zoomed.width, lessThan(fit.width * 0.6));
    final after = mmAt(cursor);
    expect((after.dx - before.dx).abs(), lessThan(0.01));
    expect((after.dy - before.dy).abs(), lessThan(0.01));

    // Middle-button drag pans the view by the drag distance.
    final g = await tester.startGesture(cursor, kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await g.moveBy(const Offset(60, 0));
    await g.up();
    await tester.pump();
    expect(painter().viewRectMm.center.dx, lessThan(zoomed.center.dx)); // content moved right, view left
    expect(painter().viewRectMm.width, zoomed.width);

    // Buttons and Ctrl+minus zoom around the centre; fit resets everything.
    await tester.tap(find.byTooltip('Zoom in (Ctrl +)'));
    await tester.pump();
    expect(painter().viewRectMm.width, lessThan(zoomed.width));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(painter().viewRectMm.width, closeTo(zoomed.width, 0.01));

    await tester.tap(find.byTooltip(RegExp('^Fit the plate')));
    await tester.pump();
    expect(painter().viewRectMm, fit);
    expect(find.text('100%'), findsOneWidget);
  });
}
