import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';

bool _has(List<Vec2> pts, Vec2 p) => pts.any((q) => (q.x - p.x).abs() < 1e-6 && (q.y - p.y).abs() < 1e-6);

void main() {
  TemplateMakerController strip() {
    final c = TemplateMakerController()
      ..setOutlineWidth(100)
      ..setOutlineHeight(20)
      ..setUseCustomOutline(true); // (0,0) (100,0) (100,20) (0,20)
    return c;
  }

  test('a fillet next to a sharp corner can use the whole edge', () {
    final c = strip()
      ..setOutlinePointStyle(2, OutlineCornerStyle.fillet)
      ..setOutlinePointSize(2, 20);
    final pts = c.customOutlineDisplayPoints();
    // Tangent points: all the way down the 20mm right edge, and 20mm along the top.
    expect(_has(pts, const Vec2(100, 0)), isTrue);
    expect(_has(pts, const Vec2(80, 20)), isTrue, reason: '$pts');
    // The fillet's end and the sharp corner are merged, not duplicated.
    // (The flattened points repeat the first one at the end to close the loop.)
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i], b = pts[i + 1];
      expect((a.x - b.x).abs() + (a.y - b.y).abs() > 1e-9, isTrue, reason: 'duplicate point at $a');
    }
  });

  test('two fillets sharing an edge split it instead of overlapping', () {
    final c = strip()
      ..setOutlinePointStyle(1, OutlineCornerStyle.fillet)
      ..setOutlinePointSize(1, 20)
      ..setOutlinePointStyle(2, OutlineCornerStyle.fillet)
      ..setOutlinePointSize(2, 20);
    final pts = c.customOutlineDisplayPoints();
    expect(_has(pts, const Vec2(100, 10)), isTrue, reason: '$pts');
    expect(_has(pts, const Vec2(90, 0)), isTrue);
    expect(_has(pts, const Vec2(90, 20)), isTrue);
  });
}
