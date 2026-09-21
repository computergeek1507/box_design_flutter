import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../design/snap.dart';
import '../models/annotation.dart';
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

/// Which layer of the template the maker is showing/editing: the first
/// plate, the second plate of a two-layer box, or the drawing layer (notes).
enum TemplateMakerLayer { layer1, layer2, drawing }

/// One note on the drawing layer being edited; see [Annotation] for what
/// each field means per [type].
class TemplateMakerNote {
  final String id;
  final AnnotationType type;
  String text;
  double x;
  double y;
  double x2;
  double y2;
  double width;
  double height;
  double radius;
  double rotationDeg;

  TemplateMakerNote({
    required this.id,
    required this.type,
    this.text = '',
    this.x = 0,
    this.y = 0,
    this.x2 = 0,
    this.y2 = 0,
    this.width = 10,
    this.height = 5,
    this.radius = 5,
    this.rotationDeg = 0,
  });

  factory TemplateMakerNote.fromAnnotation(String id, Annotation a) => TemplateMakerNote(
        id: id,
        type: a.type,
        text: a.text,
        x: a.x,
        y: a.y,
        x2: a.x2,
        y2: a.y2,
        width: a.width,
        height: a.height,
        radius: a.radius,
        rotationDeg: a.rotationDeg,
      );

  Annotation toAnnotation() => Annotation(
        type: type,
        text: text,
        x: x,
        y: y,
        x2: x2,
        y2: y2,
        width: width,
        height: height,
        radius: radius,
        rotationDeg: rotationDeg,
      );
}

/// One plate's worth of outline settings and holes, used to park the plate
/// that isn't currently being edited.
/// Which draggable handle of the selected hole/slot/rectangle is grabbed.
/// Holes resize symmetrically about their centre, in their own (rotated) frame.
enum HoleHandle { radius, lengthPos, lengthNeg, widthPos, widthNeg, cornerNE, cornerNW, cornerSW, cornerSE }

/// Which draggable handle of the selected drawing-layer note is grabbed.
enum NoteHandle { start, end, cornerSW, cornerSE, cornerNW, cornerNE, radius, textSize }

/// Estimated width (mm) of a text note: about 0.6 of its height per
/// character. Used to place its resize handle and to hit-test it.
double noteTextWidthMm(TemplateMakerNote n) => math.max(n.text.length, 1) * n.height * 0.6;

class _Plate {
  final double outlineWidth;
  final double outlineHeight;
  final TemplateMakerCornerStyle cornerStyle;
  final double cornerSize;
  final List<TemplateMakerHole> holes;

  _Plate(this.outlineWidth, this.outlineHeight, this.cornerStyle, this.cornerSize, this.holes);
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

  /// Two-layer plate support: the fields above always describe the plate
  /// being edited; the other plate is parked in [_stored]. [layer] is the
  /// tab being shown (one at a time).
  bool dualLayer = false;
  TemplateMakerLayer layer = TemplateMakerLayer.layer1;
  _Plate? _stored;
  bool _fieldsAreLayer2 = false;

  /// The drawing layer.
  final List<TemplateMakerNote> notes = [];
  int _nextNoteSeq = 1;

  /// Every selected note. [selectedNoteId] is the primary one (the one whose
  /// handles and fields are shown when it's the only one); assigning it selects
  /// just that note, or none for null.
  final Set<String> selectedNoteIds = {};
  String? _primaryNoteId;
  String? get selectedNoteId => _primaryNoteId;
  set selectedNoteId(String? id) {
    selectedNoteIds.clear();
    _primaryNoteId = id;
    if (id != null) selectedNoteIds.add(id);
  }

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

  /// Grid and drag snapping. The grid is anchored at the plate's (0, 0) corner.
  static const gridSizesMm = [1.0, 2.0, 5.0, 10.0, 20.0];
  bool showGrid = true;
  bool snapToGrid = true;

  /// Snap a dragged point to the plate's edges and centre lines and to other
  /// holes'/notes' X and Y (alignment), independently per axis.
  bool snapToObjects = true;
  double gridMm = 5;

  void setShowGrid(bool value) {
    showGrid = value;
    notifyListeners();
  }

  void setSnapToGrid(bool value) {
    snapToGrid = value;
    notifyListeners();
  }

