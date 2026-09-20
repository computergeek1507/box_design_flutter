import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/design/design_controller.dart';
import 'package:box_design_flutter/geometry/placed_entities.dart';
import 'package:box_design_flutter/geometry/tessellate.dart';
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
    library.importJson(_rectTemplate('board', 'controller', 30, 20));
    return DesignController(library)..applyBoxTemplate('box');
  }

  const preset = HolePreset(id: 'r', name: 'r', type: HoleType.rectangle, slotLength: 24, slotWidth: 12);

  test('holes and templates dropped, dragged or rotated outside the box are pushed back inside', () {
    final c = make();

    c.addHoleFromPreset(preset, const Vec2(-50, 200));
    var b = c.project.holes.single.boundingBox;
    expect((b.minX, b.maxY), (0.0, 80.0));

    c.addPlacedTemplate('board', const Vec2(500, 500));
    final placed = c.project.placedTemplates.single;
    b = entitiesBoundingBox(placedTemplateEntities(c.library.byId('board')!, placed));
    expect((b.maxX, b.maxY), (100.0, 80.0));

    c.movePlacedTemplate(placed.id, const Vec2(-300, -300));
    b = entitiesBoundingBox(placedTemplateEntities(c.library.byId('board')!, c.project.placedTemplates.single));
    expect((b.minX, b.minY), (0.0, 0.0));

    c.updateHole(c.project.holes.single.id, (h) => h.copyWith(position: const Vec2(1000, -1000)));
    b = c.project.holes.single.boundingBox;
    expect((b.maxX, b.minY), (100.0, 0.0));
  });

  test('a loaded project with an item outside the box gets it moved back in', () {
    final c = make();
    final broken = c.project.copyWith(holes: [
      Hole(id: 'h', type: HoleType.rectangle, position: const Vec2(-16.7, 193.9), slotLength: 24, slotWidth: 12),
    ]);
    c.loadProject(broken);
    final b = c.project.holes.single.boundingBox;
    expect(b.minX >= 0 && b.maxX <= 100 && b.minY >= 0 && b.maxY <= 80, isTrue);
  });
}
