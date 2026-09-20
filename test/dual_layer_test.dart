import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/design/design_controller.dart';
import 'package:box_design_flutter/models/annotation.dart';
import 'package:box_design_flutter/models/box_project.dart';
import 'package:box_design_flutter/models/hole.dart';
import 'package:box_design_flutter/models/hole_preset.dart';
import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/services/dxf_export.dart';
import 'package:box_design_flutter/services/mesh_export.dart';
import 'package:box_design_flutter/services/template_library.dart';
import 'package:box_design_flutter/services/threemf_export.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';

String _rect(String id, double w, double h, {String category = 'box', double? layer2W, double? layer2H}) {
  List<Map<String, dynamic>> poly(double w, double h) => [
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
      ];
  return jsonEncode({
    'id': id,
    'name': id,
    'category': category,
    'entities': poly(w, h),
    if (layer2W != null) 'layer2Entities': poly(layer2W, layer2H!),
  });
}

const _round = HolePreset(id: 'r', name: 'r', type: HoleType.screw, diameter: 6);

void main() {
  DesignController make() {
    final library = TemplateLibrary()
      ..importJson(_rect('big', 100, 80))
      ..importJson(_rect('small', 60, 50))
      ..importJson(_rect('twin', 100, 80, layer2W: 70, layer2H: 40))
      ..importJson(_rect('twin2', 100, 80, layer2W: 100, layer2H: 80));
    return DesignController(library)..applyBoxTemplate('big');
  }

  test('a two-layer box template gives two plates; a one-layer template takes layer 2 away', () {
    final c = make();
    expect(c.project.dualLayer, isFalse);
    c.applyBoxTemplate('twin');
    expect(c.project.dualLayer, isTrue);
    expect(c.project.boxTemplateId, 'twin');
    expect((c.project.plateBoxes[0].width, c.project.plateBoxes[1].width, c.project.plateBoxes[1].height), (100.0, 70.0, 40.0));
    // Plate 2 (70x40) sits at the origin; plate 1 is lifted above it.
    expect((c.project.plateBoxes[1].minX, c.project.plateBoxes[1].minY), (0.0, 0.0));
    expect((c.project.plateBoxes[0].minX, c.project.plateBoxes[0].minY), (0.0, 40 + kLayerGapMm));
    expect(c.project.boxHeight, 40 + kLayerGapMm + 80);

    // A hole dropped over plate 2 stays there (and is clamped inside it).
    c.addHoleFromPreset(_round, const Vec2(30, 20));
    expect(c.project.plateIndexForPoint(c.project.holes.single.position), 1);
    c.addHoleFromPreset(_round, const Vec2(80, 20));
    expect(c.project.holes.last.boundingBox.maxX, closeTo(70, 1e-9));
    c.addHoleFromPreset(_round, const Vec2(20, 100));
    expect(c.itemsOnLayer2, 2);

    expect(c.itemsLostByApplying('small'), 2);
    expect(c.itemsLostByApplying('twin'), 0);

    // A one-layer template removes layer 2 and what was on it.
    c.applyBoxTemplate('small');
    expect((c.project.dualLayer, c.project.holes.length), (false, 1));
    expect(c.project.boxWidth, 60);
  });

  test('export: two meshes, two 3MF objects, a DXF layer per plate, and the project round-trips', () {
    final c = make();
    c.applyBoxTemplate('twin2');
    c.addHoleFromPreset(_round, const Vec2(40, 40));
    c.addHoleFromPreset(_round, const Vec2(40, 140));

    final meshes = buildPlateMeshes(c.project, c.library, thicknessMm: 5);
    expect(meshes.length, 2);
    for (final m in meshes) {
      final ys = m.vertices.map((v) => v.y);
      expect(ys.reduce((a, b) => a < b ? a : b), anyOf(0.0, 80 + kLayerGapMm));
    }
    // Same triangle count on both plates: one hole each, identical outlines.
    expect(meshes[0].triangles.length, meshes[1].triangles.length);

    final xml = meshesTo3mfModelXml(meshes);
    expect('<object '.allMatches(xml).length, 2);
    expect(xml, contains('name="Layer 2"'));

    expect(utf8.decode(exportProjectAsDxfBytes(c.project, c.library)), contains('Outline_Layer2'));

    final back = BoxProject.fromJson(jsonDecode(jsonEncode(c.project.toJson())) as Map<String, dynamic>);
    expect(back.dualLayer, isTrue);
    expect(back.plateBoxes[0].minY, 80 + kLayerGapMm);
    expect(BoxProject.fromJson(BoxProject().toJson()).dualLayer, isFalse);
  });

  test('template maker: a hole can be copied to the other layer only on a two-layer plate', () {
    final t = TemplateMakerController();
    t.addHole();
    final id = t.holes.single.id;
    expect(t.canCopyToOtherLayer, isFalse);

    t.setDualLayer(true);
    expect(t.canCopyToOtherLayer, isTrue);
    t.copyHoleToOtherLayer(id);
    expect(t.holes.length, 1);

    t.selectLayer(TemplateMakerLayer.layer2);
    // Layer 2 started as a copy of layer 1, so the copy makes it two holes.
    expect(t.holes.length, 2);
    expect(t.holes.map((h) => h.id).toSet().length, 2);
    t.copyHoleToOtherLayer(t.holes.first.id);
    t.selectLayer(TemplateMakerLayer.layer1);
    expect(t.holes.length, 2);
  });

  test('template maker: duplicating a hole or note makes an offset copy on the same layer', () {
    final t = TemplateMakerController();
    t.addHole();
    final h = t.holes.single;
    final copy = t.duplicateHole(h.id)!;
    expect(t.holes.map((e) => e.id).toList(), [h.id, copy.id]);
    expect((copy.x, copy.y), (h.x + 5, h.y + 5));
    expect((t.selectedHoleId, copy.diameter), (copy.id, h.diameter));

    final note = t.addNote(AnnotationType.line);
    final nc = t.duplicateNote(note.id)!;
    expect(t.notes.length, 2);
    expect((nc.x, nc.x2, t.selectedNoteId), (note.x + 5, note.x2 + 5, nc.id));
  });
}
