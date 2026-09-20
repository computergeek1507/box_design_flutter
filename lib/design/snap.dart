import 'dart:math' as math;

import '../geometry/placed_entities.dart';
import '../models/dxf_entity.dart';
import '../models/vec2.dart';
import 'design_controller.dart';

/// Snaps [raw] (box-space mm) to the nearest hole center, round/arc center
/// (e.g. a slot's rounded end, or a template's own baked-in mounting hole),
/// placed-template origin, or point along any box/template edge within
/// [toleranceMm] -- lets the measure tool click precisely on existing
/// geometry ("two lines or holes") instead of an approximate freehand
/// point. Returns [raw] unchanged if nothing is within tolerance.
Vec2 snapPoint(Vec2 raw, DesignController controller, {double toleranceMm = 3.0}) {
  final project = controller.project;
  Vec2? best;
  var bestDist = toleranceMm;

  void consider(Vec2 candidate) {
    final dx = candidate.x - raw.x;
    final dy = candidate.y - raw.y;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < bestDist) {
      bestDist = dist;
      best = candidate;
    }
  }

  void considerEdges(Iterable<Vec2> points) {
    Vec2? prev;
    for (final p in points) {
      if (prev != null) consider(_nearestOnSegment(prev, p, raw));
      prev = p;
    }
  }

  void considerCenters(Iterable<DxfEntity> entities) {
    for (final entity in entities) {
      for (final center in _entityCenters(entity)) {
        consider(center);
      }
    }
  }

  void considerEntities(Iterable<DxfEntity> entities) {
    for (final entity in entities) {
      considerEdges(entity.toPoints());
    }
    considerCenters(entities);
  }

  for (final hole in project.holes) {
    consider(hole.position);
    // Centers only, not the traced outline: a click anywhere inside a round
    // hole should snap to its exact center, not to whichever point on its
    // rim happens to be nearest. Still picks up e.g. a slot's two rounded
    // end centers, or a zip-tie hole's individual circle centers, that
    // [Hole.position] alone doesn't cover.
    considerCenters(hole.toEntities());
  }
  for (final placed in project.placedTemplates) {
    consider(placed.position);
    final template = controller.library.byId(placed.templateId);
    if (template == null) continue;
    considerEntities(placedTemplateEntities(template, placed));
  }
  considerEntities(project.boxOutline);

  return best ?? raw;
}

/// Generic version of [snapPoint] for callers without a [DesignController]
/// (the Template Maker): snaps [raw] to the nearest of [points], the
/// round/arc centers of [centerOnly] entities (holes: their centers, not
/// every point on their rim), or the centers and edges of [edges] entities
/// (an outline), within [toleranceMm]. Returns [raw] if nothing is close.
Vec2 snapToGeometry(
  Vec2 raw, {
  Iterable<Vec2> points = const [],
  Iterable<DxfEntity> centerOnly = const [],
  Iterable<DxfEntity> edges = const [],
  double toleranceMm = 3.0,
}) {
  Vec2? best;
  var bestScore = toleranceMm;

  // [weight] < 1 makes a candidate win over an edge point that's a bit
  // closer -- so a click near a corner lands on the corner itself.
  void consider(Vec2 candidate, [double weight = 1.0]) {
    final dx = candidate.x - raw.x;
    final dy = candidate.y - raw.y;
    final score = math.sqrt(dx * dx + dy * dy) * weight;
    if (score < bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  points.forEach(consider);
  for (final entity in centerOnly) {
    _entityCenters(entity).forEach(consider);
  }
  for (final entity in edges) {
    final pts = entity.toPoints();
    for (var i = 0; i + 1 < pts.length; i++) {
      consider(_nearestOnSegment(pts[i], pts[i + 1], raw));
    }
    if (entity is DxfPolyline && entity.closed && pts.length > 2) {
      consider(_nearestOnSegment(pts.last, pts.first, raw));
    }
    if (entity is DxfPolyline) {
      for (final v in entity.vertices) {
        consider(v.point, 0.5);
      }
    }
    _entityCenters(entity).forEach(consider);
  }
  return best ?? raw;
}

/// Circle/arc centers worth snapping to within [entity]: a whole circle's
/// center, a standalone arc's center, or -- for a polyline -- the center of
/// each bulge (arc) segment, e.g. a slot/stadium's two rounded end caps or a
/// filleted outline corner. A hole's own [Hole.position] already covers its
/// overall center (see [snapPoint]); this is what additionally lets you
/// snap to "the center of that rounded end" on a slot, or to a mounting
/// hole baked directly into a placed template's or the box outline's own
/// geometry (which otherwise only offers points traced along its edge).
Iterable<Vec2> _entityCenters(DxfEntity entity) sync* {
  switch (entity) {
    case DxfCircle e:
      yield e.center;
    case DxfArc e:
      yield e.center;
    case DxfPolyline e:
      final segmentCount = e.closed ? e.vertices.length : e.vertices.length - 1;
      for (var i = 0; i < segmentCount; i++) {
        final a = e.vertices[i];
        if (a.bulge == 0) continue;
        final b = e.vertices[(i + 1) % e.vertices.length];
        final center = _bulgeArcCenter(a.point, b.point, a.bulge);
        if (center != null) yield center;
      }
    case DxfLine():
      break;
  }
}

/// Mirrors the arc-center step of DxfPolyline's own bulge-flattening (kept
/// private to that file since it only needs the arc's *points* there) --
/// same formula, duplicated here since this is the one place that needs the
/// center itself. bulge = tan(includedAngle / 4).
Vec2? _bulgeArcCenter(Vec2 from, Vec2 to, double bulge) {
  final includedAngle = 4 * math.atan(bulge);
  final dx = to.x - from.x;
  final dy = to.y - from.y;
  final chord = math.sqrt(dx * dx + dy * dy);
  if (chord == 0 || includedAngle == 0) return null;
  final radius = chord / (2 * math.sin(includedAngle.abs() / 2));
  final perpX = -dy / chord;
  final perpY = dx / chord;
  final sign = bulge < 0 ? -1 : 1;
  final centerDist = radius * math.cos(includedAngle.abs() / 2) * sign;
  return Vec2((from.x + to.x) / 2 + perpX * centerDist, (from.y + to.y) / 2 + perpY * centerDist);
}

Vec2 _nearestOnSegment(Vec2 a, Vec2 b, Vec2 p) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final lenSq = abx * abx + aby * aby;
  if (lenSq < 1e-12) return a;
  var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq;
  t = t.clamp(0.0, 1.0);
  return Vec2(a.x + abx * t, a.y + aby * t);
}
