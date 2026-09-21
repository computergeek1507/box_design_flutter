import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/controller_template.dart';
import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

void main() {
  testWidgets('Delete removes the selected drawing-layer line, even after typing in a field', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The test font is wider than the real one, so the side panel overflows.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      onError!(details);
    };
    addTearDown(() => FlutterError.onError = onError);

    await tester.pumpWidget(const MaterialApp(home: TemplateMakerScreen()));
    await tester.pumpAndSettle();

    // The default category is a box, which has no drawing layer.
    await tester.tap(find.byType(DropdownButtonFormField<TemplateCategory>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('controller').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Drawing'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.horizontal_rule));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    final center = tester.getCenter(canvas);

    // Draw a line by dragging.
    final g = await tester.startGesture(center - const Offset(60, 0), kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(5, 0));
    await g.moveBy(const Offset(115, 0));
    await g.up();
    await tester.pumpAndSettle();
    expect(painter().notes, hasLength(1));

    // Put keyboard focus in a text field, as after editing a value.
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    // Click the line on the canvas to select it, then press Delete.
    await tester.tap(find.byIcon(Icons.horizontal_rule)); // disarm the draw tool
    await tester.pumpAndSettle();
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().selectedNoteId, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(painter().notes, isEmpty);
  });
}
