import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../dxf/dxf_parser.dart';
import '../models/annotation.dart';
import '../models/controller_template.dart';
import '../models/vec2.dart';
import '../services/file_io.dart';
import '../services/simple_math.dart';
import '../services/template_library.dart';
import '../widgets/app_colors.dart';
import 'template_maker_controller.dart';
import 'template_outline_painter.dart';

const double _outlinePreviewMargin = 32.0;

/// Extra space shown around the plate (at least this many mm, or this fraction
/// of its larger side), so items can be dragged partly off the plate.
const double _offPlateMinMm = 10.0;
const double _offPlateFraction = 0.1;
const double _holeDragHitPx = 14.0;
const double _imageHandleHitPx = 12.0;

enum _ImageDrag { none, move, corner }

// The repo the "Open PR on GitHub" button contributes a template to --
// same one loadRemoteDefaults() (see template_library.dart) fetches
// bundled templates from.
const String _githubRepoOwner = 'computergeek1507';
const String _githubRepoName = 'box_design_flutter';

// GitHub's own "create new file" page (the target of the URL below) has no
// documented length limit, but very long URLs risk being rejected by the
// browser or GitHub's server before the page even loads -- comfortably
// under that keeps every template this tool can produce well clear of it.
const int _githubPrUrlWarnLength = 6000;

/// A standalone screen for building a [ControllerTemplate] by hand: an
/// outline rectangle sized by width/height fields, plus a list of round
/// holes each given a diameter and X/Y position. Loads and exports the same
/// JSON template format the rest of the app reads, so a file made here can
/// be dropped straight into `assets/templates/` or imported. When opened
/// with a [library] (the running app's live template set), "Add to
/// Library" drops the template straight into it with no file round-trip.
class TemplateMakerScreen extends StatefulWidget {
  final TemplateLibrary? library;

  /// When set, the screen opens pre-loaded with this template's geometry
  /// instead of a blank one -- used to re-edit an existing user-made
  /// template from the palette.
  final ControllerTemplate? initialTemplate;

  const TemplateMakerScreen({super.key, this.library, this.initialTemplate});

  @override
  State<TemplateMakerScreen> createState() => _TemplateMakerScreenState();
}

class _TemplateMakerScreenState extends State<TemplateMakerScreen> {
  final _controller = TemplateMakerController();
  String? _draggingHoleId;
  _ImageDrag _imageDrag = _ImageDrag.none;
  Rect? _frozenView;
  Vec2? _measureHover;
  String? _draggingNoteId;

  /// The shape armed on the drawing layer: dragging on the canvas draws a new
  /// one of this type. Null means dragging selects/moves existing notes.
  AnnotationType? _drawTool;

  /// The note being created by the current draw-tool drag.
  String? _creatingNoteId;

  /// While true, clicking the canvas (on a plate layer with a custom
  /// outline) appends a new outline point instead of selecting/dragging.
  bool _addingOutlinePoint = false;

  /// The custom outline point index being dragged (placed or moved), if any.
  int? _draggingOutlinePointIndex;

  /// While dragging an existing outline point with Shift held, the drag
  /// grows the point's fillet/chamfer size instead of moving it -- these
  /// record where that drag started and the size it started from.
  Vec2? _outlinePointResizeStart;
  double _outlinePointResizeBaseSize = 0;

  /// Where an outline-point drag started, until it has moved past
  /// [_outlinePointDragDeadZonePx].
  Offset? _outlinePointDragStartPx;
  static const _outlinePointDragDeadZonePx = 4.0;
  /// For detecting a double-click on the outline (not on an existing point)
  /// to insert a new point there, mirroring the note double-click detector
  /// below but for the plate layer.
  DateTime _lastPlateTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  Vec2? _lastPlateTapMm;

  /// Canvas zoom (1 = the whole plate fits) and how far the view centre has
  /// been panned from the plate's centre, in mm.
  /// The canvas size from the latest layout, for keyboard zoom.
  Size? _canvasSize;

  double _zoom = 1;
  Vec2 _panMm = const Vec2(0, 0);
  static const double _minZoom = 0.25, _maxZoom = 40;

  /// A drag-selection box being dragged on empty canvas (template mm), and
  /// the notes that were already selected when it started (kept when the
  /// box is dragged with Shift/Ctrl held).
  Vec2? _marqueeStart;
  Vec2? _marqueeEnd;
  Set<String> _marqueeBase = {};

  /// Set on pressing a note that is part of a multi-selection: a plain click
  /// (no drag) narrows the selection to it, but a drag moves them all.
  String? _collapseToNoteId;

  bool get _additiveKey {
    final k = HardwareKeyboard.instance;
    return k.isShiftPressed || k.isControlPressed || k.isMetaPressed;
  }

  /// The text note being edited in place on the canvas (double-click), the
  /// text it had before, and the field that edits it.
  String? _editingNoteId;
  String _editingOriginalText = '';
  final _canvasTextController = TextEditingController();
  late final FocusNode _canvasTextFocus = FocusNode(
    debugLabel: 'canvas text edit',
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        _endTextEdit(cancel: true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );

  /// The previous canvas tap, to recognise a double-click without a
  /// double-tap recognizer (which would delay every single tap).
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastTapNoteId;

  /// The handle of the selected note being dragged (resize / move an end), and
  /// for a rectangle the corner that stays put.
  NoteHandle? _noteHandle;

  /// Receives Ctrl/Cmd+C and Ctrl/Cmd+V for the whole screen (see [_onKey]).
  final FocusNode _keyFocus = FocusNode(debugLabel: 'template maker shortcuts');

  /// The handle of the selected hole being dragged (resize).
  HoleHandle? _holeHandle;
  Vec2? _noteHandleFixed;
  Vec2 _lastNoteMm = const Vec2(0, 0);

  /// Where the dragged note would be with no snapping (its anchor), so
  /// snapping doesn't lose the pointer's real movement.
  Vec2 _noteRawAnchor = const Vec2(0, 0);

  /// Alignment guides (template mm) while a drag is snapped to an object.
  double? _guideX;
  double? _guideY;
  final Map<String, TextEditingController> _noteFields = {};
  final Map<String, GlobalKey> _holeRowKeys = {};

  /// While true the Id follows the Name (slugified); typing in the Id field
  /// itself turns it off. Starts on only if the loaded Id already matches its
  /// Name's slug.
  bool _idAuto = true;
  Vec2 _imageDragFixed = const Vec2(0, 0);
  Vec2 _imageGrabOffset = const Vec2(0, 0);

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTemplate;
    if (initial != null) {
      _controller.loadFromTemplate(initial);
      _resetIdAuto();
    }
  }

  void _resetIdAuto() => _idAuto = _controller.id == _slugify(_controller.name);

  late final _idController = TextEditingController(text: _controller.id);
  late final _nameController = TextEditingController(text: _controller.name);
  late final _widthController = TextEditingController(text: _fmt(_controller.outlineWidth));
  late final _heightController = TextEditingController(text: _fmt(_controller.outlineHeight));
  late final _cornerSizeController = TextEditingController(text: _fmt(_controller.cornerSize));
  final _widthFocus = FocusNode();
  final _heightFocus = FocusNode();
  final _cornerSizeFocus = FocusNode();

  final _outlinePointXController = TextEditingController();
  final _outlinePointYController = TextEditingController();
  final _outlinePointSizeController = TextEditingController();
  final _outlinePointXFocus = FocusNode();
  final _outlinePointYFocus = FocusNode();
  final _outlinePointSizeFocus = FocusNode();

  final _shiftDistanceController = TextEditingController(text: '1');

  final _imageXController = TextEditingController(text: '0.0');
  final _imageYController = TextEditingController(text: '0.0');
  final _imageWController = TextEditingController(text: '0.0');
  final _imageHController = TextEditingController(text: '0.0');
  final _imageXFocus = FocusNode();
  final _imageYFocus = FocusNode();
  final _imageWFocus = FocusNode();
  final _imageHFocus = FocusNode();

  final Map<String, TextEditingController> _holeX = {};
  final Map<String, TextEditingController> _holeY = {};
  final Map<String, TextEditingController> _holeD = {};
  final Map<String, TextEditingController> _holeLen = {};
  final Map<String, TextEditingController> _holeWidth = {};
  final Map<String, TextEditingController> _holeRotation = {};
  final Map<String, FocusNode> _holeXFocus = {};
  final Map<String, FocusNode> _holeYFocus = {};
  final Map<String, FocusNode> _holeDFocus = {};
  final Map<String, FocusNode> _holeLenFocus = {};
  final Map<String, FocusNode> _holeWidthFocus = {};
  final Map<String, FocusNode> _holeRotationFocus = {};

  /// Re-parses [controller]'s current text as a (possibly math-expression)
  /// number and, if valid, applies it via [onCommit] and rewrites the field
  /// to show the plain computed result -- so typing "55-23" and pressing
  /// Enter or clicking away leaves "32.0" in the field instead of the raw
  /// expression. Invalid/incomplete text is left alone (the model already
  /// holds whatever the last valid keystroke committed via onChanged).
  void _commitMathField(TextEditingController controller, void Function(double value) onCommit) {
    final value = tryEvalMath(controller.text);
    if (value == null) return;
    setState(() {
      onCommit(value);
      controller.text = _fmt(value);
    });
  }

  String _fmt(double v) => v.toStringAsFixed(1);

