import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/design/design_controller.dart';
import 'package:box_design_flutter/models/hole.dart';
import 'package:box_design_flutter/models/hole_preset.dart';
import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/services/template_library.dart';

String _rectTemplate(String id, String category, double w, double h) => jsonEncode({
      'id': id,
      'name': id,
      'category': category,
      'entities': [
        {
          'type': 'polyline',
          'closed': true,
          'vertices': [
            {'x': 0, 'y': 0, 'bulge': 0},
            {'x': w, 'y': 0, 'bulge': 0},
            {'x': w, 'y': h, 'bulge': 0},
            {'x': 0, 'y': h, 'bulge': 0},
          ],
        },
      ],
    });

void main() {
  DesignController make() {
    final library = TemplateLibrary();
    library.importJson(_rectTemplate('box', 'box', 100, 80));
    return DesignController(library)..applyBoxTemplate('box');
  }

  const preset = HolePreset(id: 'r', name: 'r', type: HoleType.rectangle, slotLength: 24, slotWidth: 12);

  test('loading a project with existing hole ids never lets a newly added hole reuse one', () {
    final c = make();
    final loadedHole = const Hole(id: 'hole-4', type: HoleType.rectangle, position: Vec2(10, 10));
    c.loadProject(c.project.copyWith(holes: [loadedHole]));

    c.addHoleFromPreset(preset, const Vec2(50, 50));
    c.addHoleFromPreset(preset, const Vec2(60, 60));
    c.addHoleFromPreset(preset, const Vec2(70, 70));
    c.addHoleFromPreset(preset, const Vec2(80, 80));

    final ids = c.project.holes.map((h) => h.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate hole ids: $ids');
  });
}