  void setSnapToObjects(bool value) {
    snapToObjects = value;
    notifyListeners();
  }

  void setGridMm(double value) {
    if (value <= 0) return;
    gridMm = value;
    notifyListeners();
  }

  /// Snaps a point being dragged, per axis: to an object (plate edge/centre,
  /// another hole or note) if one is within [toleranceMm], otherwise to the
  /// grid. [guideX]/[guideY] are set when that axis snapped to an object, so
  /// the screen can draw an alignment line. Pass the dragged item's id in
  /// [excludeHoleId]/[excludeNoteId] so it doesn't snap to itself; when
  /// dragging a note, the other notes are alignment targets too.
  ({Vec2 point, double? guideX, double? guideY}) snapDragPoint(
    Vec2 raw, {
    String? excludeHoleId,
    String? excludeNoteId,
    required double toleranceMm,
  }) {
    double? objX, objY;
    if (snapToObjects) {
      final xs = <double>[0, outlineWidth / 2, outlineWidth];
      final ys = <double>[0, outlineHeight / 2, outlineHeight];
      for (final h in holes) {
        if (h.id == excludeHoleId) continue;
        xs.add(h.x);
        ys.add(h.y);
      }
      if (excludeNoteId != null) {
        // A dragged multi-selection moves together, so none of it is a target.
        final moving = selectedNoteIds.contains(excludeNoteId) ? selectedNoteIds : {excludeNoteId};
        for (final n in notes) {
          if (moving.contains(n.id)) continue;
          xs.add(n.x);
          ys.add(n.y);
        }
      }
      double? nearest(List<double> candidates, double v) {
        double? best;
        var bestDist = toleranceMm;
        for (final c in candidates) {
          final d = (c - v).abs();
          if (d <= bestDist) {
            bestDist = d;
            best = c;
          }
        }
        return best;
      }

      objX = nearest(xs, raw.x);
      objY = nearest(ys, raw.y);
    }
    double onGrid(double v) => snapToGrid ? double.parse(((v / gridMm).round() * gridMm).toStringAsFixed(6)) : v;
    return (point: Vec2(objX ?? onGrid(raw.x), objY ?? onGrid(raw.y)), guideX: objX, guideY: objY);
  }

