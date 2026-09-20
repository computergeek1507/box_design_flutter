import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../design/snap.dart';
import '../models/controller_template.dart';
import '../models/dxf_entity.dart';
import '../models/vec2.dart';
import 'image_detect.dart';

const _bulge90 = 0.4142135623730951; // tan(90deg / 4), quarter-circle bulge

enum TemplateMakerHoleShape { round, slot, rect }

/// How each corner of the outline rectangle is treated. [size] (a separate
/// field on the controller) is the fillet radius, chamfer cut, or notch cut
/// depending on which style is selected; a size of 0 always yields a plain
/// sharp-cornered rectangle regardless of style.
enum TemplateMakerCornerStyle { fillet, chamfer, cornerCut }

/// A single mounting hole in the template being built: either a round hole
/// (sized by [diameter]) or an elongated slot (sized by [slotLength] /
/// [slotWidth] and oriented by [rotationDeg]), with a center position in
/// the template's own local coordinate space (min corner of the outline
/// sits at (0, 0), matching every other template).
class TemplateMakerHole {
  final String id;
  TemplateMakerHoleShape shape;
  double x;
  double y;
  double diameter;
  double slotLength;
  double slotWidth;
  double rotationDeg;

  TemplateMakerHole({
    required this.id,
    required this.x,
    required this.y,
    this.shape = TemplateMakerHoleShape.round,
    this.diameter = 4,
    this.slotLength = 12,
    this.slotWidth = 4,
    this.rotationDeg = 0,
  });
}

/// A [length] x [width] rectangle centered on the origin with its long axis
/// along X, as a closed 4-vertex polygon (no bulge).
List<PolyVertex> rectVertices(double length, double width) {
  final hl = length / 2, hw = width / 2;
  return [
    PolyVertex(Vec2(-hl, -hw)),
    PolyVertex(Vec2(hl, -hw)),
    PolyVertex(Vec2(hl, hw)),
    PolyVertex(Vec2(-hl, hw)),
  ];
}

/// A rectangle outline with a square notch cut from each corner (e.g. for
/// corner clearance around fasteners or an adjoining panel), as a single
/// closed 12-vertex polygon -- no bulge, every edge straight. [cut] is
/// clamped by the caller to at most half the shorter side.
List<PolyVertex> notchedRectVertices(double width, double height, double cut) {
  final c = cut;
  return [
    PolyVertex(Vec2(c, 0)),
    PolyVertex(Vec2(width - c, 0)),
    PolyVertex(Vec2(width - c, c)),
    PolyVertex(Vec2(width, c)),
    PolyVertex(Vec2(width, height - c)),
    PolyVertex(Vec2(width - c, height - c)),
    PolyVertex(Vec2(width - c, height)),
    PolyVertex(Vec2(c, height)),
    PolyVertex(Vec2(c, height - c)),
    PolyVertex(Vec2(0, height - c)),
    PolyVertex(Vec2(0, c)),
    PolyVertex(Vec2(c, c)),
  ];
}

/// A rectangle outline with a straight 45-degree cut across each corner
/// (chamfer), as a single closed 8-vertex polygon -- no bulge, every edge
/// straight. [cut] is clamped by the caller to at most half the shorter
/// side.
List<PolyVertex> chamferedRectVertices(double width, double height, double cut) {
  final c = cut;
  return [
    PolyVertex(Vec2(c, 0)),
    PolyVertex(Vec2(width - c, 0)),
    PolyVertex(Vec2(width, c)),
    PolyVertex(Vec2(width, height - c)),
    PolyVertex(Vec2(width - c, height)),
    PolyVertex(Vec2(c, height)),
    PolyVertex(Vec2(0, height - c)),
    PolyVertex(Vec2(0, c)),
  ];
}

