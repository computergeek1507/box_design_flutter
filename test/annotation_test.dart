import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/design/design_controller.dart';
import 'package:box_design_flutter/geometry/placed_annotations.dart';
import 'package:box_design_flutter/models/annotation.dart';
import 'package:box_design_flutter/models/controller_template.dart';
import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/services/dxf_export.dart';
import 'package:box_design_flutter/services/pdf_export.dart';
import 'package:box_design_flutter/services/template_library.dart';

const _notes = [
  Annotation(type: AnnotationType.text, text: 'USB', x: 2, y: 3, height: 4, rotationDeg: 90),
  Annotation(type: AnnotationType.line, x: 0, y: 0, x2: 10, y2: 0),
  Annotation(type: AnnotationType.rect, x: 1, y: 1, width: 4, height: 2),
  Annotation(type: AnnotationType.circle, x: 5, y: 5, radius: 2),
];

String _box() => jsonEncode({
      'id': 'box',
      'name': 'box',
      'category': 'box',
      'entities': [
        {
          'type': 'polyline',
          'closed': true,
          'vertices': [
            {'x': 0, 'y': 0, 'bulge': 0},
            {'x': 100, 'y': 0, 'bulge': 0},
            {'x': 100, 'y': 80, 'bulge': 0},
            {'x': 0, 'y': 80, 'bulge': 0},
          ],
        },
      ],
    });

void main() {
  test('annotations round-trip through template JSON', () {
    final t = ControllerTemplate(id: 'a', name: 'A', entities: const [], source: TemplateSource.imported, category: TemplateCategory.controller, annotations: _notes);
    final back = ControllerTemplate.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>, source: TemplateSource.imported);
    expect(back.annotations.map((a) => a.type), _notes.map((a) => a.type));
    expect(back.annotations.first.text, 'USB');
    expect((back.annotations[3].x, back.annotations[3].radius), (5.0, 2.0));
    expect(ControllerTemplate(id: 'b', name: 'B', entities: const [], source: TemplateSource.imported, category: TemplateCategory.controller).toJson().containsKey('annotations'), isFalse);
  });

  test('placing a template rotates and moves its notes with it', () {
    final placed = placeAnnotations(_notes, delta: const Vec2(100, 50), rotationDeg: 90);
    expect(placed.shapes.length, 3);
    final text = placed.texts.single;
    // (2,3) rotated 90deg = (-3,2), then + (100,50).
    expect(text.anchor.x, closeTo(97, 1e-9));
    expect(text.anchor.y, closeTo(52, 1e-9));
    expect(text.rotationDeg, 180);
  });

  testWidgets('DXF gets a Notes layer with TEXT and PDF renders with notes', (tester) async {
    final library = TemplateLibrary();
    library.importJson(_box());
    final board = ControllerTemplate(id: 'board', name: 'Board', entities: const [], source: TemplateSource.imported, category: TemplateCategory.controller, annotations: _notes);
    library.importJson(jsonEncode(board.toJson()));
    final c = DesignController(library)..applyBoxTemplate('box');
    c.addPlacedTemplate('board', const Vec2(20, 20));

    final dxf = utf8.decode(exportProjectAsDxfBytes(c.project, library));
    expect(dxf, contains('Notes'));
    expect(dxf, contains('TEXT'));
    expect(dxf, contains('USB'));

    final pdf = await tester.runAsync(() => exportProjectAsPdfBytes(c.project, library));
    expect(pdf!.length, greaterThan(500));
  });
}
