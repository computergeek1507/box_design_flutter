import 'dart:math' as math;

import '../models/vec2.dart';
import 'triangulate.dart';

class Vec3 {
  final double x;
  final double y;
  final double z;

  const Vec3(this.x, this.y, this.z);

  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// A triangle mesh: [triangles] are index triples into [vertices], each
/// wound counter-clockwise when viewed from the direction its face should
/// be visible from (i.e. from outside a solid).
class Mesh {
  final List<Vec3> vertices;
  final List<List<int>> triangles;

  const Mesh(this.vertices, this.triangles);
}

bool pointInPolygon(Vec2 p, List<Vec2> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i];
    final b = poly[j];
    if ((a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// Drops every hole that sits entirely inside a strictly larger one (e.g. a
/// box template's own small baked-in mounting hole landing inside a big
/// user-drawn slot) -- cutting it would be redundant, since the larger hole
/// already removes that material, and [mergeHolesIntoOuter] assumes holes
/// don't overlap: bridging a nested hole to the boundary of the hole that
/// contains it produces a self-intersecting polygon, corrupting the mesh.
/// Comparing against strictly larger area (not just "contains") means two
/// holes can never drop each other, even if identical.
List<List<Vec2>> _dropNestedHoles(List<List<Vec2>> holesCcw) {
  final areas = [for (final h in holesCcw) signedArea(h).abs()];
  final kept = <List<Vec2>>[];
  for (var i = 0; i < holesCcw.length; i++) {
    final hole = holesCcw[i];
    final containedInLarger = Iterable<int>.generate(holesCcw.length).any(
      (j) => j != i && areas[j] > areas[i] && hole.every((p) => pointInPolygon(p, holesCcw[j])),
    );
    if (!containedInLarger) kept.add(hole);
  }
  return kept;
}

/// Extrudes a flat [outer] boundary (with [holes] cut all the way through)
/// into a solid plate of [thickness] mm, for 3D printing. Coordinates are
/// mm; the result sits between z=0 and z=thickness.
Mesh extrudePlate({
  required List<Vec2> outer,
  required List<List<Vec2>> holes,
  required double thickness,
}) {
  var outerCcw = List<Vec2>.from(outer);
  if (signedArea(outerCcw) < 0) outerCcw = outerCcw.reversed.toList();

  // A hole that isn't entirely inside the outline (e.g. a mounting hole
  // dragged off the plate, or past a chamfered corner) has no material to
  // cut: bridging it into the outer boundary would produce a
  // self-intersecting polygon and a corrupt mesh, so it's skipped.
  final holesCcw = _dropNestedHoles([
    for (final h in holes)
      if (h.length >= 3 && h.every((p) => pointInPolygon(p, outerCcw)))
        (signedArea(h) < 0 ? h.reversed.toList() : List<Vec2>.from(h)),
  ]);

  final mergeResult = mergeHolesIntoOuter(outerCcw, holesCcw);
  final merged = mergeResult.polygon;
  final faceTriangles = earClipTriangulate(merged);

  final vertices = <Vec3>[];
  // Every (x, y) that appears more than once (e.g. an outer vertex used both
  // by the top/bottom faces and by a wall, or duplicated across a bridge
  // seam) resolves to the same vertex index, so shared physical edges are
  // shared in the index buffer too — required for a manifold/watertight mesh.
  final topIndex = <Vec2, int>{};
  final bottomIndex = <Vec2, int>{};

  int topIdxFor(Vec2 p) => topIndex.putIfAbsent(p, () {
        vertices.add(Vec3(p.x, p.y, thickness));
        return vertices.length - 1;
      });
  int bottomIdxFor(Vec2 p) => bottomIndex.putIfAbsent(p, () {
        vertices.add(Vec3(p.x, p.y, 0));
        return vertices.length - 1;
      });

  final triangles = <List<int>>[];
  for (final t in faceTriangles) {
    final a = merged[t[0]];
    final b = merged[t[1]];
    final c = merged[t[2]];
    triangles.add([topIdxFor(a), topIdxFor(b), topIdxFor(c)]);
    triangles.add([bottomIdxFor(a), bottomIdxFor(c), bottomIdxFor(b)]);
  }

  void addWalls(List<Vec2> boundaryForOutwardNormal) {
    final n = boundaryForOutwardNormal.length;
    for (var i = 0; i < n; i++) {
      final a = boundaryForOutwardNormal[i];
      final b = boundaryForOutwardNormal[(i + 1) % n];
      if (a == b) continue;
      final aTop = topIdxFor(a);
      final bTop = topIdxFor(b);
      final aBot = bottomIdxFor(a);
      final bBot = bottomIdxFor(b);
      triangles.add([aBot, bBot, bTop]);
      triangles.add([aBot, bTop, aTop]);
    }
  }

  // Walked from mergeResult (not the raw outerCcw/holesCcw) so a wall
  // segment always matches a real top/bottom-face boundary edge — a Steiner
  // point [mergeHolesIntoOuter] inserts to split an edge for one bridge
  // must split the corresponding wall too, or the two surfaces disagree
  // about where the boundary actually runs and the mesh isn't watertight.
  addWalls(mergeResult.outerBoundary);
  for (final h in mergeResult.holeBoundaries) {
    addWalls(h.reversed.toList());
  }

  return Mesh(vertices, triangles);
}

/// Builds a self-contained, independently watertight annular tube (a
/// standoff/boss): a hollow cylinder from [baseZ] to [topZ] with an
/// [innerRadius] through-hole and [outerRadius] outer wall, capped top and
/// bottom. Meant to be appended alongside a plate's own mesh (see
/// [combineMeshes]) rather than CSG-unioned with it: it deliberately
/// overlaps the plate's existing solid material below [topZ] down to
/// wherever the plate itself ends (a standard, widely-supported
/// "overlapping bodies" technique — slicers union overlapping solids
/// automatically when slicing), so it never needs to know anything about
/// the plate's own triangulation.
Mesh buildAnnularTube({
  required Vec2 center,
  required double innerRadius,
  required double outerRadius,
  required double baseZ,
  required double topZ,
  int segments = 32,
}) {
  final vertices = <Vec3>[];
  final triangles = <List<int>>[];

  List<Vec2> ring(double radius) => [
        for (var i = 0; i < segments; i++)
          Vec2(
            center.x + radius * math.cos(2 * math.pi * i / segments),
            center.y + radius * math.sin(2 * math.pi * i / segments),
          ),
      ];

  int addVertex(Vec2 p, double z) {
    vertices.add(Vec3(p.x, p.y, z));
    return vertices.length - 1;
  }

  final innerRing = ring(innerRadius);
  final outerRing = ring(outerRadius);
  final innerBot = [for (final p in innerRing) addVertex(p, baseZ)];
  final innerTop = [for (final p in innerRing) addVertex(p, topZ)];
  final outerBot = [for (final p in outerRing) addVertex(p, baseZ)];
  final outerTop = [for (final p in outerRing) addVertex(p, topZ)];

  // A ring of points at increasing angle is CCW when viewed from +z looking
  // down (matching signedArea's convention elsewhere in this file), so
  // walking it forward (i -> i+1) and using the same wall-triangle winding
  // as extrudePlate's outer boundary gives an outward-pointing normal;
  // walking it backward (i+1 -> i, as for a hole boundary there) gives a
  // normal pointing back toward the axis -- exactly what the inner (hole)
  // wall needs.
  void wall(List<int> bot, List<int> top, {required bool forward}) {
    final n = bot.length;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final a = forward ? i : j;
      final b = forward ? j : i;
      triangles.add([bot[a], bot[b], top[b]]);
      triangles.add([bot[a], top[b], top[a]]);
    }
  }

  wall(outerBot, outerTop, forward: true);
  wall(innerBot, innerTop, forward: false);

  // Top annulus cap: CCW (in x/y) triangles face +z, matching extrudePlate's
  // own top-face convention.
  for (var i = 0; i < segments; i++) {
    final j = (i + 1) % segments;
    triangles.add([innerTop[i], outerTop[i], outerTop[j]]);
    triangles.add([innerTop[i], outerTop[j], innerTop[j]]);
  }
  // Bottom annulus cap: reversed winding to face -z.
  for (var i = 0; i < segments; i++) {
    final j = (i + 1) % segments;
    triangles.add([innerBot[i], outerBot[j], outerBot[i]]);
    triangles.add([innerBot[i], innerBot[j], outerBot[j]]);
  }

  return Mesh(vertices, triangles);
}

/// Concatenates several independent meshes into one, offsetting each one's
/// triangle indices to point into the combined vertex list. Does not weld
/// or deduplicate shared/overlapping geometry between the inputs -- see
/// [buildAnnularTube].
Mesh combineMeshes(List<Mesh> meshes) {
  final vertices = <Vec3>[];
  final triangles = <List<int>>[];
  for (final m in meshes) {
    final offset = vertices.length;
    vertices.addAll(m.vertices);
    for (final t in m.triangles) {
      triangles.add([t[0] + offset, t[1] + offset, t[2] + offset]);
    }
  }
  return Mesh(vertices, triangles);
}