  String _slugify(String name) {
    final slug = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '').toLowerCase();
    return slug.isEmpty ? 'template' : slug;
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _cornerSizeController.dispose();
    _outlinePointXController.dispose();
    _outlinePointYController.dispose();
    _outlinePointSizeController.dispose();
    _shiftDistanceController.dispose();
    for (final c in [_imageXController, _imageYController, _imageWController, _imageHController]) {
      c.dispose();
    }
    for (final f in [_imageXFocus, _imageYFocus, _imageWFocus, _imageHFocus]) {
      f.dispose();
    }
    _controller.refImage?.dispose();
    _controller.refImage = null;
    for (final c in _noteFields.values) {
      c.dispose();
    }
    _widthFocus.dispose();
    _heightFocus.dispose();
    _cornerSizeFocus.dispose();
    _outlinePointXFocus.dispose();
    _outlinePointYFocus.dispose();
    _outlinePointSizeFocus.dispose();
    for (final c in [
      ..._holeX.values,
      ..._holeY.values,
      ..._holeD.values,
      ..._holeLen.values,
      ..._holeWidth.values,
      ..._holeRotation.values,
    ]) {
      c.dispose();
    }
    _keyFocus.dispose();
    _canvasTextController.dispose();
    _canvasTextFocus.dispose();
    for (final f in [
      ..._holeXFocus.values,
      ..._holeYFocus.values,
      ..._holeDFocus.values,
      ..._holeLenFocus.values,
      ..._holeWidthFocus.values,
      ..._holeRotationFocus.values,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  void _syncHoleControllers() {
    final liveIds = _controller.holes.map((h) => h.id).toSet();
    for (final map in [_holeX, _holeY, _holeD, _holeLen, _holeWidth, _holeRotation]) {
      map.removeWhere((id, c) {
        final stale = !liveIds.contains(id);
        if (stale) c.dispose();
        return stale;
      });
    }
    for (final map in [_holeXFocus, _holeYFocus, _holeDFocus, _holeLenFocus, _holeWidthFocus, _holeRotationFocus]) {
      map.removeWhere((id, f) {
        final stale = !liveIds.contains(id);
        if (stale) f.dispose();
        return stale;
      });
    }
    for (final h in _controller.holes) {
      _holeX.putIfAbsent(h.id, () => TextEditingController(text: _fmt(h.x)));
      _holeY.putIfAbsent(h.id, () => TextEditingController(text: _fmt(h.y)));
      _holeD.putIfAbsent(h.id, () => TextEditingController(text: _fmt(h.diameter)));
      _holeLen.putIfAbsent(h.id, () => TextEditingController(text: _fmt(h.slotLength)));
      _holeWidth.putIfAbsent(h.id, () => TextEditingController(text: _fmt(h.slotWidth)));
      _holeRotation.putIfAbsent(h.id, () => TextEditingController(text: _fmt(h.rotationDeg)));
      _holeXFocus.putIfAbsent(h.id, () => FocusNode());
      _holeYFocus.putIfAbsent(h.id, () => FocusNode());
      _holeDFocus.putIfAbsent(h.id, () => FocusNode());
      _holeLenFocus.putIfAbsent(h.id, () => FocusNode());
      _holeWidthFocus.putIfAbsent(h.id, () => FocusNode());
      _holeRotationFocus.putIfAbsent(h.id, () => FocusNode());
    }
  }

  void _refreshImageFields() {
    _imageXController.text = _fmt(_controller.imageX);
    _imageYController.text = _fmt(_controller.imageY);
    _imageWController.text = _fmt(_controller.imageWidth);
    _imageHController.text = _fmt(_controller.imageHeight);
  }

  void _refreshTopFields() {
    _idController.text = _controller.id;
    _nameController.text = _controller.name;
    _widthController.text = _fmt(_controller.outlineWidth);
    _heightController.text = _fmt(_controller.outlineHeight);
    _cornerSizeController.text = _fmt(_controller.cornerSize);
    for (final h in _controller.holes) {
      _holeX[h.id]?.text = _fmt(h.x);
      _holeY[h.id]?.text = _fmt(h.y);
      _holeD[h.id]?.text = _fmt(h.diameter);
      _holeLen[h.id]?.text = _fmt(h.slotLength);
      _holeWidth[h.id]?.text = _fmt(h.slotWidth);
      _holeRotation[h.id]?.text = _fmt(h.rotationDeg);
    }
    _refreshOutlinePointFields();
  }

  /// Syncs the selected outline point's X/Y/Size fields to its current
  /// values -- called whenever the selection changes or the point moves
  /// (by drag or by typing in these fields themselves), so the fields never
  /// show a stale position.
  void _refreshOutlinePointFields() {
    final index = _controller.selectedOutlinePointIndex;
    final points = _controller.customOutlinePoints;
    if (index == null || index < 0 || index >= points.length) return;
    final point = points[index];
    _outlinePointXController.text = _fmt(point.position.x);
    _outlinePointYController.text = _fmt(point.position.y);
    _outlinePointSizeController.text = _fmt(point.size);
  }

  /// Mirrors [TemplateOutlinePainter]'s scale-to-fit transform so pointer
  /// positions in the preview can be mapped back to template mm-space.
  /// The mm region the preview frames: the outline plus, when loaded, the
  /// reference image -- so a large image (and its scale handles) always stays
  /// on screen. Held fixed while a drag is in progress so the view doesn't
  /// rescale under the pointer.
  Rect _currentView() {
    final frozen = _frozenView;
    if (frozen != null) return frozen;
    final base = _baseView();
    if (_zoom == 1 && _panMm.x == 0 && _panMm.y == 0) return base;
    return Rect.fromCenter(
      center: base.center + Offset(_panMm.x, _panMm.y),
      width: base.width / _zoom,
      height: base.height / _zoom,
    );
  }

  /// The whole-plate framing at zoom 1 (see [_currentView]).
  Rect _baseView() {
    final c = _controller;
    var left = 0.0, bottom = 0.0, right = c.outlineWidth, top = c.outlineHeight;
    if (c.refImage != null) {
      left = math.min(left, c.imageX);
      bottom = math.min(bottom, c.imageY);
      right = math.max(right, c.imageX + c.imageWidth);
      top = math.max(top, c.imageY + c.imageHeight);
    }
    // Leave room beyond the plate so items can be dragged a little off it and
    // still be seen and grabbed.
    final pad = math.max(_offPlateMinMm, _offPlateFraction * math.max(right - left, top - bottom));
    return Rect.fromLTRB(left - pad, bottom - pad, right + pad, top + pad);
  }

  /// Zooms by [factor] keeping the mm point under [anchorPx] (canvas-local
  /// pixels) where it is -- the cursor for the wheel, the centre for buttons.
  void _zoomBy(double factor, Offset anchorPx, Size size) {
    final newZoom = (_zoom * factor).clamp(_minZoom, _maxZoom).toDouble();
    if (newZoom == _zoom) return;
    final before = _previewPxToMm(anchorPx, size);
    setState(() {
      _zoom = newZoom;
      final after = _previewPxToMm(anchorPx, size);
      _panMm = Vec2(_panMm.x + before.x - after.x, _panMm.y + before.y - after.y);
    });
  }

  void _zoomFit() => setState(() {
        _zoom = 1;
        _panMm = const Vec2(0, 0);
      });

  /// Pans the view by a pointer movement of [deltaPx] (the content follows the mouse).
  void _panViewBy(Offset deltaPx, Size size) {
    final scale = _previewScale(size);
    setState(() => _panMm = Vec2(_panMm.x - deltaPx.dx / scale, _panMm.y + deltaPx.dy / scale));
  }

  double _previewScale(Size size) {
    final availableW = size.width - _outlinePreviewMargin * 2;
    final availableH = size.height - _outlinePreviewMargin * 2;
    if (availableW <= 0 || availableH <= 0) return 1;
    final view = _currentView();
    return math.min(availableW / view.width, availableH / view.height);
  }

  Offset _previewOrigin(Size size, double scale) {
    final view = _currentView();
    return Offset(
      (size.width - view.width * scale) / 2,
      (size.height - view.height * scale) / 2,
    );
  }

  Vec2 _previewPxToMm(Offset localPx, Size size) {
    final scale = _previewScale(size);
    final origin = _previewOrigin(size, scale);
    final view = _currentView();
    return Vec2(
      view.left + (localPx.dx - origin.dx) / scale,
      view.bottom - (localPx.dy - origin.dy) / scale,
    );
  }

  TemplateMakerHole? _holeNear(Vec2 mm, double scale) {
    final hitToleranceMm = _holeDragHitPx / scale;
    TemplateMakerHole? closest;
    var closestDist = double.infinity;
    for (final h in _controller.holes) {
      final dx = h.x - mm.x;
      final dy = h.y - mm.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      final radiusMm = h.shape != TemplateMakerHoleShape.round
          ? math.max(h.slotLength, h.slotWidth) / 2
          : h.diameter / 2;
      if (dist <= math.max(radiusMm, hitToleranceMm) && dist < closestDist) {
        closestDist = dist;
        closest = h;
      }
    }
    return closest;
  }

  int? _outlinePointNear(Vec2 mm, double scale) {
    final hitToleranceMm = _holeDragHitPx / scale;
    int? closest;
    var closestDist = hitToleranceMm;
    final points = _controller.customOutlinePoints;
    for (var i = 0; i < points.length; i++) {
      final dx = points[i].position.x - mm.x;
      final dy = points[i].position.y - mm.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist <= closestDist) {
        closestDist = dist;
        closest = i;
      }
    }
    return closest;
  }

  /// The outline point index [mm] should be inserted *after* (i.e. the
  /// nearest edge, as a segment between consecutive points), within
  /// [toleranceMm], or null if no edge is close enough. With 3+ points the
  /// outline is closed (the last edge wraps back to the first point).
  int? _outlineEdgeNear(Vec2 mm, double toleranceMm) {
    final points = _controller.customOutlinePoints;
    final n = points.length;
    if (n < 2) return null;
    final edgeCount = n >= 3 ? n : n - 1;
    int? closestIndex;
    var closestDist = toleranceMm;
    for (var i = 0; i < edgeCount; i++) {
      final dist = _distToSegment(mm, points[i].position, points[(i + 1) % n].position);
      if (dist < closestDist) {
        closestDist = dist;
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  void _onPreviewPanStart(DragStartDetails details, Size size) {
    _focusCanvasKeys();
    if (_controller.measureMode) return;
    _frozenView = null;
    _frozenView = _currentView();
    final scale = _previewScale(size);
    final mm = _previewPxToMm(details.localPosition, size);
    _imageDrag = _ImageDrag.none;
    if (_controller.layer == TemplateMakerLayer.drawing) {
      _noteHandle = null;
      final tool = _drawTool;
      if (tool != null) {
        final start = _snapDrag(mm, size);
        final note = _controller.addNoteAt(tool, start);
        _creatingNoteId = _draggingNoteId = note.id;
        _noteHandle = switch (tool) {
          AnnotationType.line => NoteHandle.end,
          AnnotationType.circle => NoteHandle.radius,
          AnnotationType.text => NoteHandle.textSize,
          _ => NoteHandle.cornerNE,
        };
        _noteHandleFixed = start;
        setState(_refreshNoteFields);
        return;
      }
      _collapseToNoteId = null;
      // Handles only show (and can only be grabbed) with a single note selected.
      final selected = _controller.selectedNoteIds.length > 1
          ? null
          : _controller.notes.where((n) => n.id == _controller.selectedNoteId).firstOrNull;
      final grabbed = selected == null ? null : _noteHandleAt(selected, mm, scale);
      if (selected != null && grabbed != null) {
        _draggingNoteId = selected.id;
        _noteHandle = grabbed;
        _noteHandleFixed = _controller.noteRectFixedCorner(selected, grabbed);
        return;
      }
      final hit = _noteAt(mm, scale);
      final additive = _additiveKey;
      if (hit == null) {
        // Empty canvas: drag out a selection box.
        _draggingNoteId = null;
        _marqueeStart = _marqueeEnd = mm;
        _marqueeBase = additive ? {..._controller.selectedNoteIds} : {};
        setState(() {
          if (!additive) _controller.selectNote(null);
        });
        return;
      }
      if (additive) {
        // Shift/Ctrl on a note toggles it (see the tap handler); no drag.
        _draggingNoteId = null;
        return;
      }
      _draggingNoteId = hit.id;
      _lastNoteMm = mm;
      _noteRawAnchor = Vec2(hit.x, hit.y);
      // Grabbing a note that is already part of a multi-selection drags them all.
      if (!_controller.selectedNoteIds.contains(hit.id)) setState(() => _controller.selectNote(hit.id));
      return;
    }
    if (_controller.useCustomOutline) {
      // In add mode a press that turns into a drag never reaches the tap
      // handler: add the point here (or grab an existing one), then drag it.
      final idx = _addingOutlinePoint ? _addOrSelectOutlinePoint(mm, size) : _outlinePointNear(mm, scale);
      if (idx != null) {
        _outlinePointDragStartPx = details.localPosition;
        _draggingOutlinePointIndex = idx;
        _outlinePointResizeStart = mm;
        _outlinePointResizeBaseSize = _controller.customOutlinePoints[idx].size;
        setState(() {
          _controller.selectOutlinePoint(idx);
          _refreshOutlinePointFields();
        });
        return;
      }
    }
    _holeHandle = null;
    final selectedHole = _controller.holes.where((h) => h.id == _controller.selectedHoleId).firstOrNull;
    final grabbed = selectedHole == null ? null : _holeHandleAt(selectedHole, mm, scale);
    if (selectedHole != null && grabbed != null) {
      _draggingHoleId = selectedHole.id;
      _holeHandle = grabbed;
      return;
    }
    _draggingHoleId = _holeNear(mm, scale)?.id;
    if (_draggingHoleId != null) _selectHoleFromPreview(_draggingHoleId!);
    if (_draggingHoleId != null || _controller.refImage == null) return;

    final c = _controller;
    final left = c.imageX, right = c.imageX + c.imageWidth;
    final bottom = c.imageY, top = c.imageY + c.imageHeight;
    final hitMm = _imageHandleHitPx / scale;
    for (final corner in [Vec2(left, bottom), Vec2(right, bottom), Vec2(left, top), Vec2(right, top)]) {
      if ((corner.x - mm.x).abs() <= hitMm && (corner.y - mm.y).abs() <= hitMm) {
        _imageDrag = _ImageDrag.corner;
        _imageDragFixed = Vec2(corner.x == left ? right : left, corner.y == bottom ? top : bottom);
        return;
      }
    }
    if (mm.x >= left && mm.x <= right && mm.y >= bottom && mm.y <= top) {
      _imageDrag = _ImageDrag.move;
      _imageGrabOffset = Vec2(mm.x - left, mm.y - bottom);
    }
  }

  void _selectHoleFromPreview(String holeId) {
    setState(() => _controller.selectHole(holeId));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _holeRowKeys[holeId]?.currentContext;
      if (rowContext != null && rowContext.mounted) {
        Scrollable.ensureVisible(rowContext, duration: const Duration(milliseconds: 150), alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    });
  }

  Vec2 _snapForMeasure(Offset localPx, Size size) {
    final raw = _previewPxToMm(localPx, size);
    return _controller.snapMeasurePoint(raw, 10 / _previewScale(size));
  }

  /// Snaps a dragged point (see [TemplateMakerController.snapDragPoint]); holding
  /// Alt drags freely. Sets the alignment guides shown while dragging.
  Vec2 _snapDrag(Vec2 raw, Size size, {String? excludeHoleId, String? excludeNoteId}) {
    if (HardwareKeyboard.instance.isAltPressed) {
      _guideX = _guideY = null;
      return raw;
    }
    final r = _controller.snapDragPoint(
      raw,
      excludeHoleId: excludeHoleId,
      excludeNoteId: excludeNoteId,
      toleranceMm: 8 / _previewScale(size),
    );
    _guideX = r.guideX;
    _guideY = r.guideY;
    return r.point;
  }

  void _onPreviewTapUp(TapUpDetails details, Size size) {
    final collapse = _collapseToNoteId;
    if (collapse != null) {
      _collapseToNoteId = null;
      setState(() => _controller.selectNote(collapse));
      return;
    }
    if (!_controller.measureMode) return;
    setState(() => _controller.placeMeasurePoint(_snapForMeasure(details.localPosition, size)));
  }

  void _beginTextEdit(TemplateMakerNote note) {
    setState(() {
      _editingNoteId = note.id;
      _editingOriginalText = note.text;
      _canvasTextController.text = note.text;
      _canvasTextController.selection = TextSelection(baseOffset: 0, extentOffset: note.text.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _canvasTextFocus.requestFocus());
  }

  /// Finishes the in-canvas text edit: keeps the typed text, or with [cancel]
  /// restores the original. A note left empty would be invisible, so it is removed.
  void _endTextEdit({bool cancel = false}) {
    final id = _editingNoteId;
    if (id == null) return;
    _editingNoteId = null;
    final note = _controller.notes.where((n) => n.id == id).firstOrNull;
    setState(() {
      if (note != null) {
        _controller.updateNote(id, text: cancel ? _editingOriginalText : _canvasTextController.text);
        if (note.text.isEmpty) {
          _controller.removeNote(id);
        } else {
          _noteFields['$id/text']?.text = note.text;
        }
      }
    });
    // Once the editor is gone, hand focus back so Delete/Ctrl+C work again
    // (unless the click that ended the edit landed in another text field).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_typingInTextField) _keyFocus.requestFocus();
    });
  }

  Widget _canvasTextEditor(Size size, TemplateMakerNote note) {
    final scale = _previewScale(size);
    final origin = _previewOrigin(size, scale);
    final view = _currentView();
    final anchor = Offset(origin.dx + (note.x - view.left) * scale, origin.dy + (view.bottom - note.y) * scale);
    final style = TextStyle(
      fontSize: math.max(note.height * scale, 4),
      color: Colors.lightBlue,
    );
    return Positioned(
      left: anchor.dx,
      bottom: size.height - anchor.dy,
      child: Transform.rotate(
        angle: -note.rotationDeg * math.pi / 180,
        alignment: Alignment.bottomLeft,
        child: IntrinsicWidth(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 40),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: canvasBackground(context),
                border: Border.all(color: Colors.lightBlue),
              ),
              child: EditableText(
                controller: _canvasTextController,
                focusNode: _canvasTextFocus,
                style: style,
                cursorColor: Colors.lightBlue,
                backgroundCursorColor: Colors.grey,
                selectionColor: Colors.lightBlue.withValues(alpha: 0.3),
                onChanged: (v) => setState(() {
                  _controller.updateNote(note.id, text: v);
                  _noteFields['${note.id}/text']?.text = v;
                }),
                onSubmitted: (_) => _endTextEdit(),
                onTapOutside: (_) => _endTextEdit(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onPreviewHover(PointerHoverEvent event, Size size) {
    if (!_controller.measureMode) return;
    setState(() => _measureHover = _snapForMeasure(event.localPosition, size));
  }

  /// Clicking the canvas doesn't take keyboard focus by itself, so after
  /// typing in a field (or any focus loss) Delete and Ctrl+C/V would go
  /// nowhere. Claim it, unless an in-canvas text edit owns the keyboard.
  void _focusCanvasKeys() {
    if (_editingNoteId == null) _keyFocus.requestFocus();
  }

  /// "Add outline point" mode's click: selects the point under [mm] if there
  /// is one, otherwise adds a point there. Returns the selected/added index.
  int _addOrSelectOutlinePoint(Vec2 mm, Size size) {
    final existingIndex = _outlinePointNear(mm, _previewScale(size));
    if (existingIndex != null) {
      // Clicking an existing point while still in add mode selects it (and
      // lets a drag move it) instead of stacking a new point on top of it.
      setState(() {
        _controller.selectOutlinePoint(existingIndex);
        _refreshOutlinePointFields();
      });
      return existingIndex;
    }
    // Once the outline is closed (3+ points), the new point splits the edge
    // it adds the least length to -- the line you clicked on or next to --
    // instead of wiring it to whichever point happens to be selected, which
    // could be on the far side. While still drawing the first points, it
    // chains on after the selected one (or goes at the end).
    final start = _snapDrag(mm, size);
    final points = _controller.customOutlinePoints;
    final after = points.length >= 3 ? _cheapestOutlineEdge(start) : _controller.selectedOutlinePointIndex;
    late int index;
    setState(() {
      index = after != null ? _controller.insertOutlinePointAfter(after, start) : _controller.addOutlinePointAt(start);
      _refreshOutlinePointFields();
    });
    return index;
  }

  /// Index of the closed outline's edge (from that point to the next) that
  /// inserting [p] lengthens the least.
  int _cheapestOutlineEdge(Vec2 p) {
    final points = _controller.customOutlinePoints;
    double d(Vec2 a, Vec2 b) => math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    var best = 0;
    var bestCost = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final a = points[i].position, b = points[(i + 1) % points.length].position;
      final cost = d(a, p) + d(p, b) - d(a, b);
      if (cost < bestCost) {
        bestCost = cost;
        best = i;
      }
    }
    return best;
  }

  void _onPreviewTapDown(TapDownDetails details, Size size) {
    _focusCanvasKeys();
    if (_controller.measureMode) return;
    if (_controller.useCustomOutline && _addingOutlinePoint) {
      // A plain click (no drag) never reaches onPanStart, so adding a point
      // on tap is what makes "click to add points" actually work --
      // onPanStart adds it instead when the press turns into a drag.
      _addOrSelectOutlinePoint(_previewPxToMm(details.localPosition, size), size);
      return;
    }
    if (_controller.useCustomOutline && !_addingOutlinePoint) {
      final mm = _previewPxToMm(details.localPosition, size);
      final scale = _previewScale(size);
      // A plain click (no drag) never reaches onPanStart (see the add-point
      // branch above), so selecting a point has to happen here too --
      // otherwise it only "works" by the accident of a click having a
      // little incidental movement.
      final pointIndex = _outlinePointNear(mm, scale);
      if (pointIndex != null) {
        setState(() {
          _controller.selectOutlinePoint(pointIndex);
          _refreshOutlinePointFields();
        });
        _lastPlateTapAt = DateTime.fromMillisecondsSinceEpoch(0);
        return;
      }
      // Double-clicking an edge (not an existing point) inserts a new point
      // right there, in its correct place along the path -- handy without
      // switching into "Add outline point" mode first.
      final now = DateTime.now();
      final lastMm = _lastPlateTapMm;
      final isDoubleClick = lastMm != null &&
          now.difference(_lastPlateTapAt) < const Duration(milliseconds: 400) &&
          (lastMm.x - mm.x) * (lastMm.x - mm.x) + (lastMm.y - mm.y) * (lastMm.y - mm.y) < math.pow(10 / scale, 2);
      _lastPlateTapAt = now;
      _lastPlateTapMm = mm;
      if (isDoubleClick) {
        final edgeIndex = _outlineEdgeNear(mm, 10 / scale);
        if (edgeIndex != null) {
          final snapped = _snapDrag(mm, size);
          setState(() {
            _controller.insertOutlinePointAfter(edgeIndex, snapped);
            _refreshOutlinePointFields();
          });
          _lastPlateTapAt = DateTime.fromMillisecondsSinceEpoch(0);
          return;
        }
      }
    }
    if (_controller.layer == TemplateMakerLayer.drawing) {
      final hit = _noteAt(_previewPxToMm(details.localPosition, size), _previewScale(size));
      _collapseToNoteId = null;
      if (_additiveKey) {
        // Shift/Ctrl+click adds a note to (or removes it from) the selection.
        if (hit != null) setState(() => _controller.toggleNoteSelection(hit.id));
        return;
      }
      final now = DateTime.now();
      final doubleClick = hit != null &&
          hit.id == _lastTapNoteId &&
          now.difference(_lastTapAt) < const Duration(milliseconds: 400);
      _lastTapAt = now;
      _lastTapNoteId = hit?.id;
      if (hit != null && _controller.selectedNoteIds.length > 1 && _controller.selectedNoteIds.contains(hit.id)) {
        // Keep the group so it can be dragged; a plain click narrows it on release.
        _collapseToNoteId = hit.id;
      } else {
        setState(() => _controller.selectNote(hit?.id));
      }
      if (doubleClick && _drawTool == null && hit.type == AnnotationType.text) _beginTextEdit(hit);
      return;
    }
    final hit = _holeNear(_previewPxToMm(details.localPosition, size), _previewScale(size));
    if (hit != null) {
      _selectHoleFromPreview(hit.id);
    } else {
      setState(() => _controller.selectHole(null));
    }
  }

  void _onPreviewPanUpdate(DragUpdateDetails details, Size size) {
    if (_controller.layer == TemplateMakerLayer.drawing) {
      final boxStart = _marqueeStart;
      if (boxStart != null) {
        final p = _previewPxToMm(details.localPosition, size);
        setState(() {
          _marqueeEnd = p;
          final box = Rect.fromLTRB(math.min(boxStart.x, p.x), math.min(boxStart.y, p.y), math.max(boxStart.x, p.x), math.max(boxStart.y, p.y));
          _controller.setSelectedNotes({..._marqueeBase, ..._controller.notesInRect(box)});
        });
        return;
      }
      final id = _draggingNoteId;
      if (id == null) return;
      final handle = _noteHandle;
      if (handle != null) {
        final raw = _previewPxToMm(details.localPosition, size);
        setState(() {
          if (id == _creatingNoteId && handle == NoteHandle.textSize) {
            // Drawing a text box: both corners are positions, so snap them.
            _controller.dragNoteTextBox(id, _noteHandleFixed!, _snapDrag(raw, size, excludeNoteId: id));
            _refreshNoteFields();
            return;
          }
          // A text note's size isn't a position worth snapping to the grid.
          final target = handle == NoteHandle.textSize ? raw : _snapDrag(raw, size, excludeNoteId: id);
          _controller.dragNoteHandle(id, handle, target, fixed: _noteHandleFixed);
          _refreshNoteFields();
        });
        return;
      }
      final p = _previewPxToMm(details.localPosition, size);
      _noteRawAnchor = _noteRawAnchor.add(Vec2(p.x - _lastNoteMm.x, p.y - _lastNoteMm.y));
      _lastNoteMm = p;
      final note = _controller.notes.firstWhere((n) => n.id == id);
      setState(() {
        final target = _snapDrag(_noteRawAnchor, size, excludeNoteId: id);
        if (_controller.selectedNoteIds.length > 1 && _controller.selectedNoteIds.contains(id)) {
          _controller.moveSelectedNotesBy(target.x - note.x, target.y - note.y);
        } else {
          _controller.moveNoteBy(id, target.x - note.x, target.y - note.y);
        }
        _refreshNoteFields();
      });
      return;
    }
    final opIndex = _draggingOutlinePointIndex;
    if (opIndex != null) {
      final rawMm = _previewPxToMm(details.localPosition, size);
      final resizeStart = _outlinePointResizeStart;
      if (HardwareKeyboard.instance.isShiftPressed && resizeStart != null) {
        // Shift+drag grows the point's fillet/chamfer size instead of
        // moving it -- distance dragged from where the drag started is
        // added to the size it started from, so it can only grow from
        // there (drag back toward the start to shrink back down).
        final dx = rawMm.x - resizeStart.x, dy = rawMm.y - resizeStart.y;
        final dragged = math.sqrt(dx * dx + dy * dy);
        // Jumps in 1mm steps rather than tracking the pointer continuously,
        // so it's easy to land on a clean size instead of fighting sub-mm
        // jitter.
        final size = ((_outlinePointResizeBaseSize + dragged).round()).toDouble();
        setState(() {
          final point = _controller.customOutlinePoints[opIndex];
          if (point.style == OutlineCornerStyle.sharp) {
            _controller.setOutlinePointStyle(opIndex, OutlineCornerStyle.fillet);
          }
          _controller.setOutlinePointSize(opIndex, size);
          _refreshOutlinePointFields();
        });
        return;
      }
      // Ignore the first few pixels, so a slightly shaky click on a point
      // (e.g. a traced one, off the grid) doesn't snap it somewhere else.
      final startPx = _outlinePointDragStartPx;
      if (startPx != null) {
        if ((details.localPosition - startPx).distance < _outlinePointDragDeadZonePx) return;
        _outlinePointDragStartPx = null;
      }
      final mm = _snapDrag(rawMm, size);
      setState(() {
        _controller.moveOutlinePoint(opIndex, mm);
        _refreshOutlinePointFields();
      });
      return;
    }
    final draggingId = _draggingHoleId;
    if (draggingId == null) {
      if (_imageDrag == _ImageDrag.none) return;
      final pointer = _previewPxToMm(details.localPosition, size);
      setState(() {
        if (_imageDrag == _ImageDrag.move) {
          _controller.setImagePosition(x: pointer.x - _imageGrabOffset.x, y: pointer.y - _imageGrabOffset.y);
        } else {
          _controller.scaleImageFromCorner(_imageDragFixed, pointer);
        }
        _refreshImageFields();
      });
      return;
    }
    final holeHandle = _holeHandle;
    if (holeHandle != null) {
      setState(() {
        final mm = _snapDrag(_previewPxToMm(details.localPosition, size), size, excludeHoleId: draggingId);
        _controller.dragHoleHandle(draggingId, holeHandle, mm);
        final h = _controller.holes.firstWhere((e) => e.id == draggingId);
        _holeD[draggingId]?.text = _fmt(h.diameter);
        _holeLen[draggingId]?.text = _fmt(h.slotLength);
        _holeWidth[draggingId]?.text = _fmt(h.slotWidth);
      });
      return;
    }
    setState(() {
      final mm = _snapDrag(_previewPxToMm(details.localPosition, size), size, excludeHoleId: draggingId);
      _controller.updateHole(draggingId, x: mm.x, y: mm.y);
      _holeX[draggingId]?.text = _fmt(mm.x);
      _holeY[draggingId]?.text = _fmt(mm.y);
    });
  }

  bool get _dragActive =>
      _marqueeStart != null ||
      _draggingNoteId != null ||
      _draggingHoleId != null ||
      _draggingOutlinePointIndex != null ||
      _creatingNoteId != null ||
      _imageDrag != _ImageDrag.none;

  void _onPreviewPanEnd(DragEndDetails details) => _finishDrag();

  /// The primary-button press on the canvas being tracked, where it went
  /// down, and whether it has moved far enough to be a drag.
  int? _canvasPointer;
  Offset _canvasDownPx = Offset.zero;
  bool _canvasDragging = false;

  void _onCanvasPointerDown(PointerDownEvent event) {
    if (event.buttons & kPrimaryButton == 0) return;
    // A press still being tracked means its release never arrived: end
    // whatever it was doing before starting over.
    if (_canvasPointer != null) _onCanvasPointerCancel(null);
    _canvasPointer = event.pointer;
    _canvasDownPx = event.localPosition;
    _canvasDragging = false;
  }

  void _onCanvasPointerMove(PointerMoveEvent event, Size size) {
    if (event.pointer != _canvasPointer) return;
    if (!_canvasDragging) {
      if ((event.localPosition - _canvasDownPx).distance <= computePanSlop(event.kind, null)) return;
      _canvasDragging = true;
      // Start the drag from where the button went down, not where the
      // pointer is now: otherwise a quick drag starting on a small handle,
      // hole or point has moved off it before we look for what was grabbed.
      _onPreviewPanStart(
        DragStartDetails(
          localPosition: _canvasDownPx,
          globalPosition: event.position - (event.localPosition - _canvasDownPx),
          kind: event.kind,
        ),
        size,
      );
    }
    _onPreviewPanUpdate(
      DragUpdateDetails(localPosition: event.localPosition, globalPosition: event.position, delta: event.delta),
      size,
    );
  }

  void _onCanvasPointerUp(PointerUpEvent event, Size size) {
    if (event.pointer != _canvasPointer) return;
    _canvasPointer = null;
    if (_canvasDragging) {
      _onPreviewPanEnd(DragEndDetails());
      return;
    }
    final at = _canvasDownPx;
    final global = event.position - (event.localPosition - at);
    _onPreviewTapDown(TapDownDetails(localPosition: at, globalPosition: global, kind: event.kind), size);
    _onPreviewTapUp(TapUpDetails(localPosition: at, globalPosition: global, kind: event.kind), size);
  }

  void _onCanvasPointerCancel(PointerCancelEvent? event) {
    if (event != null && event.pointer != _canvasPointer) return;
    _canvasPointer = null;
    if (_canvasDragging) _finishDrag();
    _canvasDragging = false;
  }

  /// Ends whatever canvas drag is in progress. Also used when the gesture is
  /// cancelled or the pointer leaves the canvas (e.g. off the window), where
  /// no pointer-up may ever arrive: without it the drag would stay "on" and
  /// keep following the mouse.
  void _finishDrag() {
    final creatingId = _creatingNoteId;
    if (creatingId != null) {
      _creatingNoteId = null;
      final n = _controller.notes.where((e) => e.id == creatingId).firstOrNull;
      // A click without a real drag would leave a dot; drop it.
      final tiny = n == null ||
          switch (n.type) {
            AnnotationType.line => math.sqrt(math.pow(n.x2 - n.x, 2) + math.pow(n.y2 - n.y, 2)) < 0.5,
            AnnotationType.rect => n.width < 0.5 && n.height < 0.5,
            AnnotationType.text => n.height <= 0.5,
            AnnotationType.circle => n.radius < 0.5,
          };
      if (n != null && tiny) _controller.removeNote(creatingId);
    }
    _marqueeStart = _marqueeEnd = null;
    _draggingHoleId = null;
    _draggingOutlinePointIndex = null;
    _outlinePointResizeStart = null;
    _outlinePointDragStartPx = null;
    _holeHandle = null;
    _draggingNoteId = null;
    _noteHandle = null;
    _noteHandleFixed = null;
    _imageDrag = _ImageDrag.none;
    setState(() {
      _frozenView = null;
      _guideX = _guideY = null;
    });
  }

  Future<void> _autoFitImage() async {
    final mismatch = await _controller.autoFitImageToOutline();
    if (!mounted) return;
    if (mismatch == null) {
      _snack('Could not find a board outline in the image');
      return;
    }
    setState(_refreshImageFields);
    _snack(mismatch > 0.5
        ? 'Fitted to outline. The image needed ${mismatch.toStringAsFixed(1)}% different X and Y scaling -- check the outline size.'
        : 'Fitted image to outline');
  }

  Future<void> _detectHoles() async {
    final added = await _controller.detectHolesFromImage();
    if (!mounted) return;
    setState(() {});
    if (added == null) {
      _snack('Could not analyse the image');
    } else if (added == 0) {
      _snack('No new holes found. Try "Auto-fit to outline" first.');
    } else {
      _snack('Added $added hole${added == 1 ? '' : 's'} -- check them against the image');
    }
  }

  Future<void> _traceOutline() async {
    final count = await _controller.traceOutlineFromImage();
    if (!mounted) return;
    setState(() => _addingOutlinePoint = false);
    if (count == null) {
      _snack('Could not find a board outline in the image');
    } else {
      _snack('Traced custom outline with $count points -- check it against the image');
    }
  }

  Future<void> _loadImage() async {
    final picked = await pickFile(
      allowedExtensions: ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
      dialogTitle: 'Load Reference Image',
    );
    if (picked == null) return;
    try {
      await _controller.loadReferenceImage(picked.bytes, picked.name);
      if (!mounted) return;
      setState(_refreshImageFields);
    } catch (e) {
      _snack('Failed to load image: $e');
    }
  }

  Widget _imageField(String label, TextEditingController controller, FocusNode focus, void Function(double) apply) {
    void commit() => _commitMathField(controller, (v) {
          apply(v);
          _refreshImageFields();
        });
    return TextField(
      controller: controller,
      focusNode: focus,
      decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      onChanged: (v) {
        final parsed = tryEvalMath(v);
        if (parsed != null) setState(() => apply(parsed));
      },
      onSubmitted: (_) => commit(),
      onEditingComplete: commit,
      onTapOutside: (_) {
        commit();
        focus.unfocus();
      },
    );
  }

  /// X/Y position (manually editable) plus corner style/size for the
  /// selected custom-outline point.
  Widget _outlinePointEditor(BuildContext context, int index) {
    final point = _controller.customOutlinePoints[index];
    void commitX() => _commitMathField(_outlinePointXController, (v) {
          _controller.moveOutlinePoint(index, Vec2(v, _controller.customOutlinePoints[index].position.y));
        });
    void commitY() => _commitMathField(_outlinePointYController, (v) {
          _controller.moveOutlinePoint(index, Vec2(_controller.customOutlinePoints[index].position.x, v));
        });
    void commitSize() => _commitMathField(_outlinePointSizeController, (v) => _controller.setOutlinePointSize(index, v));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Selected point', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _outlinePointXController,
                focusNode: _outlinePointXFocus,
                decoration: const InputDecoration(labelText: 'X (mm)', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onSubmitted: (_) => commitX(),
                onEditingComplete: commitX,
                onTapOutside: (_) {
                  commitX();
                  _outlinePointXFocus.unfocus();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _outlinePointYController,
                focusNode: _outlinePointYFocus,
                decoration: const InputDecoration(labelText: 'Y (mm)', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onSubmitted: (_) => commitY(),
                onEditingComplete: commitY,
                onTapOutside: (_) {
                  commitY();
                  _outlinePointYFocus.unfocus();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<OutlineCornerStyle>(
                initialValue: point.style,
                decoration: const InputDecoration(labelText: 'Corner', isDense: true, border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: OutlineCornerStyle.sharp, child: Text('Sharp')),
                  DropdownMenuItem(value: OutlineCornerStyle.fillet, child: Text('Fillet')),
                  DropdownMenuItem(value: OutlineCornerStyle.chamfer, child: Text('Chamfer')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _controller.setOutlinePointStyle(index, v));
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _outlinePointSizeController,
                focusNode: _outlinePointSizeFocus,
                enabled: point.style != OutlineCornerStyle.sharp,
                decoration: const InputDecoration(labelText: 'Size (mm)', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (_) => commitSize(),
                onEditingComplete: commitSize,
                onTapOutside: (_) {
                  commitSize();
                  _outlinePointSizeFocus.unfocus();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _referenceImageSection(BuildContext context) {
    final c = _controller;
    final loaded = c.refImage != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Reference Image', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _loadImage,
              icon: const Icon(Icons.image_outlined),
              label: Text(loaded ? 'Replace' : 'Load Image'),
            ),
            const SizedBox(width: 8),
            if (loaded)
              OutlinedButton.icon(
                onPressed: () => setState(c.clearReferenceImage),
                icon: const Icon(Icons.close),
                label: const Text('Remove'),
              ),
          ],
        ),
        if (loaded) ...[
          const SizedBox(height: 4),
          Text(c.refImageName ?? '', style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _imageField('X (mm)', _imageXController, _imageXFocus, (v) => c.setImagePosition(x: v))),
              const SizedBox(width: 8),
              Expanded(child: _imageField('Y (mm)', _imageYController, _imageYFocus, (v) => c.setImagePosition(y: v))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _imageField('Width (mm)', _imageWController, _imageWFocus, (v) => c.setImageSize(width: v))),
              const SizedBox(width: 8),
              Expanded(child: _imageField('Height (mm)', _imageHController, _imageHFocus, (v) => c.setImageSize(height: v))),
            ],
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Lock aspect ratio'),
            value: c.imageLockAspect,
            onChanged: (v) => setState(() {
              c.setImageLockAspect(v ?? true);
              _refreshImageFields();
            }),
          ),
          Row(
            children: [
              const Text('Opacity'),
              Expanded(
                child: Slider(
                  value: c.imageOpacity,
                  min: 0.05,
                  max: 1,
                  onChanged: (v) => setState(() => c.setImageOpacity(v)),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                onPressed: _autoFitImage,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Auto-fit to outline'),
              ),
              FilledButton.tonalIcon(
                onPressed: _detectHoles,
                icon: const Icon(Icons.search),
                label: const Text('Find holes'),
              ),
              FilledButton.tonalIcon(
                onPressed: _traceOutline,
                icon: const Icon(Icons.polyline),
                label: const Text('Trace outline'),
              ),
              OutlinedButton(
                onPressed: () => setState(() {
                  c.fitImageToOutline();
                  _refreshImageFields();
                }),
                child: const Text('Fit width to outline'),
              ),
              OutlinedButton(
                onPressed: () => setState(() {
                  c.fitImageToOutline(keepAspect: false);
                  _refreshImageFields();
                }),
                child: const Text('Stretch to outline'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Drag the image to move it, or a corner handle to scale it. Holes are dragged first when they overlap.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadJson() async {
    final picked = await pickFile(allowedExtensions: ['json'], dialogTitle: 'Load Template JSON');
    if (picked == null) return;
    try {
      final json = jsonDecode(utf8.decode(picked.bytes)) as Map<String, dynamic>;
      final template = ControllerTemplate.fromJson(json, source: TemplateSource.imported);
      setState(() {
        _controller.loadFromTemplate(template);
        _resetIdAuto();
        _syncHoleControllers();
        _refreshTopFields();
      });
      _snack('Loaded ${template.name}');
    } catch (e) {
      _snack('Failed to load: $e');
    }
  }

  Future<void> _loadDxf() async {
    final picked = await pickFile(allowedExtensions: ['dxf'], dialogTitle: 'Load Template DXF');
    if (picked == null) return;
    try {
      final entities = parseDxf(utf8.decode(picked.bytes));
      final name = picked.name.replaceAll(RegExp(r'\.dxf$', caseSensitive: false), '');
      final template = ControllerTemplate(
        id: _slugify(name),
        name: name,
        entities: entities,
        source: TemplateSource.imported,
        category: _controller.category,
      );
      setState(() {
        _controller.loadFromTemplate(template);
        _resetIdAuto();
        _syncHoleControllers();
        _refreshTopFields();
      });
      _snack('Loaded ${template.name}');
    } catch (e) {
      _snack('Failed to load: $e');
    }
  }

  Future<void> _exportJson() async {
    final template = _controller.toTemplate();
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(template.toJson()));
    final result = await saveBytes('${template.id}.json', bytes, dialogTitle: 'Export Template JSON', mimeType: 'application/json');
    _snack(result != null ? 'Template exported' : 'Export cancelled');
  }

  Future<void> _saveToLibrary() async {
    final library = widget.library;
    if (library == null) return;
    final template = _controller.toTemplate();
    final saved = await library.saveUserTemplate(template);
    if (saved.id != template.id) {
      // The id collided with some other template already in the library
      // (e.g. this is an edited copy of a bundled/remote one) -- adopt the
      // unique id the library picked so a subsequent save updates this same
      // saved copy instead of colliding (and getting renamed) all over again.
      setState(() {
        _controller.setId(saved.id);
        _idController.text = saved.id;
      });
      _snack('"${template.id}" was already in use -- saved as a new copy with id "${saved.id}"');
    } else {
      _snack('Saved "${saved.name}" to the library');
    }
  }

  /// Opens GitHub's own "create new file" page, pre-filled with this
  /// template's JSON at the path it belongs in -- no GitHub token or API
  /// calls needed in the app itself: for anyone without direct push access
  /// (i.e. everyone but the repo's own maintainer), clicking "Propose new
  /// file" there has GitHub fork the repo, create a branch, and open a pull
  /// request, all under the contributor's own already-logged-in account.
  Future<void> _openGitHubPr() async {
    final template = _controller.toTemplate();
    if (template.id.trim().isEmpty) {
      _snack('Set a template Id first.');
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert(template.toJson());
    final path = 'assets/templates/${template.id}.json';
    final url = Uri.https(
      'github.com',
      '/$_githubRepoOwner/$_githubRepoName/new/main',
      {'filename': path, 'value': json},
    );
    if (url.toString().length > _githubPrUrlWarnLength) {
      _snack('This template is large -- GitHub may not load it. If the page comes up empty, use Export JSON and attach the file to the PR by hand instead.');
    }
    final launched = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!launched) {
      _snack('Could not open a browser. Use Export JSON and open a pull request manually instead.');
      return;
    }
    _snack('Opened GitHub in your browser -- review the file, then click "Propose new file" to open your pull request.');
  }

  void _newTemplate() {
    setState(() {
      _controller.newTemplate();
      _resetIdAuto();
      _syncHoleControllers();
      _refreshTopFields();
    });
  }

  void _addHole() {
    setState(() {
      _controller.addHole();
      _syncHoleControllers();
      _refreshTopFields();
    });
  }

  /// True while the keyboard focus is in a text field, where Ctrl+C / Ctrl+V /
  /// Delete belong to the text.
  bool get _typingInTextField {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape && (_drawTool != null || _dragActive || _addingOutlinePoint)) {
      // Escape stops drawing: cancels a drag in progress and disarms the tool.
      if (_dragActive) _finishDrag();
      setState(() {
        _drawTool = null;
        _addingOutlinePoint = false;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete || event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_typingInTextField || _controller.measureMode) return KeyEventResult.ignored;
      final opIndex = _controller.selectedOutlinePointIndex;
      if (_controller.useCustomOutline && opIndex != null) {
        setState(() => _controller.removeOutlinePoint(opIndex));
        return KeyEventResult.handled;
      }
      if (!_controller.canCopy) return KeyEventResult.ignored;
      setState(() {
        if (_controller.layer == TemplateMakerLayer.drawing) {
          _controller.deleteSelectedNotes();
        } else {
          _controller.removeHole(_controller.selectedHoleId!);
        }
      });
      return KeyEventResult.handled;
    }
    if (!(keyboard.isControlPressed || keyboard.isMetaPressed) || keyboard.isAltPressed) return KeyEventResult.ignored;
    if (_typingInTextField) return KeyEventResult.ignored;
    final zoomSize = _canvasSize;
    if (zoomSize != null) {
      final key = event.logicalKey;
      final centre = Offset(zoomSize.width / 2, zoomSize.height / 2);
      if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd) {
        _zoomBy(1.25, centre, zoomSize);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) {
        _zoomBy(1 / 1.25, centre, zoomSize);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
        _zoomFit();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      if (_controller.layer != TemplateMakerLayer.drawing || _controller.notes.isEmpty) return KeyEventResult.ignored;
      setState(_controller.selectAllNotes);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      if (!_controller.copySelection()) return KeyEventResult.ignored;
      _snack('Copied');
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      if (!_controller.canPaste) return KeyEventResult.ignored;
      final id = _controller.paste();
      if (id == null) return KeyEventResult.ignored;
      setState(() {
        _syncHoleControllers();
        _refreshTopFields();
        _refreshNoteFields();
      });
      if (_controller.layer != TemplateMakerLayer.drawing) _selectHoleFromPreview(id);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _addRect() {
    setState(() {
      _controller.addRect();
      _syncHoleControllers();
      _refreshTopFields();
    });
  }

  void _addSlot() {
    setState(() {
      _controller.addSlot();
      _syncHoleControllers();
      _refreshTopFields();
    });
  }

  void _removeHole(String id) {
    setState(() => _controller.removeHole(id));
  }

  void _shiftAllHoles(double dx, double dy) {
    final distance = tryEvalMath(_shiftDistanceController.text);
    if (distance == null || distance <= 0) {
      _snack('Enter a positive shift distance.');
      return;
    }
    setState(() {
      _controller.shiftAllHoles(dx * distance, dy * distance);
      _refreshTopFields();
    });
  }

  Future<void> _showQuickHoleDialog() async {
    final hCtrl = TextEditingController();
    final vCtrl = TextEditingController();
    final dCtrl = TextEditingController(text: '4');
    final lenCtrl = TextEditingController(text: '6');
    final widthCtrl = TextEditingController(text: '4');
    final offsetCtrl = TextEditingController();
    var shape = TemplateMakerHoleShape.round;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Quick 4-Hole Pattern'),
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Places 4 holes centered on the outline\'s centerline.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: hCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Horizontal spacing (mm)', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: vCtrl,
                    decoration: const InputDecoration(labelText: 'Vertical spacing (mm)', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<TemplateMakerHoleShape>(
                    initialValue: shape,
                    decoration: const InputDecoration(labelText: 'Hole type', isDense: true, border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: TemplateMakerHoleShape.round, child: Text('Circle')),
                      DropdownMenuItem(value: TemplateMakerHoleShape.rect, child: Text('Square')),
                      DropdownMenuItem(value: TemplateMakerHoleShape.slot, child: Text('Slot')),
                    ],
                    onChanged: (value) => setDialogState(() => shape = value ?? TemplateMakerHoleShape.round),
                  ),
                  const SizedBox(height: 8),
                  if (shape == TemplateMakerHoleShape.round)
                    TextField(
                      controller: dCtrl,
                      decoration: const InputDecoration(labelText: 'Hole diameter (mm)', isDense: true, border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    )
                  else if (shape == TemplateMakerHoleShape.rect)
                    TextField(
                      controller: dCtrl,
                      decoration: const InputDecoration(labelText: 'Square side (mm)', isDense: true, border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    )
                  else ...[
                    TextField(
                      controller: lenCtrl,
                      decoration: const InputDecoration(labelText: 'Slot length (mm)', isDense: true, border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: widthCtrl,
                      decoration: const InputDecoration(labelText: 'Slot width (mm)', isDense: true, border: OutlineInputBorder()),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: offsetCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Outline offset (mm)',
                      helperText: 'Sets outline size to spacing + this much margin on each side. Leave blank to keep the current outline size.',
                      helperMaxLines: 3,
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Add')),
            ],
          ),
        ),
      );
      if (confirmed != true) return;

      final h = tryEvalMath(hCtrl.text);
      final v = tryEvalMath(vCtrl.text);
      final d = tryEvalMath(dCtrl.text);
      if (h == null || v == null || h <= 0 || v <= 0) {
        _snack('Enter a positive horizontal and vertical spacing.');
        return;
      }
      final offset = tryEvalMath(offsetCtrl.text);
      if (offsetCtrl.text.trim().isNotEmpty && (offset == null || offset < 0)) {
        _snack('Outline offset must be a non-negative number, or left blank.');
        return;
      }
      final double side = (d != null && d > 0) ? d : 4;
      final len = tryEvalMath(lenCtrl.text);
      final width = tryEvalMath(widthCtrl.text);
      setState(() {
        _controller.addQuickHolePattern(
          horizontalSpacing: h,
          verticalSpacing: v,
          diameter: side,
          outlineOffset: offset,
          shape: shape,
          slotLength: shape == TemplateMakerHoleShape.rect ? side : ((len != null && len > 0) ? len : 6.0),
          slotWidth: shape == TemplateMakerHoleShape.rect ? side : ((width != null && width > 0) ? width : 4.0),
        );
        _syncHoleControllers();
        _refreshTopFields();
      });
    } finally {
      hCtrl.dispose();
      vCtrl.dispose();
      offsetCtrl.dispose();
      dCtrl.dispose();
      lenCtrl.dispose();
      widthCtrl.dispose();
    }
  }

  Widget _gridMenu() {
    final c = _controller;
    String fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Grid and snapping (hold Alt while dragging to move freely)',
      onSelected: (action) => setState(action),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: () => c.setShowGrid(!c.showGrid), checked: c.showGrid, child: const Text('Show grid')),
        CheckedPopupMenuItem(value: () => c.setSnapToGrid(!c.snapToGrid), checked: c.snapToGrid, child: const Text('Snap to grid')),
        CheckedPopupMenuItem(
          value: () => c.setSnapToObjects(!c.snapToObjects),
          checked: c.snapToObjects,
          child: const Text('Snap to edges, centres and other items'),
        ),
        const PopupMenuDivider(),
        for (final size in TemplateMakerController.gridSizesMm)
          CheckedPopupMenuItem(value: () => c.setGridMm(size), checked: c.gridMm == size, child: Text('Grid ${fmt(size)} mm')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(c.showGrid ? Icons.grid_on : Icons.grid_off, size: 18),
            const SizedBox(width: 8),
            Text(c.snapToGrid || c.snapToObjects ? 'Grid · snap' : 'Grid'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    _syncHoleControllers();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Template Maker'),
        actions: [
          _controller.measureMode
              ? FilledButton.icon(
                  onPressed: () => setState(() {
                    _controller.toggleMeasureMode();
                    _measureHover = null;
                  }),
                  icon: const Icon(Icons.straighten, size: 18),
                  label: const Text('Measure'),
                )
              : TextButton.icon(
                  onPressed: () => setState(_controller.toggleMeasureMode),
                  icon: const Icon(Icons.straighten, size: 18),
                  label: const Text('Measure'),
                ),
          _gridMenu(),
          TextButton.icon(onPressed: _newTemplate, icon: const Icon(Icons.add), label: const Text('New')),
          TextButton.icon(onPressed: _loadJson, icon: const Icon(Icons.folder_open), label: const Text('Load JSON')),
          TextButton.icon(onPressed: _loadDxf, icon: const Icon(Icons.folder_open), label: const Text('Load DXF')),
          TextButton.icon(onPressed: _exportJson, icon: const Icon(Icons.save_alt), label: const Text('Export JSON')),
          if (widget.library != null)
            TextButton.icon(
              onPressed: _saveToLibrary,
              icon: const Icon(Icons.library_add),
              label: const Text('Save to Library'),
            ),
          TextButton.icon(
            onPressed: _openGitHubPr,
            icon: const Icon(Icons.merge_type),
            label: const Text('Open PR on GitHub'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 340,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text('Template', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _idController,
                  decoration: InputDecoration(
                    labelText: 'Id',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    helperText: _idAuto ? 'Auto-set from Name' : null,
                  ),
                  onChanged: (v) => setState(() {
                    _idAuto = false;
                    _controller.setId(v);
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) => setState(() {
                    _controller.setName(v);
                    if (_idAuto) {
                      final id = _slugify(v);
                      _controller.setId(id);
                      _idController.text = id;
                    }
                  }),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<TemplateCategory>(
                  isExpanded: true,
                  initialValue: _controller.category,
                  decoration: const InputDecoration(labelText: 'Category', isDense: true, border: OutlineInputBorder()),
                  items: [
                    for (final c in TemplateCategory.values) DropdownMenuItem(value: c, child: Text(c.name)),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        _controller.setCategory(v);
                        _syncHoleControllers();
                        _refreshTopFields();
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                _layerSelector(context),
                if (_controller.layer == TemplateMakerLayer.drawing)
                  ..._drawingSectionWidgets(context)
                else ...[
                const Divider(height: 32),
                Text('Outline', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _widthController,
                        focusNode: _widthFocus,
                        decoration: const InputDecoration(labelText: 'Width (mm)', isDense: true, border: OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (v) {
                          final parsed = tryEvalMath(v);
                          if (parsed != null) setState(() => _controller.setOutlineWidth(parsed));
                        },
                        onSubmitted: (_) => _commitMathField(_widthController, _controller.setOutlineWidth),
                        onEditingComplete: () => _commitMathField(_widthController, _controller.setOutlineWidth),
                        onTapOutside: (_) {
                          _commitMathField(_widthController, _controller.setOutlineWidth);
                          _widthFocus.unfocus();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _heightController,
                        focusNode: _heightFocus,
                        decoration: const InputDecoration(labelText: 'Height (mm)', isDense: true, border: OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (v) {
                          final parsed = tryEvalMath(v);
                          if (parsed != null) setState(() => _controller.setOutlineHeight(parsed));
                        },
                        onSubmitted: (_) => _commitMathField(_heightController, _controller.setOutlineHeight),
                        onEditingComplete: () => _commitMathField(_heightController, _controller.setOutlineHeight),
                        onTapOutside: (_) {
                          _commitMathField(_heightController, _controller.setOutlineHeight);
                          _heightFocus.unfocus();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Custom outline'),
                  subtitle: const Text('Click points on the canvas to draw the outline instead of using Corner Style.'),
                  value: _controller.useCustomOutline,
                  onChanged: (v) => setState(() {
                    _controller.setUseCustomOutline(v ?? false);
                    _addingOutlinePoint = false;
                  }),
                ),
                if (_controller.useCustomOutline) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => _addingOutlinePoint = !_addingOutlinePoint),
                        icon: Icon(_addingOutlinePoint ? Icons.check : Icons.add_location_alt_outlined),
                        label: Text(_addingOutlinePoint ? 'Done adding points' : 'Add outline point'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _controller.customOutlinePoints.isEmpty
                            ? null
                            : () => setState(() {
                                  _controller.customOutlinePoints.clear();
                                  _controller.selectOutlinePoint(null);
                                }),
                        icon: const Icon(Icons.clear),
                        label: const Text('Clear points'),
                      ),
                      Text('${_controller.customOutlinePoints.length} point'
                          '${_controller.customOutlinePoints.length == 1 ? '' : 's'}'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Click a point to select it, then drag to move it. Click Add outline point, then click on or '
                    'near an edge to insert a new point into it -- or double-click an edge to insert one there '
                    'without switching modes. '
                    'Shift+drag a point to grow its fillet/chamfer. Delete removes the selected point. At least '
                    '3 points are needed to use the shape.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_controller.selectedOutlinePointIndex != null &&
                      _controller.selectedOutlinePointIndex! < _controller.customOutlinePoints.length) ...[
                    const SizedBox(height: 8),
                    _outlinePointEditor(context, _controller.selectedOutlinePointIndex!),
                  ],
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<TemplateMakerCornerStyle>(
                          initialValue: _controller.cornerStyle,
                          decoration: const InputDecoration(labelText: 'Corner style', isDense: true, border: OutlineInputBorder()),
                          items: const [
                            DropdownMenuItem(value: TemplateMakerCornerStyle.fillet, child: Text('Fillet')),
                            DropdownMenuItem(value: TemplateMakerCornerStyle.chamfer, child: Text('Chamfer')),
                            DropdownMenuItem(value: TemplateMakerCornerStyle.cornerCut, child: Text('Corner cut')),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _controller.setCornerStyle(v));
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _cornerSizeController,
                          focusNode: _cornerSizeFocus,
                          decoration: const InputDecoration(labelText: 'Size (mm)', isDense: true, border: OutlineInputBorder()),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          onChanged: (v) {
                            final parsed = tryEvalMath(v);
                            if (parsed != null) {
                              setState(() {
                                _controller.setCornerSize(parsed);
                                _refreshTopFields();
                              });
                            }
                          },
                          onSubmitted: (_) => _commitMathField(_cornerSizeController, (v) {
                            _controller.setCornerSize(v);
                            _refreshTopFields();
                          }),
                          onEditingComplete: () => _commitMathField(_cornerSizeController, (v) {
                            _controller.setCornerSize(v);
                            _refreshTopFields();
                          }),
                          onTapOutside: (_) {
                            _commitMathField(_cornerSizeController, (v) {
                              _controller.setCornerSize(v);
                              _refreshTopFields();
                            });
                            _cornerSizeFocus.unfocus();
                          },
                        ),
                      ),
                    ],
                  ),
                const Divider(height: 32),
                _referenceImageSection(context),
                const Divider(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Holes', style: Theme.of(context).textTheme.titleMedium),
                    Row(
                      children: [
                        IconButton(onPressed: _addHole, icon: const Icon(Icons.add_circle_outline), tooltip: 'Add round hole'),
                        IconButton(onPressed: _addSlot, icon: const Icon(Icons.crop_7_5), tooltip: 'Add slot'),
                        IconButton(onPressed: _addRect, icon: const Icon(Icons.crop_square), tooltip: 'Add rectangle'),
                        IconButton(onPressed: _showQuickHoleDialog, icon: const Icon(Icons.grid_4x4), tooltip: 'Quick 4-hole pattern'),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Shift all'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 70,
                      child: TextField(
                        controller: _shiftDistanceController,
                        decoration: const InputDecoration(labelText: 'mm', isDense: true, border: OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => _shiftAllHoles(0, 1),
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: 'Shift all holes up',
                    ),
                    IconButton(
                      onPressed: () => _shiftAllHoles(0, -1),
                      icon: const Icon(Icons.arrow_downward),
                      tooltip: 'Shift all holes down',
                    ),
                    IconButton(
                      onPressed: () => _shiftAllHoles(-1, 0),
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Shift all holes left',
                    ),
                    IconButton(
                      onPressed: () => _shiftAllHoles(1, 0),
                      icon: const Icon(Icons.arrow_forward),
                      tooltip: 'Shift all holes right',
                    ),
                  ],
                ),
                for (final hole in _controller.holes) _holeRow(hole.id),
                ],
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ColoredBox(
              color: canvasBackground(context),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.biggest;
                  _canvasSize = size;
                  return AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => Stack(children: [
                      Listener(
                        // Wheel zooms about the cursor; middle- or right-drag pans (the
                        // primary button is left to drawing and selecting).
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent) {
                            _zoomBy(math.pow(1.0015, -event.scrollDelta.dy).toDouble(), event.localPosition, size);
                          }
                        },
                        onPointerMove: (event) {
                          if (event.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0) {
                            _panViewBy(event.delta, size);
                          }
                        },
                        child: MouseRegion(
                      cursor: _controller.measureMode || (_drawTool != null && _controller.layer == TemplateMakerLayer.drawing)
                          ? SystemMouseCursors.precise
                          : MouseCursor.defer,
                      onHover: (event) => _onPreviewHover(event, size),
                      onExit: (event) {
                        // Leaving the window mid-drag can lose the mouse-up, so end the
                        // drag there; moving onto the side panel keeps dragging.
                        final window = MediaQuery.sizeOf(context);
                        final p = event.position;
                        final leftWindow = p.dx <= 2 || p.dy <= 2 || p.dx >= window.width - 2 || p.dy >= window.height - 2;
                        if (_dragActive && leftWindow) {
                          _finishDrag();
                        } else if (_measureHover != null) {
                          setState(() => _measureHover = null);
                        }
                      },
                      // Clicks and drags come from raw pointer events rather than a
                      // GestureDetector: on Windows a mouse-up sometimes never arrives, and
                      // the tap/pan recognizers then stay stuck on that press -- every later
                      // drag reports the stale press position and never ends. Here a new
                      // press always starts fresh.
                      child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onCanvasPointerDown,
                      onPointerMove: (event) => _onCanvasPointerMove(event, size),
                      onPointerUp: (event) => _onCanvasPointerUp(event, size),
                      onPointerCancel: _onCanvasPointerCancel,
                      child: ClipRect(
                        child: CustomPaint(
                        painter: TemplateOutlinePainter(
                          viewRectMm: _currentView(),
                          drawingMode: _controller.layer == TemplateMakerLayer.drawing,
                          notes: _controller.notes,
                          selectedNoteId: _controller.selectedNoteId,
                          selectedNoteIds: {..._controller.selectedNoteIds},
                          selectionRectMm: () {
                            final a = _marqueeStart, b = _marqueeEnd;
                            return a == null || b == null
                                ? null
                                : Rect.fromLTRB(math.min(a.x, b.x), math.min(a.y, b.y), math.max(a.x, b.x), math.max(a.y, b.y));
                          }(),
                          holeHandles: () {
                            final h = _controller.holes.where((e) => e.id == _controller.selectedHoleId).firstOrNull;
                            return h == null || _controller.layer == TemplateMakerLayer.drawing
                                ? const <Vec2>[]
                                : [for (final handle in _controller.holeHandles(h)) handle.point];
                          }(),
                          noteHandles: () {
                            final n = _controller.notes.where((e) => e.id == _controller.selectedNoteId).firstOrNull;
                            return n == null || _controller.layer != TemplateMakerLayer.drawing || _controller.selectedNoteIds.length > 1
                                ? const <Vec2>[]
                                : [for (final h in _controller.noteHandles(n)) h.point];
                          }(),
                          ghostNotes: _controller.layer != TemplateMakerLayer.drawing,
                          showGrid: _controller.showGrid,
                          gridMm: _controller.gridMm,
                          guideX: _guideX,
                          guideY: _guideY,
                          isDark: Theme.of(context).brightness == Brightness.dark,
                          measureStart: _controller.measureStart,
                          measureEnd: _controller.measureEnd,
                          measureHover: _controller.measureMode ? _measureHover : null,
                          image: _controller.refImage,
                          imageRectMm: Rect.fromLTWH(
                              _controller.imageX, _controller.imageY, _controller.imageWidth, _controller.imageHeight),
                          imageOpacity: _controller.imageOpacity,
                          outlineWidth: _controller.outlineWidth,
                          outlineHeight: _controller.outlineHeight,
                          cornerStyle: _controller.cornerStyle,
                          cornerSize: _controller.cornerSize,
                          useCustomOutline: _controller.useCustomOutline,
                          customOutlinePoints: [for (final v in _controller.customOutlinePoints) v.position],
                          customOutlineDisplayPoints: _controller.customOutlineDisplayPoints(),
                          selectedOutlinePointIndex: _controller.selectedOutlinePointIndex,
                          holes: [
                            for (final h in _controller.holes)
                              (
                                shape: h.shape,
                                center: Vec2(h.x, h.y),
                                diameter: h.diameter,
                                slotLength: h.slotLength,
                                slotWidth: h.slotWidth,
                                rotationDeg: h.rotationDeg,
                                selected: h.id == _controller.selectedHoleId,
                              ),
                          ],
                        ),
                        size: size,
                      ),
                      ),
                    ),
                    ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _zoomControls(size),
                      ),
                      if (_editingNoteId != null && _controller.layer == TemplateMakerLayer.drawing)
                        for (final n in _controller.notes.where((n) => n.id == _editingNoteId))
                          _canvasTextEditor(size, n),
                    ]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoomControls(Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove, size: 20),
            tooltip: 'Zoom out (Ctrl -)',
            onPressed: () => _zoomBy(1 / 1.25, centre, size),
          ),
          SizedBox(
            width: 48,
            child: Text('${(_zoom * 100).round()}%', textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            tooltip: 'Zoom in (Ctrl +)',
            onPressed: () => _zoomBy(1.25, centre, size),
          ),
          IconButton(
            icon: const Icon(Icons.fit_screen, size: 20),
            tooltip: 'Fit the plate (Ctrl 0). Scroll wheel zooms at the cursor; middle- or right-drag pans.',
            onPressed: _zoomFit,
          ),
        ],
      ),
    );
  }

  // ---- layers + drawing layer ----

  Widget _layerSelector(BuildContext context) {
    final c = _controller;
    final isBox = c.category == TemplateCategory.box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<TemplateMakerLayer>(
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(value: TemplateMakerLayer.layer1, label: Text('Layer 1')),
            ButtonSegment(value: TemplateMakerLayer.layer2, label: const Text('Layer 2'), enabled: c.dualLayer),
            ButtonSegment(value: TemplateMakerLayer.drawing, label: const Text('Drawing'), enabled: !isBox),
          ],
          selected: {c.layer},
          onSelectionChanged: (selection) => setState(() {
            _endTextEdit();
            _drawTool = null;
            c.selectLayer(selection.first);
            _syncHoleControllers();
            _refreshTopFields();
          }),
        ),
        if (isBox)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Two-layer plate'),
            subtitle: const Text('Layer 2 sits beside layer 1 in the design and exports as its own object.'),
            value: c.dualLayer,
            onChanged: (v) => setState(() {
              c.setDualLayer(v ?? false);
              _syncHoleControllers();
              _refreshTopFields();
            }),
          ),
      ],
    );
  }

  /// The handle of [h] under [mm], if any (the nearest when several are close).
  HoleHandle? _holeHandleAt(TemplateMakerHole h, Vec2 mm, double scale) {
    final tol = 10 / scale;
    HoleHandle? best;
    var bestDist = double.infinity;
    for (final handle in _controller.holeHandles(h)) {
      final dx = handle.point.x - mm.x, dy = handle.point.y - mm.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d <= tol && d < bestDist) {
        bestDist = d;
        best = handle.handle;
      }
    }
    return best;
  }

  /// The handle of [n] under [mm], if any (the nearest when several are close).
  NoteHandle? _noteHandleAt(TemplateMakerNote n, Vec2 mm, double scale) {
    final tol = 10 / scale;
    NoteHandle? best;
    var bestDist = double.infinity;
    for (final h in _controller.noteHandles(n)) {
      final dx = h.point.x - mm.x, dy = h.point.y - mm.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d <= tol && d < bestDist) {
        bestDist = d;
        best = h.handle;
      }
    }
    return best;
  }

  TemplateMakerNote? _noteAt(Vec2 mm, double scale) {
    final tol = 10 / scale;
    for (final n in _controller.notes.reversed) {
      final hit = switch (n.type) {
        AnnotationType.text => () {
            final local = mm.subtract(Vec2(n.x, n.y)).rotated(-n.rotationDeg);
            final w = noteTextWidthMm(n);
            return local.x >= -tol && local.x <= w + tol && local.y >= -tol && local.y <= n.height + tol;
          }(),
        AnnotationType.line => _distToSegment(mm, Vec2(n.x, n.y), Vec2(n.x2, n.y2)) <= tol,
        AnnotationType.rect => mm.x >= n.x - tol && mm.x <= n.x + n.width + tol && mm.y >= n.y - tol && mm.y <= n.y + n.height + tol,
        AnnotationType.circle => math.sqrt(math.pow(mm.x - n.x, 2) + math.pow(mm.y - n.y, 2)) <= n.radius + tol,
      };
      if (hit) return n;
    }
    return null;
  }

  double _distToSegment(Vec2 p, Vec2 a, Vec2 b) {
    final abx = b.x - a.x, aby = b.y - a.y;
    final lenSq = abx * abx + aby * aby;
    var t = lenSq == 0 ? 0.0 : ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq;
    t = t.clamp(0.0, 1.0);
    final dx = p.x - (a.x + abx * t), dy = p.y - (a.y + aby * t);
    return math.sqrt(dx * dx + dy * dy);
  }

  String _noteValue(TemplateMakerNote n, String field) => switch (field) {
        'text' => n.text,
        'x' => _fmt(n.x),
        'y' => _fmt(n.y),
        'x2' => _fmt(n.x2),
        'y2' => _fmt(n.y2),
        'width' => _fmt(n.width),
        'height' => _fmt(n.height),
        'radius' => _fmt(n.radius),
        _ => _fmt(n.rotationDeg),
      };

  void _refreshNoteFields() {
    for (final n in _controller.notes) {
      for (final field in const ['x', 'y', 'x2', 'y2', 'width', 'height', 'radius', 'rotation']) {
        _noteFields['${n.id}/$field']?.text = _noteValue(n, field);
      }
    }
  }

  void _applyNote(String id, String field, double v) {
    final c = _controller;
    switch (field) {
      case 'x':
        c.updateNote(id, x: v);
      case 'y':
        c.updateNote(id, y: v);
      case 'x2':
        c.updateNote(id, x2: v);
      case 'y2':
        c.updateNote(id, y2: v);
      case 'width':
        c.updateNote(id, width: v);
      case 'height':
        c.updateNote(id, height: v);
      case 'radius':
        c.updateNote(id, radius: v);
      default:
        c.updateNote(id, rotationDeg: v);
    }
  }

  Widget _noteField(TemplateMakerNote n, String field, String label) {
    final isText = field == 'text';
    final controller = _noteFields.putIfAbsent('${n.id}/$field', () => TextEditingController(text: _noteValue(n, field)));
    void commit() {
      if (isText) return;
      _commitMathField(controller, (v) => _applyNote(n.id, field, v));
    }

    return TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      keyboardType: isText ? TextInputType.text : const TextInputType.numberWithOptions(decimal: true, signed: true),
      onTap: () => setState(() => _controller.selectNote(n.id)),
      onChanged: (v) {
        if (isText) {
          setState(() => _controller.updateNote(n.id, text: v));
          return;
        }
        final parsed = tryEvalMath(v);
        if (parsed != null) setState(() => _applyNote(n.id, field, parsed));
      },
      onSubmitted: (_) => commit(),
      onEditingComplete: commit,
      onTapOutside: (_) => commit(),
    );
  }

  List<Widget> _drawingSectionWidgets(BuildContext context) {
    final live = _controller.notes.map((n) => n.id).toSet();
    _noteFields.removeWhere((key, c) {
      final stale = !live.contains(key.split('/').first);
      if (stale) c.dispose();
      return stale;
    });
    Widget drawTool(AnnotationType type, IconData icon, String label) {
      final active = _drawTool == type;
      final button = OutlinedButton.icon(
        onPressed: () => setState(() => _drawTool = active ? null : type),
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: active
            ? OutlinedButton.styleFrom(
                backgroundColor: Colors.lightBlue.withValues(alpha: 0.2),
                side: const BorderSide(color: Colors.lightBlue, width: 2),
              )
            : null,
      );
      return Tooltip(message: 'Drag on the canvas to draw a ${label.toLowerCase()}', child: button);
    }

    return [
      const Divider(height: 32),
      Text('Drawing layer', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Notes that show how this item is placed. They appear on the canvas, PDF and DXF but are never cut or printed.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          drawTool(AnnotationType.text, Icons.text_fields, 'Text'),
          drawTool(AnnotationType.line, Icons.horizontal_rule, 'Line'),
          drawTool(AnnotationType.rect, Icons.crop_square, 'Rectangle'),
          drawTool(AnnotationType.circle, Icons.circle_outlined, 'Circle'),
        ],
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton.icon(
            onPressed: _controller.notes.isEmpty ? null : () => setState(_controller.selectAllNotes),
            icon: const Icon(Icons.select_all, size: 18),
            label: const Text('Select all'),
          ),
          TextButton.icon(
            onPressed: _controller.selectedNoteIds.isEmpty ? null : () => setState(_controller.deleteSelectedNotes),
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: Text(_controller.selectedNoteIds.length > 1
                ? 'Delete ${_controller.selectedNoteIds.length} selected'
                : 'Delete selected'),
          ),
        ],
      ),
      Text(
        'Drag a box on empty canvas, or Shift/Ctrl+click, to select several. Delete removes them all.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (_drawTool != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Drag on the canvas to draw. Esc, or clicking the highlighted tool again, goes back to selecting and moving.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      for (final n in _controller.notes) _noteRow(context, n),
    ];
  }

  Widget _noteRow(BuildContext context, TemplateMakerNote n) {
    final selected = _controller.selectedNoteIds.contains(n.id);
    final title = switch (n.type) {
      AnnotationType.text => 'Text',
      AnnotationType.line => 'Line',
      AnnotationType.rect => 'Rectangle',
      AnnotationType.circle => 'Circle',
    };
    Widget pair(Widget a, Widget b) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [Expanded(child: a), const SizedBox(width: 6), Expanded(child: b)]),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _additiveKey ? _controller.toggleNoteSelection(n.id) : _controller.selectNote(n.id)),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: selected ? Colors.lightBlue.withValues(alpha: 0.12) : null,
            border: Border.all(color: selected ? Colors.lightBlue : Colors.transparent, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelMedium),
                  const Spacer(),
                  IconButton(
                    onPressed: () => setState(() => _controller.duplicateNote(n.id)),
                    icon: const Icon(Icons.content_copy_outlined, size: 20),
                    tooltip: 'Duplicate ${title.toLowerCase()}',
                  ),
                  IconButton(
                    onPressed: () => setState(() => _controller.removeNote(n.id)),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove ${title.toLowerCase()}',
                  ),
                ],
              ),
              if (n.type == AnnotationType.text) ...[
                _noteField(n, 'text', 'Text'),
                pair(_noteField(n, 'x', 'X'), _noteField(n, 'y', 'Y')),
                pair(_noteField(n, 'height', 'Height'), _noteField(n, 'rotation', 'Rotation\u00b0')),
              ],
              if (n.type == AnnotationType.line) ...[
                pair(_noteField(n, 'x', 'X1'), _noteField(n, 'y', 'Y1')),
                pair(_noteField(n, 'x2', 'X2'), _noteField(n, 'y2', 'Y2')),
              ],
              if (n.type == AnnotationType.rect) ...[
                pair(_noteField(n, 'x', 'X'), _noteField(n, 'y', 'Y')),
                pair(_noteField(n, 'width', 'Width'), _noteField(n, 'height', 'Height')),
              ],
              if (n.type == AnnotationType.circle) ...[
                pair(_noteField(n, 'x', 'X'), _noteField(n, 'y', 'Y')),
                Padding(padding: const EdgeInsets.only(top: 6), child: _noteField(n, 'radius', 'Radius')),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _holeRow(String holeId) {
    final hole = _controller.holes.firstWhere((h) => h.id == holeId);
    final isSlot = hole.shape != TemplateMakerHoleShape.round;
    final isRect = hole.shape == TemplateMakerHoleShape.rect;
    final selected = _controller.selectedHoleId == holeId;
    final scheme = Theme.of(context).colorScheme;
    void select() {
      if (_controller.selectedHoleId != holeId) setState(() => _controller.selectHole(holeId));
    }

    return Padding(
      key: _holeRowKeys.putIfAbsent(holeId, GlobalKey.new),
      padding: const EdgeInsets.only(top: 8),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (hasFocus) {
          if (hasFocus) select();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: select,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: selected ? Colors.lightBlue.withValues(alpha: 0.12) : null,
              border: Border.all(color: selected ? Colors.lightBlue : scheme.outlineVariant.withValues(alpha: 0.0), width: selected ? 2 : 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(isRect ? 'Rectangle' : isSlot ? 'Slot' : 'Round hole', style: Theme.of(context).textTheme.labelMedium),
              const Spacer(),
              if (_controller.canCopyToOtherLayer)
                IconButton(
                  onPressed: () {
                    final toLayer = _controller.layer == TemplateMakerLayer.layer1 ? 2 : 1;
                    setState(() => _controller.copyHoleToOtherLayer(holeId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Copied to layer $toLayer'), duration: const Duration(seconds: 2)),
                    );
                  },
                  icon: const Icon(Icons.file_copy_outlined, size: 20),
                  tooltip: 'Copy ${isRect ? 'rectangle' : isSlot ? 'slot' : 'hole'} to layer ${_controller.layer == TemplateMakerLayer.layer1 ? 2 : 1}',
                ),
              IconButton(
                onPressed: () => setState(() {
                  _controller.duplicateHole(holeId);
                  _syncHoleControllers();
                  _refreshTopFields();
                }),
                icon: const Icon(Icons.content_copy_outlined, size: 20),
                tooltip: 'Duplicate ${isRect ? 'rectangle' : isSlot ? 'slot' : 'hole'} on this layer',
              ),
              IconButton(
                onPressed: () => _removeHole(holeId),
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Remove ${isRect ? 'rectangle' : isSlot ? 'slot' : 'hole'}',
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _holeX[holeId],
                  focusNode: _holeXFocus[holeId],
                  decoration: const InputDecoration(labelText: 'X', isDense: true, border: OutlineInputBorder()),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    final parsed = tryEvalMath(v);
                    if (parsed != null) setState(() => _controller.updateHole(holeId, x: parsed));
                  },
                  onSubmitted: (_) => _commitMathField(_holeX[holeId]!, (v) => _controller.updateHole(holeId, x: v)),
                  onEditingComplete: () => _commitMathField(_holeX[holeId]!, (v) => _controller.updateHole(holeId, x: v)),
                  onTapOutside: (_) {
                    _commitMathField(_holeX[holeId]!, (v) => _controller.updateHole(holeId, x: v));
                    _holeXFocus[holeId]?.unfocus();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _holeY[holeId],
                  focusNode: _holeYFocus[holeId],
                  decoration: const InputDecoration(labelText: 'Y', isDense: true, border: OutlineInputBorder()),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    final parsed = tryEvalMath(v);
                    if (parsed != null) setState(() => _controller.updateHole(holeId, y: parsed));
                  },
                  onSubmitted: (_) => _commitMathField(_holeY[holeId]!, (v) => _controller.updateHole(holeId, y: v)),
                  onEditingComplete: () => _commitMathField(_holeY[holeId]!, (v) => _controller.updateHole(holeId, y: v)),
                  onTapOutside: (_) {
                    _commitMathField(_holeY[holeId]!, (v) => _controller.updateHole(holeId, y: v));
                    _holeYFocus[holeId]?.unfocus();
                  },
                ),
              ),
              const SizedBox(width: 6),
              if (!isSlot)
                Expanded(
                  child: TextField(
                    controller: _holeD[holeId],
                    focusNode: _holeDFocus[holeId],
                    decoration: const InputDecoration(labelText: 'Dia', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final parsed = tryEvalMath(v);
                      if (parsed != null) setState(() => _controller.updateHole(holeId, diameter: parsed));
                    },
                    onSubmitted: (_) => _commitMathField(_holeD[holeId]!, (v) => _controller.updateHole(holeId, diameter: v)),
                    onEditingComplete: () => _commitMathField(_holeD[holeId]!, (v) => _controller.updateHole(holeId, diameter: v)),
                    onTapOutside: (_) {
                      _commitMathField(_holeD[holeId]!, (v) => _controller.updateHole(holeId, diameter: v));
                      _holeDFocus[holeId]?.unfocus();
                    },
                  ),
                ),
            ],
          ),
          if (isSlot) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _holeLen[holeId],
                    focusNode: _holeLenFocus[holeId],
                    decoration: const InputDecoration(labelText: 'Length', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final parsed = tryEvalMath(v);
                      if (parsed != null) setState(() => _controller.updateHole(holeId, slotLength: parsed));
                    },
                    onSubmitted: (_) => _commitMathField(_holeLen[holeId]!, (v) => _controller.updateHole(holeId, slotLength: v)),
                    onEditingComplete: () => _commitMathField(_holeLen[holeId]!, (v) => _controller.updateHole(holeId, slotLength: v)),
                    onTapOutside: (_) {
                      _commitMathField(_holeLen[holeId]!, (v) => _controller.updateHole(holeId, slotLength: v));
                      _holeLenFocus[holeId]?.unfocus();
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _holeWidth[holeId],
                    focusNode: _holeWidthFocus[holeId],
                    decoration: const InputDecoration(labelText: 'Width', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final parsed = tryEvalMath(v);
                      if (parsed != null) setState(() => _controller.updateHole(holeId, slotWidth: parsed));
                    },
                    onSubmitted: (_) => _commitMathField(_holeWidth[holeId]!, (v) => _controller.updateHole(holeId, slotWidth: v)),
                    onEditingComplete: () => _commitMathField(_holeWidth[holeId]!, (v) => _controller.updateHole(holeId, slotWidth: v)),
                    onTapOutside: (_) {
                      _commitMathField(_holeWidth[holeId]!, (v) => _controller.updateHole(holeId, slotWidth: v));
                      _holeWidthFocus[holeId]?.unfocus();
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _holeRotation[holeId],
                    focusNode: _holeRotationFocus[holeId],
                    decoration: const InputDecoration(labelText: 'Rotation°', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    onChanged: (v) {
                      final parsed = tryEvalMath(v);
                      if (parsed != null) setState(() => _controller.updateHole(holeId, rotationDeg: parsed));
                    },
                    onSubmitted: (_) => _commitMathField(_holeRotation[holeId]!, (v) => _controller.updateHole(holeId, rotationDeg: v)),
                    onEditingComplete: () => _commitMathField(_holeRotation[holeId]!, (v) => _controller.updateHole(holeId, rotationDeg: v)),
                    onTapOutside: (_) {
                      _commitMathField(_holeRotation[holeId]!, (v) => _controller.updateHole(holeId, rotationDeg: v));
                      _holeRotationFocus[holeId]?.unfocus();
                    },
                  ),
                ),
              ],
            ),
          ],
          const Divider(height: 16),
        ],
            ),
          ),
        ),
      ),
    );
  }
}
