import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:box_design_flutter/main.dart';

void main() {
  testWidgets('App loads templates and shows the toolbar', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const BoxDesignApp());
    await tester.pumpAndSettle();

    expect(find.text('Box Template'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('CG-1500'), findsOneWidget);

    // The palette's category tree is a scrollable list, and its Sliver
    // virtualizes items outside the viewport + cache extent — with many
    // bundled controller/receiver templates now expanded by default, no
    // single scroll position keeps every section mounted simultaneously.
    // Sweep the full scroll range and confirm each section is mounted at
    // some point along the way. maxScrollExtent is only an estimate until
    // the sliver has actually built every child, so it's re-read on each
    // step rather than captured once up front -- a stale (usually smaller)
    // upfront snapshot can end the sweep before reaching later sections.
    final palette = find.byType(ListView).first;
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: palette, matching: find.byType(Scrollable)).first,
    );
    final sectionsSeen = <String>{};
    const sections = ['Controllers', 'Receivers', 'Power Supplies', 'Generic Holes'];
    var offset = 0.0;
    while (true) {
      scrollable.position.jumpTo(offset);
      await tester.pumpAndSettle();
      for (final section in sections) {
        if (find.text(section).evaluate().isNotEmpty) sectionsSeen.add(section);
      }
      final maxExtent = scrollable.position.maxScrollExtent;
      if (offset >= maxExtent) break;
      offset = (offset + 150).clamp(0.0, maxExtent);
    }

    expect(sectionsSeen, containsAll(sections));
  });
}
