import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/models/controller_template.dart';
import 'package:box_design_flutter/models/dxf_entity.dart';
import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_controller.dart';

void main() {
  test('cornerRadius 0 produces a plain 4-vertex rectangle outline', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(4));
    expect(outline.vertices.every((v) => v.bulge == 0), isTrue);
    expect(outline.boundingBox.width, closeTo(80, 1e-9));
    expect(outline.boundingBox.height, closeTo(50, 1e-9));
  });

  test('a positive cornerSize with fillet style produces an 8-vertex filleted outline with the right bounding box', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.fillet)
      ..setCornerSize(6);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(8));
    expect(outline.vertices.where((v) => v.bulge != 0), hasLength(4));
    // The bounding box still matches the outer envelope, since toPoints()
    // flattens the corner arcs out to the full radius.
    expect(outline.boundingBox.width, closeTo(80, 0.05));
    expect(outline.boundingBox.height, closeTo(50, 0.05));
  });

  test('a positive cornerSize with chamfer style produces an 8-vertex chamfered outline with no bulge', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.chamfer)
      ..setCornerSize(6);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(8));
    expect(outline.vertices.every((v) => v.bulge == 0), isTrue);
    expect(outline.boundingBox.width, closeTo(80, 1e-9));
    expect(outline.boundingBox.height, closeTo(50, 1e-9));
  });

  test('cornerSize is clamped so it can never exceed half the smaller side', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.fillet)
      ..setCornerSize(1000);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    // Half of the smaller side (50) is 25 -- the first vertex sits at (r, 0).
    expect(outline.vertices.first.point.x, closeTo(25, 1e-9));
  });

  test('loadFromTemplate round-trips a filleted outline back to its corner style and size', () {
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.fillet)
      ..setCornerSize(6);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.outlineWidth, closeTo(80, 1e-9));
    expect(loaded.outlineHeight, closeTo(50, 1e-9));
    expect(loaded.cornerStyle, TemplateMakerCornerStyle.fillet);
    expect(loaded.cornerSize, closeTo(6, 1e-9));
  });

  test('loadFromTemplate round-trips a chamfered outline back to its corner style and size', () {
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.chamfer)
      ..setCornerSize(6);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.outlineWidth, closeTo(80, 1e-9));
    expect(loaded.outlineHeight, closeTo(50, 1e-9));
    expect(loaded.cornerStyle, TemplateMakerCornerStyle.chamfer);
    expect(loaded.cornerSize, closeTo(6, 1e-9));
  });

  test('loadFromTemplate reads back cornerSize 0 for a plain rectangle', () {
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.cornerSize, 0);
  });

  test('addQuickHolePattern places 4 round holes centered on the outline', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(100)
      ..setOutlineHeight(60)
      ..addQuickHolePattern(horizontalSpacing: 80, verticalSpacing: 40, diameter: 3.2);

    expect(controller.holes, hasLength(4));
    final positions = controller.holes.map((h) => (h.x, h.y)).toSet();
    expect(
      positions,
      {
        (10.0, 10.0),
        (10.0, 50.0),
        (90.0, 10.0),
        (90.0, 50.0),
      },
    );
    expect(controller.holes.every((h) => h.diameter == 3.2), isTrue);
    expect(controller.holes.every((h) => h.shape == TemplateMakerHoleShape.round), isTrue);
  });

  test('addQuickHolePattern with an outlineOffset resizes the outline to spacing + margin on each side', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(999) // any prior size -- should be fully overridden
      ..setOutlineHeight(999)
      ..addQuickHolePattern(horizontalSpacing: 80, verticalSpacing: 40, outlineOffset: 5);

    expect(controller.outlineWidth, closeTo(90, 1e-9)); // 80 + 5*2
    expect(controller.outlineHeight, closeTo(50, 1e-9)); // 40 + 5*2
    final positions = controller.holes.map((h) => (h.x, h.y)).toSet();
    expect(
      positions,
      {
        (5.0, 5.0),
        (5.0, 45.0),
        (85.0, 5.0),
        (85.0, 45.0),
      },
    );
  });

  test('addQuickHolePattern with no outlineOffset leaves the outline size untouched', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(200)
      ..setOutlineHeight(150)
      ..addQuickHolePattern(horizontalSpacing: 80, verticalSpacing: 40);

    expect(controller.outlineWidth, closeTo(200, 1e-9));
    expect(controller.outlineHeight, closeTo(150, 1e-9));
  });

  test('addQuickHolePattern can place square or slot holes', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(100)
      ..setOutlineHeight(60)
      ..addQuickHolePattern(
        horizontalSpacing: 80,
        verticalSpacing: 40,
        shape: TemplateMakerHoleShape.rect,
        slotLength: 6,
        slotWidth: 6,
      );

    expect(controller.holes, hasLength(4));
    for (final h in controller.holes) {
      expect(h.shape, TemplateMakerHoleShape.rect);
      expect(h.slotLength, 6);
      expect(h.slotWidth, 6);
    }
  });

  test('toTemplate carries category and holes through unchanged', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCategory(TemplateCategory.receiver)
      ..addHole();

    final template = controller.toTemplate();
    expect(template.category, TemplateCategory.receiver);
    expect(template.entities.whereType<DxfCircle>(), hasLength(1));
  });

  test('a positive cornerSize with cornerCut style produces a 12-vertex notched outline with the right bounding box', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.cornerCut)
      ..setCornerSize(8);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(12));
    expect(outline.vertices.every((v) => v.bulge == 0), isTrue);
    expect(outline.boundingBox.width, closeTo(80, 1e-9));
    expect(outline.boundingBox.height, closeTo(50, 1e-9));
  });

  test('cornerSize is clamped so it can never exceed half the smaller side (cornerCut style)', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.cornerCut)
      ..setCornerSize(1000);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices.first.point.x, closeTo(25, 1e-9));
  });

  test('changing cornerStyle swaps the outline shape produced for the same cornerSize', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.fillet)
      ..setCornerSize(6);
    expect(controller.cornerStyle, TemplateMakerCornerStyle.fillet);
    expect((controller.toTemplate().entities.first as DxfPolyline).vertices.any((v) => v.bulge != 0), isTrue);

    controller.setCornerStyle(TemplateMakerCornerStyle.cornerCut);
    expect(controller.cornerSize, 6);
    expect((controller.toTemplate().entities.first as DxfPolyline).vertices, hasLength(12));
  });

  test('loadFromTemplate round-trips a notched outline back to its cut size', () {
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setCornerStyle(TemplateMakerCornerStyle.cornerCut)
      ..setCornerSize(8);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.outlineWidth, closeTo(80, 1e-9));
    expect(loaded.outlineHeight, closeTo(50, 1e-9));
    expect(loaded.cornerStyle, TemplateMakerCornerStyle.cornerCut);
    expect(loaded.cornerSize, closeTo(8, 1e-9));
  });

  test('addSlot produces a closed stadium polyline with the right bounding box', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..addSlot();
    final hole = controller.holes.single;
    controller.updateHole(hole.id, x: 40, y: 25, slotLength: 20, slotWidth: 6);

    final template = controller.toTemplate();
    final slotEntity = template.entities.whereType<DxfPolyline>().last;
    expect(slotEntity.closed, isTrue);
    expect(slotEntity.boundingBox.width, closeTo(20, 0.05));
    expect(slotEntity.boundingBox.height, closeTo(6, 0.05));
    expect(slotEntity.boundingBox.center.x, closeTo(40, 0.05));
    expect(slotEntity.boundingBox.center.y, closeTo(25, 0.05));
  });

  test('a rotated slot swaps its bounding box dimensions', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..addSlot();
    final hole = controller.holes.single;
    controller.updateHole(hole.id, x: 40, y: 25, slotLength: 20, slotWidth: 6, rotationDeg: 90);

    final slotEntity = controller.toTemplate().entities.whereType<DxfPolyline>().last;
    expect(slotEntity.boundingBox.width, closeTo(6, 0.05));
    expect(slotEntity.boundingBox.height, closeTo(20, 0.05));
  });

  test('loadFromTemplate reads the outline size from separate line segments, not a single circle', () {
    // Mirrors what the KiCad plugin exports for an Edge.Cuts rectangle drawn
    // as four independent line segments (each with a degenerate, zero-area
    // bounding box) plus round mounting holes -- the outline used to be
    // picked as whichever single entity had the largest bounding-box area,
    // which was one of the holes here since every line's own area is 0.
    final template = ControllerTemplate(
      id: 'pb_16',
      name: 'PB_16',
      source: TemplateSource.imported,
      category: TemplateCategory.controller,
      entities: [
        DxfLine(const Vec2(148.6, 0), const Vec2(148.6, 76.4)),
        DxfLine(const Vec2(0, 76.4), const Vec2(0, 0)),
        DxfLine(const Vec2(148.6, 76.4), const Vec2(0, 76.4)),
        DxfLine(const Vec2(148.6, 0), const Vec2(0, 0)),
        DxfCircle(const Vec2(10.912, 71.5512), 1.85),
        DxfCircle(const Vec2(137.912, 71.5512), 1.85),
        DxfCircle(const Vec2(137.9266, 20.7512), 1.85),
        DxfCircle(const Vec2(10.9266, 20.7512), 1.85),
      ],
    );

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.outlineWidth, closeTo(148.6, 1e-6));
    expect(loaded.outlineHeight, closeTo(76.4, 1e-6));
    expect(loaded.cornerSize, 0);
    expect(loaded.holes, hasLength(4));
    for (final hole in loaded.holes) {
      expect(hole.diameter, closeTo(3.7, 1e-6));
    }
  });

  test('loadFromTemplate round-trips a slot hole back to its length/width/rotation', () {
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..addSlot();
    final hole = original.holes.single;
    original.updateHole(hole.id, x: 30, y: 15, slotLength: 18, slotWidth: 5, rotationDeg: 35);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.holes, hasLength(1));
    final loadedHole = loaded.holes.single;
    expect(loadedHole.shape, TemplateMakerHoleShape.slot);
    expect(loadedHole.x, closeTo(30, 1e-6));
    expect(loadedHole.y, closeTo(15, 1e-6));
    expect(loadedHole.slotLength, closeTo(18, 1e-6));
    expect(loadedHole.slotWidth, closeTo(5, 1e-6));
    expect(loadedHole.rotationDeg, closeTo(35, 1e-6));
  });

  test('setUseCustomOutline seeds the current rectangle corners the first time it is turned on', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);

    expect(controller.customOutlinePoints.map((v) => v.position), [
      const Vec2(0, 0),
      const Vec2(80, 0),
      const Vec2(80, 50),
      const Vec2(0, 50),
    ]);
  });

  test('a custom outline with 3+ points replaces the parametric rectangle in toTemplate', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);
    controller.addOutlinePointAt(const Vec2(40, 60));

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(5));
    expect(outline.vertices.every((v) => v.bulge == 0), isTrue);
    expect(outline.vertices.last.point, const Vec2(40, 60));
  });

  test('a custom outline with fewer than 3 points falls back to the parametric rectangle', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50);
    controller.useCustomOutline = true;
    controller.customOutlinePoints = [OutlineVertex(const Vec2(0, 0)), OutlineVertex(const Vec2(80, 0))];

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(4));
  });

  test('moveOutlinePoint and removeOutlinePoint edit the custom outline in place', () {
    final controller = TemplateMakerController()..setUseCustomOutline(true);
    controller.moveOutlinePoint(0, const Vec2(-5, -5));
    expect(controller.customOutlinePoints[0].position, const Vec2(-5, -5));

    controller.removeOutlinePoint(1);
    expect(controller.customOutlinePoints, hasLength(3));
    expect(controller.selectedOutlinePointIndex, isNull);
  });

  test('loadFromTemplate round-trips a hand-drawn straight-edge custom outline', () {
    final points = [
      const Vec2(0, 0),
      const Vec2(80, 0),
      const Vec2(80, 30),
      const Vec2(60, 30),
      const Vec2(60, 50),
      const Vec2(0, 50),
    ];
    final template = ControllerTemplate(
      id: 'notched',
      name: 'Notched',
      entities: [DxfPolyline([for (final p in points) PolyVertex(p)], closed: true)],
      source: TemplateSource.imported,
      category: TemplateCategory.controllerAddon,
    );

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints.map((v) => v.position), points);
    expect(loaded.customOutlinePoints.every((v) => v.style == OutlineCornerStyle.sharp), isTrue);
  });

  test('dual-layer plates keep independent custom outlines across a layer swap', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setDualLayer(true)
      ..setUseCustomOutline(true);
    controller.addOutlinePointAt(const Vec2(40, 60));
    final layer1Points = List.of(controller.customOutlinePoints);

    controller.selectLayer(TemplateMakerLayer.layer2);
    expect(controller.useCustomOutline, isFalse); // layer 2 starts as its own plain rectangle

    controller.selectLayer(TemplateMakerLayer.layer1);
    expect(controller.useCustomOutline, isTrue);
    expect(controller.customOutlinePoints, layer1Points);
  });

  test('a fillet on a 90-degree custom-outline corner matches the rectangle corner-style math', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);
    // Point 1 is (80, 0) -- a 90-degree corner, same angle as the
    // parametric rectangle's own corners.
    controller.setOutlinePointStyle(1, OutlineCornerStyle.fillet);
    controller.setOutlinePointSize(1, 10);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(5));
    final filletVertex = outline.vertices.firstWhere((v) => v.bulge != 0);
    expect(filletVertex.point.x, closeTo(70, 1e-9));
    expect(filletVertex.point.y, closeTo(0, 1e-9));
    expect(filletVertex.bulge, closeTo(0.4142135623730951, 1e-9)); // tan(22.5deg)
    final nextVertex = outline.vertices[outline.vertices.indexOf(filletVertex) + 1];
    expect(nextVertex.point.x, closeTo(80, 1e-9));
    expect(nextVertex.point.y, closeTo(10, 1e-9));
  });

  test('a chamfer on a custom-outline corner cuts a straight segment with no bulge', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);
    controller.setOutlinePointStyle(1, OutlineCornerStyle.chamfer);
    controller.setOutlinePointSize(1, 10);

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(5));
    expect(outline.vertices.every((v) => v.bulge == 0), isTrue);
    final points = outline.vertices.map((v) => v.point).toList();
    expect(points, contains(const Vec2(70, 0)));
    expect(points, contains(const Vec2(80, 10)));
  });

  test('a sharp outline point ignores any size', () {
    final controller = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);
    controller.setOutlinePointSize(1, 10); // style stays sharp (the default)

    final outline = controller.toTemplate().entities.first as DxfPolyline;
    expect(outline.vertices, hasLength(4));
    expect(outline.vertices.every((v) => v.bulge == 0), isTrue);
  });

  test('insertOutlinePointAfter puts the new point in path order, not at the end', () {
    final controller = TemplateMakerController()..setUseCustomOutline(true);
    final points = controller.customOutlinePoints;
    final between = Vec2(
      (points[0].position.x + points[1].position.x) / 2,
      (points[0].position.y + points[1].position.y) / 2,
    );

    final index = controller.insertOutlinePointAfter(0, between);

    expect(index, 1);
    expect(controller.customOutlinePoints[1].position, between);
    expect(controller.customOutlinePoints, hasLength(5));
  });

  test('addOutlinePointAt nudges a point that would land exactly on an existing one', () {
    final controller = TemplateMakerController()..setUseCustomOutline(true);
    final existing = controller.customOutlinePoints[0].position;

    controller.addOutlinePointAt(existing);

    final added = controller.customOutlinePoints.last.position;
    expect((added.x - existing.x).abs() + (added.y - existing.y).abs(), greaterThan(0));
  });

  test('toTemplate/loadFromTemplate round-trips an unmodified 4-point custom outline', () {
    // A plain, unmodified custom outline is geometrically identical to a
    // sharp-cornered rectangle -- the round-trip metadata is what tells
    // loadFromTemplate this was actually a custom outline, not a plain one.
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints.map((v) => v.position), [
      const Vec2(0, 0),
      const Vec2(80, 0),
      const Vec2(80, 50),
      const Vec2(0, 50),
    ]);
  });

  test('toTemplate/loadFromTemplate round-trips a filleted custom-outline point exactly', () {
    final original = TemplateMakerController()
      ..setOutlineWidth(80)
      ..setOutlineHeight(50)
      ..setUseCustomOutline(true);
    original.setOutlinePointStyle(1, OutlineCornerStyle.fillet);
    original.setOutlinePointSize(1, 10);
    final template = original.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints, hasLength(4));
    expect(loaded.customOutlinePoints[1].position, const Vec2(80, 0));
    expect(loaded.customOutlinePoints[1].style, OutlineCornerStyle.fillet);
    expect(loaded.customOutlinePoints[1].size, 10);
    // And it still produces the identical treated geometry after reloading.
    final reExported = loaded.toTemplate().entities.first as DxfPolyline;
    final originalExported = template.entities.first as DxfPolyline;
    expect(reExported.vertices.length, originalExported.vertices.length);
  });

  test('a template without round-trip metadata still loads via the geometric fallback', () {
    // Templates saved before this metadata existed (or hand-authored/DXF
    // imports) have no templateMakerCustomOutline field at all.
    final points = [
      const Vec2(0, 0),
      const Vec2(80, 0),
      const Vec2(80, 30),
      const Vec2(60, 30),
      const Vec2(60, 50),
      const Vec2(0, 50),
    ];
    final template = ControllerTemplate(
      id: 'notched',
      name: 'Notched',
      entities: [DxfPolyline([for (final p in points) PolyVertex(p)], closed: true)],
      source: TemplateSource.imported,
      category: TemplateCategory.controllerAddon,
    );

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints.map((v) => v.position), points);
  });

  void expectAssetOpensAsCustomOutline(String assetPath, int expectedCorners) {
    final json = jsonDecode(File(assetPath).readAsStringSync()) as Map<String, dynamic>;
    final template = ControllerTemplate.fromJson(json, source: TemplateSource.builtIn);
    final originalOutline = template.entities.first as DxfPolyline;

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints, hasLength(expectedCorners));
    expect(loaded.customOutlinePoints.every((v) => v.style == OutlineCornerStyle.fillet), isTrue);

    // Re-exporting the reconstructed corners must reproduce the bundled
    // asset's actual outline geometry: same vertices, same bulges. The
    // reconstructed polygon may start at a different (but equivalent)
    // vertex, so compare as a set rather than by index; bulge is rounded
    // since the asset stores a truncated literal (0.41421356) while the
    // reconstruction recomputes the exact value (tan(22.5deg)).
    final reExported = loaded.toTemplate().entities.first as DxfPolyline;
    String key(PolyVertex v) =>
        '${v.point.x.toStringAsFixed(3)},${v.point.y.toStringAsFixed(3)},${v.bulge.toStringAsFixed(4)}';
    expect(reExported.vertices.map(key).toSet(), originalOutline.vertices.map(key).toSet());
  }

  test('yps_large_box.json opens as its 8-corner custom outline and reproduces the same shape', () {
    expectAssetOpensAsCustomOutline('assets/templates/yps_large_box.json', 8);
  });

  test('yps_medium_box.json opens as its 8-corner custom outline and reproduces the same shape', () {
    expectAssetOpensAsCustomOutline('assets/templates/yps_medium_box.json', 8);
  });

  test(
      'a DXF/JSON import with mixed fillet radii and no round-trip metadata still reconstructs as a '
      'custom outline via the general geometric fallback', () {
    // Same outline as yps_large_box.json's entities, but as a template that
    // has never been through the Template Maker (no
    // templateMakerCustomOutline metadata) -- e.g. a fresh DXF import.
    final json = jsonDecode(File('assets/templates/yps_large_box.json').readAsStringSync()) as Map<String, dynamic>
      ..remove('templateMakerCustomOutline');
    final template = ControllerTemplate.fromJson(json, source: TemplateSource.imported);

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints, hasLength(8));
    expect(loaded.customOutlinePoints.map((v) => v.size.toStringAsFixed(3)).toSet(), {'6.500', '10.000', '2.000'});
  });

  test('the general fillet fallback handles a non-90-degree corner correctly', () {
    // A right triangle (0,0)-(20,0)-(0,20) with its right-angle corner at
    // the origin filleted (radius 3) and its 45-degree corner at (0,20)
    // sharp -- exercises an angle the uniform-rectangle patterns never hit.
    final controller = TemplateMakerController()
      ..customOutlinePoints = [
        OutlineVertex(const Vec2(0, 0), style: OutlineCornerStyle.fillet, size: 3),
        OutlineVertex(const Vec2(20, 0)),
        OutlineVertex(const Vec2(0, 20)),
      ]
      ..useCustomOutline = true;
    final template = controller.toTemplate();

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isTrue);
    expect(loaded.customOutlinePoints, hasLength(3));
    final filleted = loaded.customOutlinePoints.firstWhere((v) => v.style == OutlineCornerStyle.fillet);
    expect(filleted.position.x, closeTo(0, 1e-6));
    expect(filleted.position.y, closeTo(0, 1e-6));
    expect(filleted.size, closeTo(3, 1e-6));
  });

  test('the general fillet fallback bails out (falls back to a plain rectangle) on two adjacent bulges', () {
    final entities = [
      DxfPolyline([
        const PolyVertex(Vec2(0, 0), bulge: 0.4142135623730951),
        const PolyVertex(Vec2(10, 0), bulge: 0.4142135623730951), // back-to-back arcs -- not decomposable
        const PolyVertex(Vec2(10, 10)),
        const PolyVertex(Vec2(0, 10)),
      ], closed: true),
    ];
    final template = ControllerTemplate(
      id: 'weird',
      name: 'Weird',
      entities: entities,
      source: TemplateSource.imported,
      category: TemplateCategory.controllerAddon,
    );

    final loaded = TemplateMakerController()..loadFromTemplate(template);
    expect(loaded.useCustomOutline, isFalse);
    expect(loaded.cornerSize, 0);
  });
}
