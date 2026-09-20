import '../geometry/mesh.dart';
import '../geometry/placed_entities.dart';
import '../models/box_project.dart';
import '../models/controller_template.dart';
import '../models/dxf_entity.dart';
import '../models/hole.dart';
import '../models/vec2.dart';
import 'template_library.dart';

List<Vec2> _closedLoopPoints(DxfEntity entity, {int arcSegments = 64}) {
  final pts = entity.toPoints(arcSegments: arcSegments);
  if (pts.length > 1) {
    // A closed entity (e.g. a full-circle tessellation) always ends by
    // revisiting its start point, but floating-point error in the
    // trig (cos(2*pi) landing a hair off 1.0) means it rarely lands back
    // on the *exact* same double, so an exact `==` check misses the
    // near-duplicate and leaves a zero-area sliver in the extruded mesh.
    final dx = pts.first.x - pts.last.x;
    final dy = pts.first.y - pts.last.y;
    if (dx * dx + dy * dy < 1e-12) {
      return pts.sublist(0, pts.length - 1);
    }
  }
  return pts;
}

/// The box outline's largest-area entity is the plate's outer boundary
/// (in practice a single closed polyline); every *other* entity in the box
/// outline — e.g. a manufacturer enclosure's own mounting-flange holes,
/// bundled right alongside its outline — is a hole cut through the plate,
/// same as a user-added [Hole].
({List<Vec2> outer, List<List<Vec2>> ownHoles}) _splitBoxOutline(List<DxfEntity> boxOutline) {
  if (boxOutline.isEmpty) return (outer: <Vec2>[], ownHoles: <List<Vec2>>[]);
  DxfEntity? outerEntity;
  var bestArea = 0.0;
  for (final e in boxOutline) {
    final b = e.boundingBox;
    final area = b.width * b.height;
    if (area > bestArea) {
      bestArea = area;
      outerEntity = e;
    }
  }
  final ownHoles = [
    for (final e in boxOutline)
      if (!identical(e, outerEntity)) _closedLoopPoints(e, arcSegments: 48),
  ].where((pts) => pts.length >= 3).toList();
  return (outer: _closedLoopPoints(outerEntity!), ownHoles: ownHoles);
}

List<List<Vec2>> _holeBoundaries(List<Hole> holes) {
  final result = <List<Vec2>>[];
  for (final hole in holes) {
    for (final entity in hole.toEntities()) {
      final pts = _closedLoopPoints(entity, arcSegments: 48);
      if (pts.length >= 3) result.add(pts);
    }
  }
  return result;
}

/// Every round mounting hole baked into each placed controller/power-supply
/// template's own geometry (already transformed by that instance's
/// position/rotation, and resized if it has a [PlacedTemplate.
/// holeDiameterOverride]) — these get physically mounted to the plate, so
/// their holes need to go all the way through it too.
List<List<Vec2>> _placedTemplateHoles(BoxProject project, TemplateLibrary library) {
  final result = <List<Vec2>>[];
  for (final placed in project.placedTemplates) {
    final template = library.byId(placed.templateId);
    if (template == null) continue;
    for (final entity in placedTemplateEntities(template, placed)) {
      if (entity is! DxfCircle) continue;
      final pts = _closedLoopPoints(entity, arcSegments: 48);
      if (pts.length >= 3) result.add(pts);
    }
  }
  return result;
}

/// Every round mounting hole on a placed controller, controller add-on,
/// receiver, or power-distribution template (not power-supply bricks, which
/// come with their own mounting hardware, or the box's own holes), as a
/// center + radius in absolute box-space mm — the candidates for
/// [buildPlateMesh]'s `addStandoffs` option, since those are the boards that
/// actually get screwed down onto raised standoffs.
const _standoffEligibleCategories = {
  TemplateCategory.controller,
  TemplateCategory.controllerAddon,
  TemplateCategory.receiver,
  TemplateCategory.powerDistribution,
};

List<({Vec2 center, double radius})> _controllerReceiverMountingHoles(BoxProject project, TemplateLibrary library) {
  final result = <({Vec2 center, double radius})>[];
  for (final placed in project.placedTemplates) {
    final template = library.byId(placed.templateId);
    if (template == null) continue;
    if (!_standoffEligibleCategories.contains(template.category)) continue;
    for (final entity in placedTemplateEntities(template, placed)) {
      if (entity is! DxfCircle) continue;
      result.add((center: entity.center, radius: entity.radius));
    }
  }
  return result;
}

/// Builds a solid-plate [Mesh] for [project]: the box outline extruded to
/// [thicknessMm], with every screw/zip-tie hole, every hole already baked
/// into the box template itself (e.g. a real enclosure's own mounting
/// flange holes), and every round mounting hole on a placed
/// controller/power-supply template cut all the way through.
///
/// When [addStandoffs] is set, every mounting hole on a placed controller
/// or receiver template also gets a raised annular boss ([standoffHeight]
/// mm tall, [standoffWallThickness] mm of material around the hole) so the
/// board sits proud of the plate on printed standoffs instead of flush
/// against it.
Mesh buildPlateMesh(
  BoxProject project,
  TemplateLibrary library, {
  required double thicknessMm,
  bool addStandoffs = false,
  double standoffHeight = 3,
  double standoffWallThickness = 2,
}) {
  final split = _splitBoxOutline(project.boxOutline);
  final plate = extrudePlate(
    outer: split.outer,
    holes: [
      ...split.ownHoles,
      ..._holeBoundaries(project.holes),
      ..._placedTemplateHoles(project, library),
    ],
    thickness: thicknessMm,
  );
  if (!addStandoffs) return plate;

  // No standoff for a mounting hole that isn't fully on the plate (its hole
  // is skipped by extrudePlate, so a boss there would float in mid-air).
  bool onPlate(({Vec2 center, double radius}) hole) => _closedLoopPoints(DxfCircle(hole.center, hole.radius), arcSegments: 16)
      .every((p) => pointInPolygon(p, split.outer));

  final standoffs = [
    for (final hole in _controllerReceiverMountingHoles(project, library).where(onPlate))
      buildAnnularTube(
        center: hole.center,
        innerRadius: hole.radius,
        outerRadius: hole.radius + standoffWallThickness,
        baseZ: thicknessMm,
        topZ: thicknessMm + standoffHeight,
      ),
  ];
  return combineMeshes([plate, ...standoffs]);
}
