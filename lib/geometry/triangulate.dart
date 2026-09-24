import 'dart:math' as math;

import '../models/vec2.dart';

double _cross(Vec2 o, Vec2 a, Vec2 b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

double signedArea(List<Vec2> poly) {
  var sum = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % poly.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2;
}

double triangleArea(Vec2 a, Vec2 b, Vec2 c) => _cross(a, b, c).abs() / 2;

/// Strictly interior — a point sitting exactly on an edge or at a corner
/// does *not* count. Bridging routinely creates several vertex pairs that
/// share a position (a hole's rightmost point and its bridge target each
/// appear twice, at topologically distinct places in the boundary); a
/// boundary-inclusive test flags those as "containing" any ear that
/// happens to touch that coordinate, which rejects almost every ear near a
/// bridge seam even though nothing actually overlaps.
bool _pointStrictlyInsideTriangle(Vec2 p, Vec2 a, Vec2 b, Vec2 c) {
  final d1 = _cross(a, b, p);
  final d2 = _cross(b, c, p);
  final d3 = _cross(c, a, p);
  return (d1 > 0 && d2 > 0 && d3 > 0) || (d1 < 0 && d2 < 0 && d3 < 0);
}

/// True if [p] lies exactly on the open segment `(a, b)` — collinear with,
/// and strictly between, its endpoints. A diagonal that merely grazes a
/// vertex this way (common with the reflex corners a mounting flange/notch
/// produces, where a straight diagonal between two non-adjacent boundary
/// vertices can pass directly through a third one sitting between them) is
/// caught by neither [_pointStrictlyInsideTriangle] (the vertex is on an
/// edge, not strictly inside) nor [_properlyIntersect] (touching a shared
/// point isn't a proper crossing) — so without this check the clipper
/// happily clips it, orphaning that third vertex's boundary edges.
bool _pointOnOpenSegment(Vec2 p, Vec2 a, Vec2 b) {
  if (_cross(a, b, p).abs() > 1e-9) return false;
  final dot = (p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y);
  if (dot <= 0) return false;
  final lenSq = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y);
  return dot < lenSq;
}

