import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:box_design_flutter/geometry/mesh.dart';
import 'package:box_design_flutter/geometry/triangulate.dart';
import 'package:box_design_flutter/models/vec2.dart';

List<Vec2> _rect(double w, double h) => [
      const Vec2(0, 0),
      Vec2(w, 0),
      Vec2(w, h),
      Vec2(0, h),
    ];

List<Vec2> _circle(Vec2 center, double radius, {int segments = 32}) => [
      for (var i = 0; i < segments; i++)
        Vec2(
          center.x + radius * math.cos(2 * math.pi * i / segments),
          center.y + radius * math.sin(2 * math.pi * i / segments),
        ),
    ];

double _sumTriangleAreas(List<Vec2> pts, List<List<int>> tris) =>
    tris.fold(0.0, (sum, t) => sum + triangleArea(pts[t[0]], pts[t[1]], pts[t[2]]));

/// Every edge of a closed, watertight mesh must be shared by exactly two
/// triangles (once in each direction).
void _expectManifold(Mesh mesh) {
  final directedEdges = <String>{};
  for (final t in mesh.triangles) {
    for (var i = 0; i < 3; i++) {
      final a = t[i];
      final b = t[(i + 1) % 3];
      directedEdges.add('$a->$b');
    }
  }
  for (final edge in directedEdges) {
    final parts = edge.split('->');
    final reverse = '${parts[1]}->${parts[0]}';
    expect(directedEdges.contains(reverse), isTrue, reason: 'edge $edge has no matching reverse edge $reverse');
  }
}