  /// Snaps [raw] (template mm) to a hole/slot center, a slot's rounded-end
  /// center, a point on the outline (edges, corners, fillet centers) or a
  /// corner of the reference image, within [toleranceMm].
  Vec2 snapMeasurePoint(Vec2 raw, double toleranceMm) {
    final entities = _plateEntities(_snapshotFields());
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
    if (value != TemplateCategory.box) {
      _setDualLayer(false);
    } else if (layer == TemplateMakerLayer.drawing) {
      layer = TemplateMakerLayer.layer1;
    }
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

  void addRect() {
    final hole = TemplateMakerHole(
      id: 'hole${_nextHoleSeq++}',
      x: outlineWidth / 2,
      y: outlineHeight / 2,
      shape: TemplateMakerHoleShape.rect,
      slotLength: 12,
      slotWidth: 8,
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

  /// The copy/paste clipboard. Shared by every Template Maker, so an item can
  /// be copied out of one template and pasted into another; only one of the two
  /// is ever set (the last thing copied).
  static TemplateMakerHole? _clipHole;
  static TemplateMakerNote? _clipNote;

  @visibleForTesting
  static void clearClipboard() {
    _clipHole = null;
    _clipNote = null;
  }

  /// Whether there is a selected hole/slot/rectangle (on a plate layer) or a
  /// selected note (on the drawing layer) to copy.
  bool get canCopy => layer == TemplateMakerLayer.drawing
      ? notes.any((n) => n.id == selectedNoteId)
      : holes.any((h) => h.id == selectedHoleId);

  /// Whether the clipboard holds something that belongs on the current layer:
  /// holes on a plate layer, notes on the drawing layer.
  bool get canPaste => layer == TemplateMakerLayer.drawing ? _clipNote != null : _clipHole != null;

  /// Copies the selected hole or note to the clipboard. False if none is selected.
  bool copySelection() {
    if (layer == TemplateMakerLayer.drawing) {
      final n = notes.where((e) => e.id == selectedNoteId).firstOrNull;
      if (n == null) return false;
      _clipNote = _noteCopy(n, 'clip', 0, 0);
      _clipHole = null;
      return true;
    }
    final h = holes.where((e) => e.id == selectedHoleId).firstOrNull;
    if (h == null) return false;
    _clipHole = TemplateMakerHole(
      id: 'clip',
      x: h.x,
      y: h.y,
      shape: h.shape,
      diameter: h.diameter,
      slotLength: h.slotLength,
      slotWidth: h.slotWidth,
      rotationDeg: h.rotationDeg,
    );
    _clipNote = null;
    return true;
  }

  /// Pastes the clipboard onto the current layer, at the copied position -- or
  /// nudged by [duplicateOffsetMm] steps until it no longer sits exactly on top
  /// of a matching item -- and selects it. Returns the new item's id, or null if
  /// the clipboard has nothing for this layer.
  String? paste() {
    if (layer == TemplateMakerLayer.drawing) {
      final clip = _clipNote;
      if (clip == null) return null;
      var d = 0.0;
      bool taken() => notes.any((n) => n.type == clip.type && (n.x - (clip.x + d)).abs() < 1e-6 && (n.y - (clip.y + d)).abs() < 1e-6);
      for (var i = 0; i < 1000 && taken(); i++) {
        d += duplicateOffsetMm;
      }
      final note = _noteCopy(clip, 'note${_nextNoteSeq++}', d, d);
      notes.add(note);
      selectedNoteId = note.id;
      notifyListeners();
      return note.id;
    }
    final clip = _clipHole;
    if (clip == null) return null;
    var d = 0.0;
    bool taken() => holes.any((h) => h.shape == clip.shape && (h.x - (clip.x + d)).abs() < 1e-6 && (h.y - (clip.y + d)).abs() < 1e-6);
    for (var i = 0; i < 1000 && taken(); i++) {
      d += duplicateOffsetMm;
    }
    final hole = _cloneHole(clip)
      ..x += d
      ..y += d;
    holes.add(hole);
    selectedHoleId = hole.id;
    notifyListeners();
    return hole.id;
  }

  TemplateMakerNote _noteCopy(TemplateMakerNote n, String id, double dx, double dy) => TemplateMakerNote(
        id: id,
        type: n.type,
        text: n.text,
        x: n.x + dx,
        y: n.y + dy,
        x2: n.x2 + dx,
        y2: n.y2 + dy,
        width: n.width,
        height: n.height,
        radius: n.radius,
        rotationDeg: n.rotationDeg,
      );

  /// How far (mm) a duplicate is nudged so it doesn't hide under the original.
  static const double duplicateOffsetMm = 5;

  /// Duplicates [holeId] on the current layer, nudged by [duplicateOffsetMm],
  /// and selects the copy (returned; null if [holeId] isn't found).
  TemplateMakerHole? duplicateHole(String holeId) {
    final i = holes.indexWhere((h) => h.id == holeId);
    if (i < 0) return null;
    final copy = _cloneHole(holes[i])
      ..x += duplicateOffsetMm
      ..y += duplicateOffsetMm;
    holes.insert(i + 1, copy);
    selectedHoleId = copy.id;
    notifyListeners();
    return copy;
  }

  /// Whether a hole/slot on the plate being edited can be copied to the other
  /// layer (a two-layer plate showing one of its two layers).
  bool get canCopyToOtherLayer => dualLayer && layer != TemplateMakerLayer.drawing && _stored != null;

  /// Copies [holeId] (same position and size) onto the other layer's plate.
  /// The current layer keeps its hole and the selection.
  void copyHoleToOtherLayer(String holeId) {
    if (!canCopyToOtherLayer) return;
    final hole = holes.where((h) => h.id == holeId).firstOrNull;
    if (hole == null) return;
    _stored!.holes.add(_cloneHole(hole));
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

  _Plate _snapshotFields() => _Plate(outlineWidth, outlineHeight, cornerStyle, cornerSize, holes);

  TemplateMakerHole _cloneHole(TemplateMakerHole h) => TemplateMakerHole(
        id: 'hole${_nextHoleSeq++}',
        x: h.x,
        y: h.y,
        shape: h.shape,
        diameter: h.diameter,
        slotLength: h.slotLength,
        slotWidth: h.slotWidth,
        rotationDeg: h.rotationDeg,
      );

  void _swapPlateFields() {
    final other = _stored!;
    final mine = _Plate(outlineWidth, outlineHeight, cornerStyle, cornerSize, List.of(holes));
    outlineWidth = other.outlineWidth;
    outlineHeight = other.outlineHeight;
    cornerStyle = other.cornerStyle;
    cornerSize = other.cornerSize;
    holes
      ..clear()
      ..addAll(other.holes);
    _stored = mine;
    _fieldsAreLayer2 = !_fieldsAreLayer2;
    selectedHoleId = null;
  }

  void _setDualLayer(bool on) {
    if (on == dualLayer) return;
    if (on) {
      final mine = _snapshotFields();
      _stored = _Plate(mine.outlineWidth, mine.outlineHeight, mine.cornerStyle, mine.cornerSize, [for (final h in holes) _cloneHole(h)]);
      dualLayer = true;
      _fieldsAreLayer2 = false;
    } else {
      if (_fieldsAreLayer2) _swapPlateFields();
      _stored = null;
      dualLayer = false;
      if (layer == TemplateMakerLayer.layer2) layer = TemplateMakerLayer.layer1;
    }
  }

  /// Turns the two-layer plate on (layer 2 starts as a copy of layer 1) or
  /// off (layer 2 is discarded).
  void setDualLayer(bool on) {
    if (category != TemplateCategory.box && on) return;
    _setDualLayer(on);
    notifyListeners();
  }

  /// Shows one layer at a time. The fields always hold the plate for the
  /// layer being viewed; the drawing layer sits over plate 1's coordinates.
  void selectLayer(TemplateMakerLayer value) {
    if (value == TemplateMakerLayer.layer2 && !dualLayer) return;
    if (value == TemplateMakerLayer.drawing && category == TemplateCategory.box) return;
    final wantLayer2 = value == TemplateMakerLayer.layer2;
    if (dualLayer && wantLayer2 != _fieldsAreLayer2) _swapPlateFields();
    layer = value;
    selectedHoleId = null;
    selectedNoteId = null;
    notifyListeners();
  }

  TemplateMakerNote addNote(AnnotationType type) {
    final cx = outlineWidth / 2, cy = outlineHeight / 2;
    final note = TemplateMakerNote(
      id: 'note${_nextNoteSeq++}',
      type: type,
      text: type == AnnotationType.text ? 'Note' : '',
      x: type == AnnotationType.line ? cx - 10 : cx,
      y: cy,
      x2: cx + 10,
      y2: cy,
      width: 20,
      height: type == AnnotationType.text ? 5 : 10,
      radius: 5,
    );
    notes.add(note);
    selectedNoteId = note.id;
    notifyListeners();
    return note;
  }

  /// Adds a zero-size note anchored at [p] (a line's start, a rectangle's or
  /// text box's corner, a circle's centre) and selects it, ready to be sized
  /// by dragging a handle.
  TemplateMakerNote addNoteAt(AnnotationType type, Vec2 p) {
    final note = TemplateMakerNote(
      id: 'note${_nextNoteSeq++}',
      type: type,
      text: type == AnnotationType.text ? 'Text' : '',
      x: p.x,
      y: p.y,
      x2: p.x,
      y2: p.y,
      width: _minNoteSizeMm,
      height: _minNoteSizeMm,
      radius: _minNoteSizeMm,
    );
    notes.add(note);
    selectedNoteId = note.id;
    notifyListeners();
    return note;
  }

  /// Duplicates a drawing-layer note, nudged by [duplicateOffsetMm], and
  /// selects the copy (returned; null if [noteId] isn't found).
  TemplateMakerNote? duplicateNote(String noteId) {
    final i = notes.indexWhere((n) => n.id == noteId);
    if (i < 0) return null;
    final n = notes[i];
    final copy = TemplateMakerNote(
      id: 'note${_nextNoteSeq++}',
      type: n.type,
      text: n.text,
      x: n.x + duplicateOffsetMm,
      y: n.y + duplicateOffsetMm,
      x2: n.x2 + duplicateOffsetMm,
      y2: n.y2 + duplicateOffsetMm,
      width: n.width,
      height: n.height,
      radius: n.radius,
      rotationDeg: n.rotationDeg,
    );
    notes.insert(i + 1, copy);
    selectedNoteId = copy.id;
    notifyListeners();
    return copy;
  }

  void removeNote(String noteId) {
    notes.removeWhere((n) => n.id == noteId);
    _dropFromSelection({noteId});
    notifyListeners();
  }

  void _dropFromSelection(Set<String> ids) {
    selectedNoteIds.removeAll(ids);
    if (ids.contains(_primaryNoteId)) _primaryNoteId = selectedNoteIds.lastOrNull;
  }

  void selectNote(String? noteId) {
    if (selectedNoteId == noteId && selectedNoteIds.length <= 1) return;
    selectedNoteId = noteId;
    notifyListeners();
  }

  /// Adds [noteId] to the selection, or removes it if already selected
  /// (Shift/Ctrl+click).
  void toggleNoteSelection(String noteId) {
    if (selectedNoteIds.contains(noteId)) {
      _dropFromSelection({noteId});
    } else {
      selectedNoteIds.add(noteId);
      _primaryNoteId = noteId;
    }
    notifyListeners();
  }

  /// Makes exactly [ids] the selection.
  void setSelectedNotes(Set<String> ids) {
    if (ids.length == selectedNoteIds.length && ids.containsAll(selectedNoteIds)) return;
    selectedNoteIds
      ..clear()
      ..addAll(ids);
    if (!ids.contains(_primaryNoteId)) _primaryNoteId = ids.lastOrNull;
    notifyListeners();
  }

  void selectAllNotes() => setSelectedNotes({for (final n in notes) n.id});

  /// Removes every selected note; returns how many were removed.
  int deleteSelectedNotes() {
    final ids = {...selectedNoteIds};
    if (ids.isEmpty) return 0;
    notes.removeWhere((n) => ids.contains(n.id));
    selectedNoteId = null;
    notifyListeners();
    return ids.length;
  }

  /// Moves every selected note by ([dx], [dy]) mm.
  void moveSelectedNotesBy(double dx, double dy) {
    for (final n in notes) {
      if (!selectedNoteIds.contains(n.id)) continue;
      n.x += dx;
      n.y += dy;
      n.x2 += dx;
      n.y2 += dy;
    }
    notifyListeners();
  }

  /// The ids of the notes touching the rectangle [r] (template mm), for a
  /// drag-selection box.
  Set<String> notesInRect(ui.Rect r) {
    bool segmentHits(Vec2 a, Vec2 b) {
      // Liang-Barsky clip of the segment against the rectangle.
      var t0 = 0.0, t1 = 1.0;
      final dx = b.x - a.x, dy = b.y - a.y;
      bool clip(double p, double q) {
        if (p == 0) return q >= 0;
        final t = q / p;
        if (p < 0) {
          if (t > t1) return false;
          if (t > t0) t0 = t;
        } else {
          if (t < t0) return false;
          if (t < t1) t1 = t;
        }
        return true;
      }

      return clip(-dx, a.x - r.left) && clip(dx, r.right - a.x) && clip(-dy, a.y - r.top) && clip(dy, r.bottom - a.y);
    }

    bool boxHits(double minX, double minY, double maxX, double maxY) =>
        maxX >= r.left && minX <= r.right && maxY >= r.top && minY <= r.bottom;

    // Rect's top/bottom are the min/max y here (template mm, not screen).
    return {
      for (final n in notes)
        if (switch (n.type) {
          AnnotationType.line => segmentHits(Vec2(n.x, n.y), Vec2(n.x2, n.y2)),
          AnnotationType.rect => boxHits(n.x, n.y, n.x + n.width, n.y + n.height),
          AnnotationType.circle => () {
              final cx = n.x.clamp(r.left, r.right), cy = n.y.clamp(r.top, r.bottom);
              return math.pow(n.x - cx, 2) + math.pow(n.y - cy, 2) <= n.radius * n.radius;
            }(),
          AnnotationType.text => () {
              final w = noteTextWidthMm(n);
              final corners = [Vec2(0, 0), Vec2(w, 0), Vec2(w, n.height), Vec2(0, n.height)]
                  .map((c) => c.rotated(n.rotationDeg).add(Vec2(n.x, n.y)));
              final xs = corners.map((c) => c.x), ys = corners.map((c) => c.y);
              return boxHits(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
            }(),
        })
          n.id,
    };
  }

  void updateNote(
    String noteId, {
    String? text,
    double? x,
    double? y,
    double? x2,
    double? y2,
    double? width,
    double? height,
    double? radius,
    double? rotationDeg,
  }) {
    for (final n in notes) {
      if (n.id != noteId) continue;
      if (text != null) n.text = text;
      if (x != null) n.x = x;
      if (y != null) n.y = y;
      if (x2 != null) n.x2 = x2;
      if (y2 != null) n.y2 = y2;
      if (width != null && width > 0) n.width = width;
      if (height != null && height > 0) n.height = height;
      if (radius != null && radius > 0) n.radius = radius;
      if (rotationDeg != null) n.rotationDeg = rotationDeg;
      break;
    }
    notifyListeners();
  }

  static const _minHoleSizeMm = 0.2;

  /// The drag handles of [h], in template mm: a round hole's radius (its east
  /// point), a slot's four edge midpoints (length and width) and a rectangle's
  /// four corners. They follow the hole's rotation.
  List<({HoleHandle handle, Vec2 point})> holeHandles(TemplateMakerHole h) {
    Vec2 at(double lx, double ly) => Vec2(lx, ly).rotated(h.rotationDeg).add(Vec2(h.x, h.y));
    final hl = h.slotLength / 2, hw = h.slotWidth / 2;
    return switch (h.shape) {
      TemplateMakerHoleShape.round => [(handle: HoleHandle.radius, point: at(h.diameter / 2, 0))],
      TemplateMakerHoleShape.slot => [
          (handle: HoleHandle.lengthPos, point: at(hl, 0)),
          (handle: HoleHandle.lengthNeg, point: at(-hl, 0)),
          (handle: HoleHandle.widthPos, point: at(0, hw)),
          (handle: HoleHandle.widthNeg, point: at(0, -hw)),
        ],
      TemplateMakerHoleShape.rect => [
          (handle: HoleHandle.cornerNE, point: at(hl, hw)),
          (handle: HoleHandle.cornerNW, point: at(-hl, hw)),
          (handle: HoleHandle.cornerSW, point: at(-hl, -hw)),
          (handle: HoleHandle.cornerSE, point: at(hl, -hw)),
        ],
    };
  }

  /// Drags [handle] of hole [holeId] to [mm]. The hole's centre stays put and
  /// it grows or shrinks symmetrically, measured in its own rotated frame.
  void dragHoleHandle(String holeId, HoleHandle handle, Vec2 mm) {
    final h = holes.where((e) => e.id == holeId).firstOrNull;
    if (h == null) return;
    final local = mm.subtract(Vec2(h.x, h.y)).rotated(-h.rotationDeg);
    double size(double halfExtent) => math.max(2 * halfExtent.abs(), _minHoleSizeMm);
    switch (handle) {
      case HoleHandle.radius:
        h.diameter = size(math.sqrt(local.x * local.x + local.y * local.y));
      case HoleHandle.lengthPos || HoleHandle.lengthNeg:
        h.slotLength = size(local.x);
      case HoleHandle.widthPos || HoleHandle.widthNeg:
        h.slotWidth = size(local.y);
      case HoleHandle.cornerNE || HoleHandle.cornerNW || HoleHandle.cornerSW || HoleHandle.cornerSE:
        h.slotLength = size(local.x);
        h.slotWidth = size(local.y);
    }
    notifyListeners();
  }

  static const _minNoteSizeMm = 0.1;
  static const _minTextHeightMm = 0.5;

  /// The drag handles of [n], in template mm: a line's two ends, a
  /// rectangle's four corners, a circle's radius (its east point) and a text
  /// note's size (the right end of its baseline).
  List<({NoteHandle handle, Vec2 point})> noteHandles(TemplateMakerNote n) => switch (n.type) {
        AnnotationType.line => [
            (handle: NoteHandle.start, point: Vec2(n.x, n.y)),
            (handle: NoteHandle.end, point: Vec2(n.x2, n.y2)),
          ],
        AnnotationType.rect => [
            (handle: NoteHandle.cornerSW, point: Vec2(n.x, n.y)),
            (handle: NoteHandle.cornerSE, point: Vec2(n.x + n.width, n.y)),
            (handle: NoteHandle.cornerNW, point: Vec2(n.x, n.y + n.height)),
            (handle: NoteHandle.cornerNE, point: Vec2(n.x + n.width, n.y + n.height)),
          ],
        AnnotationType.circle => [(handle: NoteHandle.radius, point: Vec2(n.x + n.radius, n.y))],
        AnnotationType.text => [
            (handle: NoteHandle.textSize, point: Vec2(noteTextWidthMm(n), 0).rotated(n.rotationDeg).add(Vec2(n.x, n.y))),
          ],
      };

  /// The corner of a rectangle note that stays put while its [handle] corner
  /// is dragged (the opposite one).
  Vec2 noteRectFixedCorner(TemplateMakerNote n, NoteHandle handle) => switch (handle) {
        NoteHandle.cornerSW => Vec2(n.x + n.width, n.y + n.height),
        NoteHandle.cornerSE => Vec2(n.x, n.y + n.height),
        NoteHandle.cornerNW => Vec2(n.x + n.width, n.y),
        NoteHandle.cornerNE => Vec2(n.x, n.y),
        _ => Vec2(n.x, n.y),
      };

  /// Drags [handle] of note [noteId] to [mm]: moves a line end, resizes a
  /// rectangle about the opposite corner [fixed] (captured when the drag
  /// started, so dragging past it just flips the rectangle), sets a circle's
  /// radius, or scales a text note so its baseline ends at [mm].
  void dragNoteHandle(String noteId, NoteHandle handle, Vec2 mm, {Vec2? fixed}) {
    final n = notes.where((e) => e.id == noteId).firstOrNull;
    if (n == null) return;
    switch (handle) {
      case NoteHandle.start:
        n.x = mm.x;
        n.y = mm.y;
      case NoteHandle.end:
        n.x2 = mm.x;
        n.y2 = mm.y;
      case NoteHandle.cornerSW || NoteHandle.cornerSE || NoteHandle.cornerNW || NoteHandle.cornerNE:
        final f = fixed ?? noteRectFixedCorner(n, handle);
        n.x = math.min(mm.x, f.x);
        n.y = math.min(mm.y, f.y);
        n.width = math.max((mm.x - f.x).abs(), _minNoteSizeMm);
        n.height = math.max((mm.y - f.y).abs(), _minNoteSizeMm);
      case NoteHandle.radius:
        n.radius = math.max(math.sqrt(math.pow(mm.x - n.x, 2) + math.pow(mm.y - n.y, 2)), _minNoteSizeMm);
      case NoteHandle.textSize:
        final local = mm.subtract(Vec2(n.x, n.y)).rotated(-n.rotationDeg);
        n.height = math.max(local.x / (math.max(n.text.length, 1) * 0.6), _minTextHeightMm);
    }
    notifyListeners();
  }

  /// Sizes a text note to a box dragged from [anchor] to [mm]: the text sits
  /// at the box's bottom-left and is as tall as fits inside it (limited by the
  /// box height and by its estimated width, see [noteTextWidthMm]).
  void dragNoteTextBox(String noteId, Vec2 anchor, Vec2 mm) {
    final n = notes.where((e) => e.id == noteId).firstOrNull;
    if (n == null || n.type != AnnotationType.text) return;
    final w = (mm.x - anchor.x).abs(), h = (mm.y - anchor.y).abs();
    n.x = math.min(mm.x, anchor.x);
    n.y = math.min(mm.y, anchor.y);
    n.rotationDeg = 0;
    n.height = math.max(math.min(h, w / (math.max(n.text.length, 1) * 0.6)), _minTextHeightMm);
    notifyListeners();
  }

  /// Moves a whole note by ([dx], [dy]) mm (a line moves both ends).
  void moveNoteBy(String noteId, double dx, double dy) {
    for (final n in notes) {
      if (n.id != noteId) continue;
      n.x += dx;
      n.y += dy;
      n.x2 += dx;
      n.y2 += dy;
      break;
    }
    notifyListeners();
  }

  void newTemplate() {
    _stored = null;
    dualLayer = false;
    _fieldsAreLayer2 = false;
    layer = TemplateMakerLayer.layer1;
    notes.clear();
    selectedNoteId = null;
    _nextNoteSeq = 1;
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
    final current = _snapshotFields();
    var layer1 = _plateEntities(current);
    List<DxfEntity>? layer2;
    final other = _stored;
    if (dualLayer && other != null) {
      final otherEntities = _plateEntities(other);
      if (_fieldsAreLayer2) {
        layer2 = layer1;
        layer1 = otherEntities;
      } else {
        layer2 = otherEntities;
      }
    }
    return ControllerTemplate(
      id: id,
      name: name,
      entities: layer1,
      source: TemplateSource.imported,
      category: category,
      annotations: [for (final n in notes) n.toAnnotation()],
      layer2Entities: layer2,
    );
  }

  List<DxfEntity> _plateEntities(_Plate plate) {
    final size = plate.cornerSize <= 0 ? 0.0 : math.min(plate.cornerSize, math.min(plate.outlineWidth, plate.outlineHeight) / 2);
    final List<PolyVertex> vertices;
    if (size <= 0) {
      vertices = [
        const PolyVertex(Vec2(0, 0)),
        PolyVertex(Vec2(plate.outlineWidth, 0)),
        PolyVertex(Vec2(plate.outlineWidth, plate.outlineHeight)),
        PolyVertex(Vec2(0, plate.outlineHeight)),
      ];
    } else {
      switch (plate.cornerStyle) {
        case TemplateMakerCornerStyle.cornerCut:
          vertices = notchedRectVertices(plate.outlineWidth, plate.outlineHeight, size);
          break;
        case TemplateMakerCornerStyle.chamfer:
          vertices = chamferedRectVertices(plate.outlineWidth, plate.outlineHeight, size);
          break;
        case TemplateMakerCornerStyle.fillet:
          vertices = [
            PolyVertex(Vec2(size, 0)),
            PolyVertex(Vec2(plate.outlineWidth - size, 0), bulge: _bulge90),
            PolyVertex(Vec2(plate.outlineWidth, size)),
            PolyVertex(Vec2(plate.outlineWidth, plate.outlineHeight - size), bulge: _bulge90),
            PolyVertex(Vec2(plate.outlineWidth - size, plate.outlineHeight)),
            PolyVertex(Vec2(size, plate.outlineHeight), bulge: _bulge90),
            PolyVertex(Vec2(0, plate.outlineHeight - size)),
            PolyVertex(Vec2(0, size), bulge: _bulge90),
          ];
          break;
      }
    }
    return <DxfEntity>[
      DxfPolyline(vertices, closed: true),
      for (final h in plate.holes)
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
    holes.clear();
    selectedHoleId = null;
    _nextHoleSeq = 1;
    _stored = null;
    dualLayer = false;
    _fieldsAreLayer2 = false;
    layer = TemplateMakerLayer.layer1;

    // Layer 2 first (parked afterwards), so layer 1 ends up in the fields.
    final layer2 = template.layer2Entities;
    if (layer2 != null && layer2.isNotEmpty) {
      _loadPlateFields(layer2);
      _stored = _snapshotFields();
      _stored = _Plate(_stored!.outlineWidth, _stored!.outlineHeight, _stored!.cornerStyle, _stored!.cornerSize, List.of(holes));
      dualLayer = true;
    }
    _loadPlateFields(template.entities);

    notes.clear();
    selectedNoteId = null;
    _nextNoteSeq = 1;
    for (final a in template.annotations) {
      notes.add(TemplateMakerNote.fromAnnotation('note${_nextNoteSeq++}', a));
    }
    notifyListeners();
  }

  void _loadPlateFields(List<DxfEntity> entities) {
    BoundingBox? largest;
    var largestArea = 0.0;
    for (final e in entities) {
      final b = e.boundingBox;
      if (b.width * b.height > largestArea) {
        largestArea = b.width * b.height;
        largest = b;
      }
    }
    bool isHole(DxfEntity e) => _looksLikeHole(e) || (largest != null && _isInnerRect(e, largest));

    final outlineEntities = entities.where((e) => !isHole(e)).toList();
    // If literally everything looked like a hole (shouldn't happen for a
    // real template), fall back to treating every entity as outline
    // material instead of showing an empty 0x0 outline.
    final outlineSource = outlineEntities.isEmpty ? entities : outlineEntities;

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
    // In the fallback case above (nothing looked like a hole) there's
    // nothing left to extract as a hole either.
    final holeSource = outlineEntities.isEmpty ? const <DxfEntity>[] : entities.where(isHole);
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
  }
}
