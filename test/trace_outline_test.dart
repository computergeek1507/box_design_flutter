import 'dart:typed_data';

import 'package:box_design_flutter/template_maker/image_detect.dart';
import 'package:flutter_test/flutter_test.dart';

/// White page with the pixels where [inside] is true drawn black.
Uint8List _image(int w, int h, bool Function(int x, int y) inside) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final v = inside(x, y) ? 0 : 255;
      px[o] = px[o + 1] = px[o + 2] = v;
      px[o + 3] = 255;
    }
  }
  return px;
}

void main() {
  test('stroked L-shaped board with a hole traces to its 6 corners', () {
    // L: (20,20)-(180,20)-(180,100)-(100,100)-(100,180)-(20,180), 2px stroke,
    // plus a stroked circle hole that must be ignored.
    bool onL(int x, int y) {
      final inL = (x >= 20 && x <= 180 && y >= 20 && y <= 100) || (x >= 20 && x <= 100 && y >= 20 && y <= 180);
      final inner = (x >= 22 && x <= 178 && y >= 22 && y <= 98) || (x >= 22 && x <= 98 && y >= 22 && y <= 178);
      final d2 = (x - 60) * (x - 60) + (y - 60) * (y - 60);
      return (inL && !inner) || (d2 <= 100 && d2 >= 64);
    }

    final poly = traceBoardOutline(_image(200, 200, onL), 200, 200)!;
    expect(poly.length, 6);
    for (final c in [(20, 20), (180, 20), (180, 100), (100, 100), (100, 180), (20, 180)]) {
      expect(poly.any((p) => (p.x - c.$1 - 0.5).abs() < 1.5 && (p.y - c.$2 - 0.5).abs() < 1.5), isTrue, reason: '$c in $poly');
    }
  });

  test('filled board with a notch', () {
    bool solid(int x, int y) => x >= 10 && x <= 150 && y >= 10 && y <= 90 && !(x >= 60 && x <= 100 && y <= 30);
    final poly = traceBoardOutline(_image(160, 100, solid), 160, 100)!;
    expect(poly.length, 8);
  });
}
