import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:box_design_flutter/main.dart';
import 'package:box_design_flutter/services/theme_settings.dart';

void main() {
  test('theme mode defaults to system, saves and restores', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ThemeSettings();
    await first.load();
    expect(first.mode, ThemeMode.system);

    await first.setMode(ThemeMode.dark);
    final second = ThemeSettings();
    await second.load();
    expect(second.mode, ThemeMode.dark);
  });

  testWidgets('app uses the saved dark theme and the toolbar menu switches it', (tester) async {
    SharedPreferences.setMockInitialValues({'theme_mode_v1': 'dark'});
    final settings = ThemeSettings();
    await settings.load();
    await tester.pumpWidget(BoxDesignApp(themeSettings: settings));
    await tester.pumpAndSettle();

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.dark);
    expect(Theme.of(tester.element(find.text('New'))).brightness, Brightness.dark);

    await tester.tap(find.byTooltip('Theme: Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.light);
    expect(Theme.of(tester.element(find.text('New'))).brightness, Brightness.light);
  });
}
