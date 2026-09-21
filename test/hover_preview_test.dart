import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:box_design_flutter/main.dart';

void main() {
  testWidgets('hovering a palette item pops up a preview that goes away when the pointer leaves', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoxDesignApp());
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: const Offset(1500, 900));

    // Nothing pops up until the pointer has rested on the row.
    final row = tester.getCenter(find.text('CG-1500'));
    await gesture.moveTo(row);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining(' × '), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    final popup = find.textContaining(' × ');
    expect(popup, findsOneWidget);
    expect(tester.getTopLeft(popup).dx, greaterThan(row.dx));

    await gesture.moveTo(const Offset(1500, 900));
    await tester.pump();
    expect(popup, findsNothing);

    // Pressing on a row (start of a drag) dismisses it too.
    await gesture.moveTo(row);
    await tester.pump(const Duration(milliseconds: 500));
    expect(popup, findsOneWidget);
    await gesture.down(row);
    await tester.pump();
    expect(popup, findsNothing);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });
}