double _dist(Vec2 a, Vec2 b) {
  final dx = a.x - b.x, dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Backs the template maker screen: an outline rectangle (width/height,
/// optionally corner-filleted or corner-notched) plus a flat list of round
/// or slot holes, convertible to/from the same [ControllerTemplate] JSON
/// format the rest of the app reads and writes -- so a template built here
/// drops straight into `assets/templates/` or an imported/remote template
/// library with no separate format to maintain.
class TemplateMakerController extends ChangeNotifier {
  String id = 'new_template';
  String name = 'New Template';
  TemplateCategory category = TemplateCategory.box;
  double outlineWidth = 100;
  double outlineHeight = 100;
  TemplateMakerCornerStyle cornerStyle = TemplateMakerCornerStyle.fillet;
  double cornerSize = 0;
  final List<TemplateMakerHole> holes = [];

  /// Optional tracing overlay (a screenshot/drawing to line the outline and
  /// holes up against). Positioned by its bottom-left corner and sized in
  /// template mm; never exported with the template.
  ui.Image? refImage;
  String? refImageName;
  double imageX = 0;
  double imageY = 0;
  double imageWidth = 100;
  double imageHeight = 100;
  double imageOpacity = 0.5;
  bool imageLockAspect = true;

  Uint8List? _refPixels;

  /// Click-to-measure state: with [measureMode] on, the first click sets
  /// [measureStart], the second [measureEnd], and a third starts over.
  bool measureMode = false;
  Vec2? measureStart;
  Vec2? measureEnd;

  void toggleMeasureMode() {
    measureMode = !measureMode;
    measureStart = null;
    measureEnd = null;
    notifyListeners();
  }

  void placeMeasurePoint(Vec2 mm) {
    if (measureStart == null || measureEnd != null) {
      measureStart = mm;
      measureEnd = null;
    } else {
      measureEnd = mm;
    }
    notifyListeners();
  }

  /// Snaps [raw] (template mm) to a hole/slot center, a slot's rounded-end
  /// center, a point on the outline (edges, corners, fillet centers) or a
  /// corner of the reference image, within [toleranceMm].
  Vec2 snapMeasurePoint(Vec2 raw, double toleranceMm) {
    final entities = toTemplate().entities;
    return snapToGeometry(
      raw,
      points: [
        for (final h in holes) Vec2(h.x, h.y),
        if (refImage != null) ...[
          Vec2(imageX, imageY),
          Vec2(imageX + imageWidth, imageY),
          Vec2(imageX, imageY + imageHeight),
          Vec2(imageX + imageWidth, imageY + imageHeight),
        ],
      ],
      centerOnly: entities.skip(1),
      edges: entities.take(1),
      toleranceMm: toleranceMm,
    );
  }

  /// The hole/slot highlighted in the preview and list, if any.
  String? selectedHoleId;

  void selectHole(String? holeId) {
    if (selectedHoleId == holeId) return;
    selectedHoleId = holeId;
    notifyListeners();
  }

  int _nextHoleSeq = 1;

  void setId(String value) {
    id = value;
    notifyListeners();
  }

  void setName(String value) {
    name = value;
    notifyListeners();
  }

  void setCategory(TemplateCategory value) {
    category = value;
    notifyListeners();
  }

  void setOutlineWidth(double value) {
    if (value <= 0) return;
    outlineWidth = value;
    notifyListeners();
  }

  void setOutlineHeight(double value) {
    if (value <= 0) return;
    outlineHeight = value;
    notifyListeners();
  }

  /// Which corner treatment [cornerSize] applies as: fillet (rounded),
  /// chamfer (straight 45-degree cut), or corner cut (square notch).
  void setCornerStyle(TemplateMakerCornerStyle value) {
    cornerStyle = value;
    notifyListeners();
  }

  /// Size in mm of the selected [cornerStyle]'s corner treatment -- fillet
  /// radius, chamfer cut, or notch cut. 0 for plain sharp corners. Clamped
  /// to the outline's own half-width/height when applied so it can never
  /// invert the rectangle.
  void setCornerSize(double value) {
    if (value < 0) return;
    cornerSize = value;
    notifyListeners();
  }

  void addHole() {
    final hole = TemplateMakerHole(
      id: 'hole${_nextHoleSeq++}',
      x: outlineWidth / 2,
      y: outlineHeight / 2,
      diameter: 4,
    );
    holes.add(hole);
    selectedHoleId = hole.id;
    notifyListeners();
  }

  void addSlot() {
    final hole = TemplateMakerHole(
      id: 'hole${_nextHoleSeq++}',
      x: outlineWidth / 2,
      y: outlineHeight / 2,
      shape: TemplateMakerHoleShape.slot,
      slotLength: 12,
      slotWidth: 4,
    );
    holes.add(hole);
    selectedHoleId = hole.id;
    notifyListeners();
  }

  /// Adds a standard 4-hole rectangular mounting pattern -- one hole at each
  /// corner of a [horizontalSpacing] x [verticalSpacing] rectangle centered
  /// on the outline's own centerline, matching how a real board's 4-corner
  /// mounting holes are usually specified (center-to-center spacing, not
  /// absolute position).
  ///
  /// If [outlineOffset] is given, the outline is resized first to exactly
  /// fit the pattern plus that much margin on each side (width = spacing +
  /// 2 x offset), so the board comes out sized to the mounting holes
  /// instead of needing its own width/height set beforehand.
  void addQuickHolePattern({
    required double horizontalSpacing,
    required double verticalSpacing,
    double diameter = 4,
    double? outlineOffset,
  }) {
    if (outlineOffset != null) {
      setOutlineWidth(horizontalSpacing + outlineOffset * 2);
      setOutlineHeight(verticalSpacing + outlineOffset * 2);
    }
    final cx = outlineWidth / 2;
    final cy = outlineHeight / 2;
    final hx = horizontalSpacing / 2;
    final hy = verticalSpacing / 2;
    for (final dx in [-hx, hx]) {
      for (final dy in [-hy, hy]) {
        holes.add(TemplateMakerHole(
          id: 'hole${_nextHoleSeq++}',
          x: cx + dx,
          y: cy + dy,
          diameter: diameter,
        ));
      }
    }
    notifyListeners();
  }

  void removeHole(String holeId) {
    holes.removeWhere((h) => h.id == holeId);
    if (selectedHoleId == holeId) selectedHoleId = null;
    notifyListeners();
  }

  void updateHole(
    String holeId, {
    double? x,
    double? y,
    double? diameter,
    double? slotLength,
    double? slotWidth,
    double? rotationDeg,
  }) {
    for (final h in holes) {
      if (h.id != holeId) continue;
      if (x != null) h.x = x;
      if (y != null) h.y = y;
      if (diameter != null && diameter > 0) h.diameter = diameter;
      if (slotLength != null && slotLength > 0) h.slotLength = slotLength;
      if (slotWidth != null && slotWidth > 0) h.slotWidth = slotWidth;
      if (rotationDeg != null) h.rotationDeg = rotationDeg;
      break;
    }
    notifyListeners();
  }

  /// Shifts every hole's position by ([dx], [dy]) mm, e.g. for nudging a
  /// whole pattern after eyeballing it against a reference drawing.
  void shiftAllHoles(double dx, double dy) {
    if (dx == 0 && dy == 0) return;
    for (final h in holes) {
      h.x += dx;
      h.y += dy;
    }
    notifyListeners();
  }

  double get _imageAspect => refImage == null ? 1 : refImage!.width / refImage!.height;

  /// Decodes [bytes] as the reference image and drops it at the outline's
  /// bottom-left, scaled to the outline's width (aspect preserved).
  Future<void> loadReferenceImage(Uint8List bytes, String name) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    refImage?.dispose();
    refImage = frame.image;
    refImageName = name;
    _refPixels = null;
    fitImageToOutline(keepAspect: true);
  }

  void clearReferenceImage() {
    refImage?.dispose();
    refImage = null;
    _refPixels = null;
    refImageName = null;
    notifyListeners();
  }

  /// Sizes the image to the outline's width and pins it to (0, 0); with
  /// [keepAspect] false it is stretched to the outline's width *and* height.
  void fitImageToOutline({bool keepAspect = true}) {
    if (refImage == null) return;
    imageX = 0;
    imageY = 0;
    imageWidth = outlineWidth;
    imageHeight = keepAspect ? outlineWidth / _imageAspect : outlineHeight;
    notifyListeners();
  }

  void setImagePosition({double? x, double? y}) {
    if (x != null) imageX = x;
    if (y != null) imageY = y;
    notifyListeners();
  }

  /// Resizes the image; with [imageLockAspect] on, changing one dimension
  /// derives the other from the image's own aspect ratio.
  void setImageSize({double? width, double? height}) {
    if (refImage == null) return;
    if (width != null && width > 0) {
      imageWidth = width;
      if (imageLockAspect) imageHeight = width / _imageAspect;
    } else if (height != null && height > 0) {
      imageHeight = height;
      if (imageLockAspect) imageWidth = height * _imageAspect;
    }
    notifyListeners();
  }

  void setImageLockAspect(bool value) {
    imageLockAspect = value;
    if (value && refImage != null) imageHeight = imageWidth / _imageAspect;
    notifyListeners();
  }

  void setImageOpacity(double value) {
    imageOpacity = value.clamp(0.05, 1.0);
    notifyListeners();
  }

  /// Resizes by dragging a corner: [fixed] (the opposite corner) stays put
  /// and [pointer] is where the dragged corner now is, both in template mm.
  void scaleImageFromCorner(Vec2 fixed, Vec2 pointer) {
    if (refImage == null) return;
    final sx = pointer.x >= fixed.x ? 1.0 : -1.0;
    final sy = pointer.y >= fixed.y ? 1.0 : -1.0;
    var w = math.max((pointer.x - fixed.x).abs(), 1.0);
    var h = math.max((pointer.y - fixed.y).abs(), 1.0);
    if (imageLockAspect) h = w / _imageAspect;
    imageWidth = w;
    imageHeight = h;
    imageX = sx > 0 ? fixed.x : fixed.x - w;
    imageY = sy > 0 ? fixed.y : fixed.y - h;
    notifyListeners();
  }

  Future<ImageDetection?> _detectInImage() async {
    final img = refImage;
    if (img == null) return null;
    _refPixels ??= (await img.toByteData(format: ui.ImageByteFormat.rawRgba))?.buffer.asUint8List();
    final pixels = _refPixels;
    if (pixels == null) return null;
    return detectBoardAndHoles(pixels, img.width, img.height, outlineWidthMm: outlineWidth, outlineHeightMm: outlineHeight);
  }

  /// Finds the board outline in the reference image and scales/moves the
  /// image so that outline lands exactly on the template's outline. Returns
  /// the X-vs-Y scale mismatch in percent (the image gets stretched
  /// non-uniformly, with aspect lock turned off, when it isn't ~0), or null
  /// if no outline could be found.
  Future<double?> autoFitImageToOutline() async {
    final img = refImage;
    final det = await _detectInImage();
    if (img == null || det == null) return null;
    final o = det.outline;
    final sx = outlineWidth / o.width;
    final sy = outlineHeight / o.height;
    imageWidth = img.width * sx;
    imageHeight = img.height * sy;
    imageX = -o.left * sx;
    imageY = -(img.height - o.bottom) * sy;
    final mismatch = (sx / sy - 1).abs() * 100;
    if (mismatch > 0.5) imageLockAspect = false;
    notifyListeners();
    return mismatch;
  }

  /// Finds round holes, slots and rectangles enclosed by the outline in the
  /// reference image (using the image's *current* position and size, so fit
  /// it to the outline first) and adds them as holes, skipping any that
  /// duplicate an existing hole. Returns how many were added, or null if the
  /// image couldn't be analysed.
  Future<int?> detectHolesFromImage() async {
    final img = refImage;
    final det = await _detectInImage();
    if (img == null || det == null) return null;
    final mmPerPxX = imageWidth / img.width;
    final mmPerPxY = imageHeight / img.height;
    final avg = math.sqrt(mmPerPxX * mmPerPxY);
    double r1(double v) => (v * 10).round() / 10;

    var added = 0;
    for (final d in det.holes) {
      final x = r1(imageX + d.cx * mmPerPxX);
      final y = r1(imageY + imageHeight - d.cy * mmPerPxY);
      if (x < 0 || y < 0 || x > outlineWidth || y > outlineHeight) continue;

      final vertical = d.rotationDeg == 90;
      final aligned = d.rotationDeg == 0 || vertical;
      final lenMm = aligned ? d.length * (vertical ? mmPerPxY : mmPerPxX) : d.length * avg;
      final widMm = aligned ? d.width * (vertical ? mmPerPxX : mmPerPxY) : d.width * avg;
      final hole = TemplateMakerHole(
        id: 'hole$_nextHoleSeq',
        x: x,
        y: y,
        shape: switch (d.shape) {
          DetectedHoleShape.round => TemplateMakerHoleShape.round,
          DetectedHoleShape.slot => TemplateMakerHoleShape.slot,
          DetectedHoleShape.rect => TemplateMakerHoleShape.rect,
        },
        diameter: r1(d.length * avg),
        slotLength: r1(lenMm),
        slotWidth: r1(widMm),
        rotationDeg: d.rotationDeg.roundToDouble(),
      );
      final duplicate = holes.any((h) => (h.x - x).abs() < 1 && (h.y - y).abs() < 1);
      if (duplicate) continue;
      _nextHoleSeq++;
      holes.add(hole);
      added++;
    }
    notifyListeners();
    return added;
  }

  void newTemplate() {
    refImage?.dispose();
    refImage = null;
    _refPixels = null;
    refImageName = null;
    id = 'new_template';
    name = 'New Template';
    category = TemplateCategory.box;
    outlineWidth = 100;
    outlineHeight = 100;
    cornerStyle = TemplateMakerCornerStyle.fillet;
    cornerSize = 0;
    holes.clear();
    selectedHoleId = null;
    _nextHoleSeq = 1;
    notifyListeners();
  }

  /// Builds the template's geometry: a closed rectangular outline --
  /// optionally corner-filleted or corner-notched -- plus one [DxfCircle]
  /// per round hole and one closed stadium [DxfPolyline] per slot hole,
  /// exactly the shape [ControllerTemplate.toJson] (and the rest of the
  /// app, e.g. mesh export's own-hole detection) expect.
  ControllerTemplate toTemplate() {
    final size = cornerSize <= 0 ? 0.0 : math.min(cornerSize, math.min(outlineWidth, outlineHeight) / 2);
    final List<PolyVertex> vertices;
    if (size <= 0) {
      vertices = [
        const PolyVertex(Vec2(0, 0)),
        PolyVertex(Vec2(outlineWidth, 0)),
        PolyVertex(Vec2(outlineWidth, outlineHeight)),
        PolyVertex(Vec2(0, outlineHeight)),
      ];
    } else {
      switch (cornerStyle) {
        case TemplateMakerCornerStyle.cornerCut:
          vertices = notchedRectVertices(outlineWidth, outlineHeight, size);
          break;
        case TemplateMakerCornerStyle.chamfer:
          vertices = chamferedRectVertices(outlineWidth, outlineHeight, size);
          break;
        case TemplateMakerCornerStyle.fillet:
          vertices = [
            PolyVertex(Vec2(size, 0)),
            PolyVertex(Vec2(outlineWidth - size, 0), bulge: _bulge90),
            PolyVertex(Vec2(outlineWidth, size)),
            PolyVertex(Vec2(outlineWidth, outlineHeight - size), bulge: _bulge90),
            PolyVertex(Vec2(outlineWidth - size, outlineHeight)),
            PolyVertex(Vec2(size, outlineHeight), bulge: _bulge90),
            PolyVertex(Vec2(0, outlineHeight - size)),
            PolyVertex(Vec2(0, size), bulge: _bulge90),
          ];
          break;
      }
    }
    final entities = <DxfEntity>[
      DxfPolyline(vertices, closed: true),
      for (final h in holes)
        if (h.shape == TemplateMakerHoleShape.round)
          DxfCircle(Vec2(h.x, h.y), h.diameter / 2)
        else
          DxfPolyline(
            h.shape == TemplateMakerHoleShape.rect
                ? rectVertices(h.slotLength, h.slotWidth)
                : stadiumVertices(h.slotLength, h.slotWidth),
            closed: true,
          ).transformed(delta: Vec2(h.x, h.y), rotationDeg: h.rotationDeg),
    ];
    return ControllerTemplate(
      id: id,
      name: name,
      entities: entities,
      source: TemplateSource.imported,
      category: category,
    );
  }

  /// True for an entity this tool would itself only ever produce as a hole:
  /// a round [DxfCircle], or a 4-vertex closed polyline matching its own
  /// stadium bulge pattern (bulge 1.0 on vertices 0 and 2, matching
  /// [stadiumVertices]). Everything else -- lines, arcs, any other
  /// polyline -- is outline material.
  static bool _looksLikeHole(DxfEntity e) {
    if (e is DxfCircle) return true;
    if (e is DxfPolyline && e.closed && e.vertices.length == 4) {
      final bulges = e.vertices.map((v) => v.bulge).toList();
      return (bulges[0] - 1.0).abs() < 1e-6 &&
          bulges[1] == 0 &&
          (bulges[2] - 1.0).abs() < 1e-6 &&
          bulges[3] == 0;
    }
    return false;
  }

  /// True for a plain 4-vertex rectangle that sits strictly inside [outer]'s
  /// bounding box -- i.e. a rectangular hole, not the outline itself.
  static bool _isInnerRect(DxfEntity e, BoundingBox outer) {
    if (e is! DxfPolyline || !e.closed || e.vertices.length != 4) return false;
    if (e.vertices.any((v) => v.bulge != 0)) return false;
    final p = e.vertices.map((v) => v.point).toList();
    final ab = Vec2(p[1].x - p[0].x, p[1].y - p[0].y);
    final bc = Vec2(p[2].x - p[1].x, p[2].y - p[1].y);
    final dot = ab.x * bc.x + ab.y * bc.y;
    if (dot.abs() > 1e-6 * (_dist(p[0], p[1]) * _dist(p[1], p[2]) + 1)) return false;
    final b = e.boundingBox;
    const m = 0.01;
    return b.minX > outer.minX + m && b.maxX < outer.maxX - m && b.minY > outer.minY + m && b.maxY < outer.maxY - m;
  }

  /// Loads an existing template back into editable fields. The outline's
  /// size is the bounding box of every non-hole entity merged together --
  /// not just the single largest one -- since some exporters (e.g. the
  /// KiCad plugin) emit a board outline as separate line segments rather
  /// than one closed polyline, and each such segment's own bounding box is
  /// degenerate (zero width or height). Every [DxfCircle] becomes an
  /// editable round hole, and every stadium-shaped polyline becomes an
  /// editable slot. Any other entity shape (arcs, a slot built some other
  /// way) is dropped silently -- this tool only ever produces the shapes
  /// above, so round-tripping a template it didn't create is best-effort.
  void loadFromTemplate(ControllerTemplate template) {
    id = template.id;
    name = template.name;
    category = template.category;

    BoundingBox? largest;
    var largestArea = 0.0;
    for (final e in template.entities) {
      final b = e.boundingBox;
      if (b.width * b.height > largestArea) {
        largestArea = b.width * b.height;
        largest = b;
      }
    }
    bool isHole(DxfEntity e) => _looksLikeHole(e) || (largest != null && _isInnerRect(e, largest));

    final outlineEntities = template.entities.where((e) => !isHole(e)).toList();
    // If literally everything looked like a hole (shouldn't happen for a
    // real template), fall back to treating every entity as outline
    // material instead of showing an empty 0x0 outline.
    final outlineSource = outlineEntities.isEmpty ? template.entities : outlineEntities;

    BoundingBox? outlineBox;
    for (final e in outlineSource) {
      outlineBox = BoundingBox.merge(outlineBox, e.boundingBox);
    }

    cornerStyle = TemplateMakerCornerStyle.fillet;
    cornerSize = 0;
    if (outlineBox != null) {
      outlineWidth = outlineBox.width;
      outlineHeight = outlineBox.height;
      // This tool's own filleted/chamfered/notched outlines are always a
      // single 8- or 12-vertex polyline in a fixed shape (see toTemplate) --
      // read the style and size back off that shape when the outline is
      // exactly one such polyline. A multi-piece outline has no single shape
      // to inspect and just comes back in with sharp corners, which is
      // correct there.
      if (outlineSource.length == 1 && outlineSource.first is DxfPolyline) {
        final verts = (outlineSource.first as DxfPolyline).vertices;
        if (verts.length == 8 && verts.any((v) => v.bulge != 0)) {
          cornerStyle = TemplateMakerCornerStyle.fillet;
          cornerSize = verts.first.point.x.abs();
        } else if (verts.length == 8 && verts.every((v) => v.bulge == 0)) {
          cornerStyle = TemplateMakerCornerStyle.chamfer;
          cornerSize = verts.first.point.x.abs();
        } else if (verts.length == 12 && verts.every((v) => v.bulge == 0)) {
          cornerStyle = TemplateMakerCornerStyle.cornerCut;
          cornerSize = verts.first.point.x.abs();
        }
      }
    }

    holes.clear();
    selectedHoleId = null;
    _nextHoleSeq = 1;
    // In the fallback case above (nothing looked like a hole) there's
    // nothing left to extract as a hole either.
    final holeSource = outlineEntities.isEmpty ? const <DxfEntity>[] : template.entities.where(isHole);
    for (final e in holeSource) {
      if (e is DxfCircle) {
        holes.add(TemplateMakerHole(
          id: 'hole${_nextHoleSeq++}',
          x: e.center.x,
          y: e.center.y,
          diameter: e.radius * 2,
        ));
      } else if (e is DxfPolyline && e.vertices.every((v) => v.bulge == 0)) {
        final p = e.vertices.map((v) => v.point).toList();
        holes.add(TemplateMakerHole(
          id: 'hole${_nextHoleSeq++}',
          x: (p[0].x + p[1].x + p[2].x + p[3].x) / 4,
          y: (p[0].y + p[1].y + p[2].y + p[3].y) / 4,
          shape: TemplateMakerHoleShape.rect,
          slotLength: _dist(p[0], p[1]),
          slotWidth: _dist(p[1], p[2]),
          rotationDeg: math.atan2(p[1].y - p[0].y, p[1].x - p[0].x) * 180 / math.pi,
        ));
      } else if (e is DxfPolyline) {
        final v0 = e.vertices[0].point;
        final v1 = e.vertices[1].point;
        final v2 = e.vertices[2].point;
        final v3 = e.vertices[3].point;
        final center = Vec2((v0.x + v1.x + v2.x + v3.x) / 4, (v0.y + v1.y + v2.y + v3.y) / 4);
        final width = _dist(v0, v1);
        final straightSpan = _dist(v1, v2);
        final rotationDeg = math.atan2(v1.y - v0.y, v1.x - v0.x) * 180 / math.pi - 90;
        holes.add(TemplateMakerHole(
          id: 'hole${_nextHoleSeq++}',
          x: center.x,
          y: center.y,
          shape: TemplateMakerHoleShape.slot,
          slotLength: straightSpan + width,
          slotWidth: width,
          rotationDeg: rotationDeg,
        ));
      }
    }
    notifyListeners();
  }
}
