import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

void main() {
  testWidgets('custom outline points can be selected and added by clicking', (tester) async {
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

    await tester.tap(find.text('Custom outline'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    expect(painter().useCustomOutline, isTrue);
    expect(painter().customOutlinePoints.length, 4);

    Offset px(Vec2 mm) {
      final size = tester.getSize(canvas);
      final p = painter();
      final view = p.viewRectMm;
      final scale = ((size.width - 64) / view.width).clamp(0, (size.height - 64) / view.height).toDouble();
      final origin = tester.getTopLeft(canvas) + Offset((size.width - view.width * scale) / 2, (size.height - view.height * scale) / 2);
      return origin + Offset((mm.x - view.left) * scale, (view.bottom - mm.y) * scale);
    }

    // Plain click on a corner point selects it.
    await tester.tapAt(px(painter().customOutlinePoints[2]), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().selectedOutlinePointIndex, 2);

    // "Add outline point" mode: a click adds a point.
    await tester.tap(find.text('Add outline point'));
    await tester.pumpAndSettle();
    await tester.tapAt(px(const Vec2(50, 50)), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().customOutlinePoints.length, 5);
  });

  testWidgets('a point added on the right edge joins that edge, not the selected point', (tester) async {
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
    await tester.tap(find.text('Custom outline'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    Offset px(Vec2 mm) {
      final size = tester.getSize(canvas);
      final view = painter().viewRectMm;
      final scale = ((size.width - 64) / view.width).clamp(0, (size.height - 64) / view.height).toDouble();
      final origin = tester.getTopLeft(canvas) + Offset((size.width - view.width * scale) / 2, (size.height - view.height * scale) / 2);
      return origin + Offset((mm.x - view.left) * scale, (view.bottom - mm.y) * scale);
    }

    // Default square: (0,0) (100,0) (100,100) (0,100). Select the bottom-left one.
    await tester.tapAt(px(const Vec2(0, 0)), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().selectedOutlinePointIndex, 0);

    await tester.tap(find.text('Add outline point'));
    await tester.pumpAndSettle();
    await tester.tapAt(px(const Vec2(100, 50)), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().customOutlinePoints, [const Vec2(0, 0), const Vec2(100, 0), const Vec2(100, 50), const Vec2(100, 100), const Vec2(0, 100)]);

    // And on the bottom edge, between the two bottom corners.
    await tester.tapAt(px(const Vec2(50, 0)), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().customOutlinePoints[1], const Vec2(50, 0));
  });
}