bool _properlyIntersect(Vec2 p1, Vec2 p2, Vec2 p3, Vec2 p4) {
  double d(Vec2 a, Vec2 b, Vec2 c) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  final d1 = d(p3, p4, p1);
  final d2 = d(p3, p4, p2);
  final d3 = d(p1, p2, p3);
  final d4 = d(p1, p2, p4);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/// A bridge target found by [_findBridgeTarget]: either an existing vertex
/// of `working` (`isNew: false`, [afterIndex] *is* the target) or a new
/// point to be spliced into the boundary right after [afterIndex]
/// (`isNew: true`), splitting the edge it sits on.
class BridgeTarget {
  final int afterIndex;
  final Vec2 point;
  final bool isNew;
  const BridgeTarget(this.afterIndex, this.point, this.isNew);
}

/// Finds where [working] should be bridged to from [m] (a hole's rightmost
/// point), via the standard hole-bridging ray cast: cast a ray from [m] in
/// the +X direction and take the nearest point where it meets the boundary.
/// That point is, by construction, visible from [m] with nothing in between
/// — no occlusion check is needed the way it would be for a diagonal to
/// some other vertex — so it's always a valid bridge target. It usually
/// isn't an existing vertex, in which case the caller splices it in as a
/// new one splitting the edge it landed on; when it exactly coincides with
/// an existing vertex (the ray grazes a corner, or two holes' rays cross
/// the same edge at the same point), that vertex is reused instead of
/// creating a second vertex at an identical position — which is what
/// used to happen when multiple holes' bridges converged on the same
/// rectangle corner (there being nowhere else to bridge *to*, short of a
/// new point): ear-clipping would then find two different, validly
/// non-crossing diagonals that were nonetheless the exact same physical
/// segment, producing a duplicated face once vertices are welded by
/// position downstream (see [extrudePlate]).
BridgeTarget _findBridgeTarget(Vec2 m, List<Vec2> working, {double rayYOffset = 0}) {
  final n = working.length;
  // The ray is cast at this Y, not [m.y] itself, when [rayYOffset] is
  // nonzero -- see the caller for why: it's how two different holes whose
  // rightmost points land at the *exact* same Y (a common coincidence for
  // axis-aligned holes/slots at matching heights) get distinguishable rays.
  final rayY = m.y + rayYOffset;

  // Every earlier bridge is a zero-width slit traversed once out and once
  // back along the exact same line, so a ray that crosses one crosses both
  // of its edges at the identical x — a pass-through, not a real block.
  // Collect every rightward crossing, then cancel same-x crossings out in
  // pairs (odd counts leave a genuine blocking edge behind) instead of
  // naively taking whichever crossing happens to be found first.
  final crossings = <(double x, int edgeA, int edgeB)>[];
  for (var i = 0; i < n; i++) {
    final a = working[i];
    final b = working[(i + 1) % n];
    if (a.y == b.y) continue;
    if ((a.y > rayY) == (b.y > rayY)) continue;
    final t = (rayY - a.y) / (b.y - a.y);
    final x = a.x + t * (b.x - a.x);
    if (x <= m.x) continue;
    crossings.add((x, i, (i + 1) % n));
  }
  crossings.sort((p, q) => p.$1.compareTo(q.$1));

  double? bestX;
  var edgeA = -1;
  var edgeB = -1;
  var i = 0;
  while (i < crossings.length) {
    var count = 1;
    while (i + count < crossings.length && (crossings[i + count].$1 - crossings[i].$1).abs() < 1e-6) {
      count++;
    }
    if (count.isOdd) {
      bestX = crossings[i].$1;
      edgeA = crossings[i].$2;
      edgeB = crossings[i].$3;
      break;
    }
    i += count;
  }

  if (bestX == null) {
    // m has nothing to its right (it's the rightmost point of everything) —
    // fall back to the closest vertex by angle from straight right.
    var best = 0;
    var bestAngle = double.infinity;
    for (var i = 0; i < n; i++) {
      if (working[i] == m) continue;
      final dx = working[i].x - m.x;
      final dy = working[i].y - m.y;
      final angle = math.atan2(dy.abs(), dx);
      if (angle < bestAngle) {
        bestAngle = angle;
        best = i;
      }
    }
    return BridgeTarget(best, working[best], false);
  }

  final iPoint = Vec2(bestX, rayY);
  // A near-miss (not just an exact match) still needs reusing: two holes'
  // rays can cross the same short discretized-circle edge at points that
  // are only a hair apart, and inserting two separate new vertices that
  // close probably degenerates the same way an exact duplicate would in
  // the ear-clipping predicates below (a near-zero-area/near-collinear
  // sliver that the strict, exact-arithmetic checks can misjudge either
  // way). Snapping one onto the other costs nothing visible at plate scale.
  const epsilon = 1e-6;
  for (var i = 0; i < n; i++) {
    final v = working[i];
    if ((v.x - iPoint.x).abs() < epsilon && (v.y - iPoint.y).abs() < epsilon) {
      return BridgeTarget(i, v, false);
    }
  }
  return BridgeTarget(edgeA, iPoint, true);
}

/// Result of [mergeHolesIntoOuter]: the single bridged [polygon] ready for
/// ear-clipping, plus the outer boundary and each hole's own boundary loop
/// exactly as they should be walked for wall generation — meaning with any
/// Steiner points [_findBridgeTarget] inserted along the way included, so a
/// wall segment always matches a real top/bottom-face boundary edge.
class MergeResult {
  final List<Vec2> polygon;
  final List<Vec2> outerBoundary;
  final List<List<Vec2>> holeBoundaries;
  const MergeResult(this.polygon, this.outerBoundary, this.holeBoundaries);
}

/// Inserts [point] into the closed loop [loop] between whichever adjacent
/// pair of its vertices matches ([a], [b]) (in either order) — used to keep
/// [MergeResult.outerBoundary]/[holeBoundaries] in sync when a bridge splits
/// one of their edges. `loop` is modified in place.
void _insertIntoLoop(List<Vec2> loop, Vec2 a, Vec2 b, Vec2 point) {
  final n = loop.length;
  for (var i = 0; i < n; i++) {
    final p = loop[i];
    final q = loop[(i + 1) % n];
    if ((p == a && q == b) || (p == b && q == a)) {
      loop.insert(i + 1, point);
      return;
    }
  }
}

/// Merges each hole in [holesCcw] into [outerCcw] by bridging it to a
/// visible boundary vertex, found via [_findBridgeTarget] (the classic
/// "keyhole" technique), producing a single simple polygon suitable for
/// ear-clipping. Both the outer boundary and every hole must already be
/// closed loops (first point not repeated at the end).
MergeResult mergeHolesIntoOuter(List<Vec2> outerCcw, List<List<Vec2>> holesCcw) {
  var working = List<Vec2>.from(outerCcw);
  if (signedArea(working) < 0) working = working.reversed.toList();

  // Tracks which original boundary ('outer' or 'hole$i') each position in
  // `working` belongs to, so a Steiner insertion (which always splits an
  // edge whose two endpoints share one owner) can be mirrored into that
  // owner's own refined loop below.
  var workingOwner = List<String>.filled(working.length, 'outer');
  final outerBoundary = List<Vec2>.from(working);
  final holeBoundaries = [for (final h in holesCcw) List<Vec2>.from(h)];
  List<Vec2> loopFor(String owner) => owner == 'outer' ? outerBoundary : holeBoundaries[int.parse(owner.substring(4))];

  final indexedHoles = [for (var i = 0; i < holesCcw.length; i++) (i, holesCcw[i])]
    ..sort((a, b) {
      final maxA = a.$2.map((p) => p.x).reduce(math.max);
      final maxB = b.$2.map((p) => p.x).reduce(math.max);
      return maxB.compareTo(maxA);
    });

  for (final (holeIndex, rawHole) in indexedHoles) {
    if (rawHole.length < 3) continue;
    var hole = List<Vec2>.from(rawHole);
    if (signedArea(hole) > 0) hole = hole.reversed.toList(); // must be CW inside a CCW outer

    var mIdx = 0;
    for (var i = 1; i < hole.length; i++) {
      if (hole[i].x > hole[mIdx].x) mIdx = i;
    }
    final m = hole[mIdx];

    // A tiny, hole-specific offset to the ray's Y: without it, two holes
    // whose rightmost points coincidentally sit at the exact same Y (common
    // for axis-aligned holes/slots at matching heights) cast identical
    // rays, and an earlier hole's own already-bridged slit becomes
    // invisible to a later hole's crossing test (its slit walls end exactly
    // *at* that Y, which the strict less-than/greater-than crossing check
    // excludes) -- sending the later hole's bridge straight through/past it
    // to the same far target, producing two overlapping bridge segments and
    // a non-manifold mesh. Offsetting by (holeIndex + 1) * 1e-5 is enough to
    // separate any two holes' rays (comfortably above the 1e-6
    // vertex-reuse-snap epsilon below, so it doesn't defeat that) while
    // being negligible at real plate scale.
    final target = _findBridgeTarget(m, working, rayYOffset: (holeIndex + 1) * 1e-5);
    int chosen;
    if (target.isNew) {
      final owner = workingOwner[target.afterIndex];
      _insertIntoLoop(loopFor(owner), working[target.afterIndex], working[target.afterIndex + 1], target.point);
      working = [
        ...working.sublist(0, target.afterIndex + 1),
        target.point,
        ...working.sublist(target.afterIndex + 1),
      ];
      workingOwner = [
        ...workingOwner.sublist(0, target.afterIndex + 1),
        owner,
        ...workingOwner.sublist(target.afterIndex + 1),
      ];
      chosen = target.afterIndex + 1;
    } else {
      chosen = target.afterIndex;
    }
    final attachOwner = workingOwner[chosen];
    final rotatedHole = [for (var k = 0; k < hole.length; k++) hole[(mIdx + k) % hole.length]];
    final bridgeStart = working[chosen];
    final holeOwner = 'hole$holeIndex';

    final spliced = <Vec2>[];
    final splicedOwner = <String>[];
    for (var i = 0; i <= chosen; i++) {
      spliced.add(working[i]);
      splicedOwner.add(workingOwner[i]);
    }
    spliced.addAll(rotatedHole);
    splicedOwner.addAll(List.filled(rotatedHole.length, holeOwner));
    spliced.add(m);
    splicedOwner.add(holeOwner);
    spliced.add(bridgeStart);
    splicedOwner.add(attachOwner);
    for (var i = chosen + 1; i < working.length; i++) {
      spliced.add(working[i]);
      splicedOwner.add(workingOwner[i]);
    }
    working = spliced;
    workingOwner = splicedOwner;
  }

  return MergeResult(working, outerBoundary, holeBoundaries);
}

/// Canonical, order-independent, position-based key for an edge/diagonal —
/// used to catch a diagonal being clipped a second time under a *different*
/// pair of vertex indices that merely happen to sit at the same two
/// physical positions (see [earClipTriangulate]'s `usedDiagonals`).
String _posKey(Vec2 a, Vec2 b) {
  final p1 = '${a.x},${a.y}';
  final p2 = '${b.x},${b.y}';
  return p1.compareTo(p2) <= 0 ? '$p1|$p2' : '$p2|$p1';
}

/// Ear-clipping triangulation of a simple (possibly already hole-bridged)
/// polygon. Returns triangles as index triples into [pts]. Robust to the
/// zero-area duplicate-vertex bridge seams [mergeHolesIntoOuter] produces.
List<List<int>> earClipTriangulate(List<Vec2> pts) {
  final n = pts.length;
  if (n < 3) return [];

  final area = signedArea(pts);
  var order = List<int>.generate(n, (i) => i);
  if (area < 0) order = order.reversed.toList();

  final triangles = <List<int>>[];
  var remaining = order;
  var guard = 0;
  // Once an ear's closing diagonal (a -> c) is clipped, it becomes a
  // boundary edge of the reduced polygon and is never a diagonal again — so
  // the same physical segment should never be proposed as a diagonal twice.
  // When two or more holes bridge to the exact same target vertex (entirely
  // legitimate — see mergeHolesIntoOuter), the boundary ends up with
  // several *different-index, same-position* copies of that vertex; a later
  // ear can then reach a diagonal that is positionally identical to one
  // already clipped via a different copy. `_properlyIntersect` doesn't
  // flag that (it's collinear, not a proper crossing), so without this
  // check the clipper happily validates both — producing two triangles
  // that trace the same physical diagonal, which becomes a duplicated face
  // once vertices are welded by position downstream (extrudePlate).
  final usedDiagonals = <String>{};
  while (remaining.length > 3 && guard < n * n + 16) {
    guard++;
    var clippedIndex = -1;
    for (var i = 0; i < remaining.length; i++) {
      final iPrev = remaining[(i - 1 + remaining.length) % remaining.length];
      final iCurr = remaining[i];
      final iNext = remaining[(i + 1) % remaining.length];
      final a = pts[iPrev];
      final b = pts[iCurr];
      final c = pts[iNext];
      if (_cross(a, b, c) <= 1e-9) continue;

      // Both checks below exclude by INDEX (this candidate ear's own three
      // corners / edges), never by coordinate — bridging deliberately
      // creates several pairs of vertices that share a position (a hole's
      // rightmost point and its bridge target each appear twice), and those
      // are topologically distinct places in the boundary that must still
      // be checked against, not waved through because they look identical.
      var containsOther = false;
      for (final j in remaining) {
        if (j == iPrev || j == iCurr || j == iNext) continue;
        if (_pointStrictlyInsideTriangle(pts[j], a, b, c) || _pointOnOpenSegment(pts[j], a, c)) {
          containsOther = true;
          break;
        }
      }
      if (containsOther) continue;

      if (usedDiagonals.contains(_posKey(a, c))) continue;

      // Vertex-containment alone isn't sufficient once holes have been
      // bridged into the boundary: the "ear"'s closing diagonal (a -> c)
      // can cut across a hole/slit edge without any vertex happening to
      // fall inside the triangle. Reject that case too, or clipping it
      // would carve out (or double up) area that doesn't belong to it.
      var diagonalCrossesEdge = false;
      for (var k = 0; k < remaining.length; k++) {
        final e1 = remaining[k];
        final e2 = remaining[(k + 1) % remaining.length];
        if ((e1 == iPrev && e2 == iCurr) || (e1 == iCurr && e2 == iNext)) continue;
        if (_properlyIntersect(a, c, pts[e1], pts[e2])) {
          diagonalCrossesEdge = true;
          break;
        }
      }
      if (diagonalCrossesEdge) continue;

      usedDiagonals.add(_posKey(a, c));
      triangles.add([iPrev, iCurr, iNext]);
      clippedIndex = i;
      break;
    }

    if (clippedIndex == -1) {
      // No candidate passed both checks — pick the smallest convex,
      // vertex-containment-clean ear we can find (ignoring the diagonal
      // check as a last resort) rather than the most-convex one: a small
      // local ear is far less likely to overlap distant geometry than the
      // sweeping triangle "most convex" tends to produce, which is what was
      // silently corrupting the total area on complex, multi-hole shapes.
      var bestI = -1;
      var bestArea = double.infinity;
      // Run twice: first refusing to reuse an already-clipped diagonal's
      // position (same reasoning as the primary pass above), then — only if
      // that finds nothing at all — again without that restriction, so a
      // pathological shape still terminates rather than falling through to
      // the much cruder most-convex-vertex fallback below.
      for (final avoidUsedDiagonals in [true, false]) {
        for (var i = 0; i < remaining.length; i++) {
          final iPrev = remaining[(i - 1 + remaining.length) % remaining.length];
          final iCurr = remaining[i];
          final iNext = remaining[(i + 1) % remaining.length];
          final a = pts[iPrev];
          final b = pts[iCurr];
          final c = pts[iNext];
          if (_cross(a, b, c) <= 1e-9) continue;
          if (avoidUsedDiagonals && usedDiagonals.contains(_posKey(a, c))) continue;
          var containsOther = false;
          for (final j in remaining) {
            if (j == iPrev || j == iCurr || j == iNext) continue;
            if (_pointStrictlyInsideTriangle(pts[j], a, b, c) || _pointOnOpenSegment(pts[j], a, c)) {
              containsOther = true;
              break;
            }
          }
          if (containsOther) continue;
          final area = triangleArea(a, b, c);
          if (area < bestArea) {
            bestArea = area;
            bestI = i;
          }
        }
        if (bestI != -1) break;
      }
      // Truly nothing is even locally convex-and-clean (shouldn't happen
      // for a valid simple polygon) — fall back to the most-convex vertex
      // just to guarantee the loop terminates. Same two-pass preference for
      // an unused diagonal as above, for the same reason.
      if (bestI == -1) {
        for (final avoidUsedDiagonals in [true, false]) {
          var bestCross = double.negativeInfinity;
          for (var i = 0; i < remaining.length; i++) {
            final iPrev = remaining[(i - 1 + remaining.length) % remaining.length];
            final iCurr = remaining[i];
            final iNext = remaining[(i + 1) % remaining.length];
            if (avoidUsedDiagonals && usedDiagonals.contains(_posKey(pts[iPrev], pts[iNext]))) continue;
            final cr = _cross(pts[iPrev], pts[iCurr], pts[iNext]);
            if (cr > bestCross) {
              bestCross = cr;
              bestI = i;
            }
          }
          if (bestI != -1) break;
        }
      }
      final iPrev = remaining[(bestI - 1 + remaining.length) % remaining.length];
      final iCurr = remaining[bestI];
      final iNext = remaining[(bestI + 1) % remaining.length];
      usedDiagonals.add(_posKey(pts[iPrev], pts[iNext]));
      triangles.add([iPrev, iCurr, iNext]);
      clippedIndex = bestI;
    }

    remaining = [for (var i = 0; i < remaining.length; i++) if (i != clippedIndex) remaining[i]];
  }
  if (remaining.length == 3) {
    triangles.add([remaining[0], remaining[1], remaining[2]]);
  }

  return triangles
      .where((t) => triangleArea(pts[t[0]], pts[t[1]], pts[t[2]]) > 1e-6)
      .toList();
}