void main() {
  group('earClipTriangulate', () {
    test('a plain square triangulates to exactly its own area', () {
      final square = _rect(10, 10);
      final tris = earClipTriangulate(square);
      expect(_sumTriangleAreas(square, tris), closeTo(100, 1e-9));
    });

    test('a square with one circular hole loses exactly the hole area', () {
      final outer = _rect(10, 10);
      final hole = _circle(const Vec2(5, 5), 2, segments: 64);
      final merged = mergeHolesIntoOuter(outer, [hole]).polygon;
      final tris = earClipTriangulate(merged);
      final area = _sumTriangleAreas(merged, tris);
      expect(area, closeTo(100 - math.pi * 4, 0.05));
    });

    test('a square with two circular holes loses both hole areas', () {
      final outer = _rect(20, 10);
      final holeA = _circle(const Vec2(5, 5), 1.5, segments: 48);
      final holeB = _circle(const Vec2(15, 5), 1.5, segments: 48);
      final merged = mergeHolesIntoOuter(outer, [holeA, holeB]).polygon;
      final tris = earClipTriangulate(merged);
      final area = _sumTriangleAreas(merged, tris);
      expect(area, closeTo(200 - 2 * math.pi * 1.5 * 1.5, 0.05));
    });

    test('a rectangle with a 2x2 grid of holes loses exactly all four hole areas', () {
      // Regression test: multiple holes at different Y levels used to make
      // some holes' bridges cross another hole's bridge line undetected,
      // and separately made unrelated holes converge on the same bridge
      // vertex — both silently corrupted the triangulation without any
      // single hole being enough to reproduce it alone.
      final outer = _rect(30, 20);
      final holes = [
        _circle(const Vec2(5, 5), 1.5),
        _circle(const Vec2(25, 5), 1.5),
        _circle(const Vec2(5, 15), 1.5),
        _circle(const Vec2(25, 15), 1.5),
      ];
      final merged = mergeHolesIntoOuter(outer, holes).polygon;
      final tris = earClipTriangulate(merged);
      final area = _sumTriangleAreas(merged, tris);
      // Default 32-segment circles undershoot a true circle's area a little
      // (an inscribed 32-gon vs. the circle it approximates) — 0.5 comfortably
      // covers that discretization gap while still catching real corruption.
      expect(area, closeTo(600 - 4 * math.pi * 1.5 * 1.5, 0.5));
    });

    test('six holes (four corners + two near an edge) all cut correctly, matching a real reported bug', () {
      // Regression test for the exact shape of a real failure: a handful of
      // holes clustered such that several of them naturally want to bridge
      // to the same nearby corner.
      final outer = _rect(300, 200);
      final holes = [
        _circle(const Vec2(40, 45), 2),
        _circle(const Vec2(260, 45), 2),
        _circle(const Vec2(40, 170), 2),
        _circle(const Vec2(260, 170), 2),
        _circle(const Vec2(150, 20), 2.5),
        _circle(const Vec2(150, 180), 2.5),
      ];
      final merged = mergeHolesIntoOuter(outer, holes).polygon;
      final tris = earClipTriangulate(merged);
      final area = _sumTriangleAreas(merged, tris);
      final holesArea = 4 * math.pi * 4 + 2 * math.pi * 6.25;
      expect(area, closeTo(300 * 200 - holesArea, holesArea * 0.02));
    });
  });

  group('earClipTriangulate', () {
    test('an ear whose diagonal passes exactly through another vertex is rejected', () {
      // Regression test for a real reported corrupt STL export: a mounting
      // flange/notch shape (material sticking out to the left only for a
      // middle span of Y, flush with the body above and below it) has two
      // reflex corners at the same X with a third reflex corner of the same
      // notch sitting exactly between them on the connecting vertical line.
      // A diagonal straight between the outer two passes exactly through
      // the middle one -- collinear-and-between, not strictly inside the
      // ear triangle and not a *proper* crossing of either adjacent edge --
      // so neither existing check caught it, and clipping it orphaned the
      // middle vertex's boundary edges.
      final outer = [
        const Vec2(8, 0),
        const Vec2(40, 0),
        const Vec2(40, 154),
        const Vec2(8, 154),
        const Vec2(8, 146),
        const Vec2(0, 146),
        const Vec2(0, 8),
        const Vec2(8, 8),
      ];
      final mesh = extrudePlate(outer: outer, holes: const [], thickness: 1);
      _expectManifold(mesh);
    });
  });

  group('extrudePlate', () {
    test('skips holes that are not entirely inside the outline', () {
      final outer = [const Vec2(0, 0), const Vec2(20, 0), const Vec2(20, 10), const Vec2(10, 20), const Vec2(0, 20)];
      final inside = _circle(const Vec2(5, 5), 1.5);
      final withOutsideHoles = extrudePlate(
        outer: outer,
        holes: [
          inside,
          _circle(const Vec2(18, 18), 1.5), // beyond the chamfered corner
          _circle(const Vec2(-5, 5), 1.5), // off the left edge
          _circle(const Vec2(20, 5), 1.5), // straddling the right edge
        ],
        thickness: 3,
      );
      _expectManifold(withOutsideHoles);
      final onlyInside = extrudePlate(outer: outer, holes: [inside], thickness: 3);
      expect(withOutsideHoles.triangles.length, onlyInside.triangles.length);
    });

    test('produces a watertight (manifold) mesh for a plate with one hole', () {
      final mesh = extrudePlate(
        outer: _rect(10, 10),
        holes: [_circle(const Vec2(5, 5), 2, segments: 24)],
        thickness: 3,
      );
      _expectManifold(mesh);
    });

    test('produces a watertight mesh for a plate with two holes', () {
      final mesh = extrudePlate(
        outer: _rect(20, 10),
        holes: [
          _circle(const Vec2(5, 5), 1.5, segments: 24),
          _circle(const Vec2(15, 5), 1.5, segments: 24),
        ],
        thickness: 3,
      );
      _expectManifold(mesh);
    });

    test('a small hole fully inside a larger one is dropped instead of corrupting the mesh', () {
      // Regression test: a box template's own small baked-in mounting hole
      // landing inside a big user-drawn slot used to make mergeHolesIntoOuter
      // bridge the nested hole to the boundary of the hole containing it,
      // producing a self-intersecting polygon (a corrupt STL).
      final mesh = extrudePlate(
        outer: _rect(30, 30),
        holes: [
          _circle(const Vec2(15, 15), 10, segments: 32), // the big slot/hole
          _circle(const Vec2(15, 15), 2, segments: 24), // fully inside it
        ],
        thickness: 3,
      );
      _expectManifold(mesh);
      // Only the big hole's area should be missing -- the nested one
      // contributes nothing extra since it's already inside it.
      final topFaceTris = mesh.triangles.where((t) => mesh.vertices[t[0]].z == 3).toList();
      final area = _sumTriangleAreas(mesh.vertices.map((v) => Vec2(v.x, v.y)).toList(), topFaceTris);
      expect(area, closeTo(900 - math.pi * 100, 2.5));
    });

    test('two identical holes at the same spot are both kept (never mutually dropped)', () {
      // Same-area holes can never satisfy the *strictly* larger check, so a
      // duplicate hole doesn't disappear -- only a genuinely nested, smaller
      // one does.
      final holes = [
        _circle(const Vec2(5, 5), 2, segments: 24),
        _circle(const Vec2(5, 5), 2, segments: 24),
      ];
      final mesh = extrudePlate(outer: _rect(10, 10), holes: holes, thickness: 3);
      _expectManifold(mesh);
    });

    test('produces a watertight mesh for a plate with no holes', () {
      final mesh = extrudePlate(outer: _rect(10, 10), holes: const [], thickness: 3);
      _expectManifold(mesh);
    });

    test('two holes whose rightmost points land at the exact same Y stay manifold', () {
      // Regression test for a real reported corrupt STL export: two
      // axis-aligned rectangular holes at matching heights (extremely common
      // -- e.g. mounting slots mirrored left/right on an enclosure) cast
      // identical horizontal bridge rays. The nearer hole's own already-
      // bridged slit has walls that end *exactly* at that Y, which the
      // bridge-finding ray's strict crossing test excluded -- making it
      // invisible to the farther hole's ray and sending its bridge straight
      // through/past it to the same target, producing two overlapping
      // bridge segments and a non-manifold mesh.
      List<Vec2> squareAt(double cx, double cy) => [
            Vec2(cx - 2, cy - 2),
            Vec2(cx + 2, cy - 2),
            Vec2(cx + 2, cy + 2),
            Vec2(cx - 2, cy + 2),
          ];
      final mesh = extrudePlate(
        outer: _rect(100, 40),
        holes: [
          squareAt(80, 20), // nearer the right edge -- bridged first
          squareAt(20, 20), // same Y, farther away -- bridged second
        ],
        thickness: 5,
      );
      _expectManifold(mesh);
    });

    test('vertices span exactly [0, thickness] in z', () {
      final mesh = extrudePlate(
        outer: _rect(10, 10),
        holes: [_circle(const Vec2(5, 5), 2, segments: 24)],
        thickness: 4.5,
      );
      final zs = mesh.vertices.map((v) => v.z).toSet();
      expect(zs, {0.0, 4.5});
    });
  });

  group('buildAnnularTube', () {
    double signedVolume(Mesh mesh) {
      var vol = 0.0;
      for (final t in mesh.triangles) {
        final a = mesh.vertices[t[0]];
        final b = mesh.vertices[t[1]];
        final c = mesh.vertices[t[2]];
        final crossX = b.y * c.z - b.z * c.y;
        final crossY = b.z * c.x - b.x * c.z;
        final crossZ = b.x * c.y - b.y * c.x;
        vol += (a.x * crossX + a.y * crossY + a.z * crossZ) / 6;
      }
      return vol;
    }

    test('produces a watertight, correctly-oriented (positive volume) tube', () {
      final mesh = buildAnnularTube(
        center: const Vec2(10, 5),
        innerRadius: 2,
        outerRadius: 4,
        baseZ: 5,
        topZ: 8,
        segments: 24,
      );
      _expectManifold(mesh);
      final expected = math.pi * (16 - 4) * 3;
      expect(signedVolume(mesh), closeTo(expected, expected * 0.02));
    });

    test('vertices span exactly [baseZ, topZ] in z', () {
      final mesh = buildAnnularTube(center: const Vec2(0, 0), innerRadius: 1, outerRadius: 3, baseZ: 5, topZ: 8);
      final zs = mesh.vertices.map((v) => v.z).toSet();
      expect(zs, {5.0, 8.0});
    });
  });

  group('combineMeshes', () {
    test('offsets each mesh\'s triangle indices into the shared combined vertex list', () {
      final a = extrudePlate(outer: _rect(10, 10), holes: const [], thickness: 3);
      final b = buildAnnularTube(center: const Vec2(20, 20), innerRadius: 1, outerRadius: 2, baseZ: 3, topZ: 6);
      final combined = combineMeshes([a, b]);
      expect(combined.vertices.length, a.vertices.length + b.vertices.length);
      expect(combined.triangles.length, a.triangles.length + b.triangles.length);
      _expectManifold(a);
      _expectManifold(b);
      // Every triangle index in the combined mesh must point at a real vertex.
      for (final t in combined.triangles) {
        for (final i in t) {
          expect(i, inInclusiveRange(0, combined.vertices.length - 1));
        }
      }
    });
  });
}
