import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../dxf/dxf_parser.dart';
import '../models/controller_template.dart';
import '../models/vec2.dart';
import '../services/file_io.dart';
import '../services/simple_math.dart';
import '../services/template_library.dart';
import '../widgets/app_colors.dart';
import 'template_maker_controller.dart';
import 'template_outline_painter.dart';

const double _outlinePreviewMargin = 32.0;
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
    _shiftDistanceController.dispose();
    for (final c in [_imageXController, _imageYController, _imageWController, _imageHController]) {
      c.dispose();
    }
    for (final f in [_imageXFocus, _imageYFocus, _imageWFocus, _imageHFocus]) {
      f.dispose();
    }
    _controller.refImage?.dispose();
    _controller.refImage = null;
    _widthFocus.dispose();
    _heightFocus.dispose();
    _cornerSizeFocus.dispose();
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
    final c = _controller;
    var left = 0.0, bottom = 0.0, right = c.outlineWidth, top = c.outlineHeight;
    if (c.refImage != null) {
      left = math.min(left, c.imageX);
      bottom = math.min(bottom, c.imageY);
      right = math.max(right, c.imageX + c.imageWidth);
      top = math.max(top, c.imageY + c.imageHeight);
    }
    return Rect.fromLTRB(left, bottom, right, top);
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

  void _onPreviewPanStart(DragStartDetails details, Size size) {
    if (_controller.measureMode) return;
    _frozenView = null;
    _frozenView = _currentView();
    final scale = _previewScale(size);
    final mm = _previewPxToMm(details.localPosition, size);
    _imageDrag = _ImageDrag.none;
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

  void _onPreviewTapUp(TapUpDetails details, Size size) {
    if (!_controller.measureMode) return;
    setState(() => _controller.placeMeasurePoint(_snapForMeasure(details.localPosition, size)));
  }

  void _onPreviewHover(PointerHoverEvent event, Size size) {
    if (!_controller.measureMode) return;
    setState(() => _measureHover = _snapForMeasure(event.localPosition, size));
  }

  void _onPreviewTapDown(TapDownDetails details, Size size) {
    if (_controller.measureMode) return;
    final hit = _holeNear(_previewPxToMm(details.localPosition, size), _previewScale(size));
    if (hit != null) {
      _selectHoleFromPreview(hit.id);
    } else {
      setState(() => _controller.selectHole(null));
    }
  }

  void _onPreviewPanUpdate(DragUpdateDetails details, Size size) {
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
    final mm = _previewPxToMm(details.localPosition, size);
    setState(() {
      _controller.updateHole(draggingId, x: mm.x, y: mm.y);
      _holeX[draggingId]?.text = _fmt(mm.x);
      _holeY[draggingId]?.text = _fmt(mm.y);
    });
  }

  void _onPreviewPanEnd(DragEndDetails details) {
    _draggingHoleId = null;
    _imageDrag = _ImageDrag.none;
    setState(() => _frozenView = null);
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
    final offsetCtrl = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Quick 4-Hole Pattern'),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Places 4 round holes centered on the outline\'s centerline.'),
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
                TextField(
                  controller: dCtrl,
                  decoration: const InputDecoration(labelText: 'Hole diameter (mm)', isDense: true, border: OutlineInputBorder()),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                ),
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
      setState(() {
        _controller.addQuickHolePattern(
          horizontalSpacing: h,
          verticalSpacing: v,
          diameter: (d != null && d > 0) ? d : 4,
          outlineOffset: offset,
        );
        _syncHoleControllers();
        _refreshTopFields();
      });
    } finally {
      hCtrl.dispose();
      vCtrl.dispose();
      offsetCtrl.dispose();
      dCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    if (v != null) setState(() => _controller.setCategory(v));
                  },
                ),
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
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ColoredBox(
              color: canvasBackground(context),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.biggest;
                  return AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => MouseRegion(
                      cursor: _controller.measureMode ? SystemMouseCursors.precise : MouseCursor.defer,
                      onHover: (event) => _onPreviewHover(event, size),
                      onExit: (_) {
                        if (_measureHover != null) setState(() => _measureHover = null);
                      },
                      child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => _onPreviewTapDown(details, size),
                      onTapUp: (details) => _onPreviewTapUp(details, size),
                      onPanStart: (details) => _onPreviewPanStart(details, size),
                      onPanUpdate: (details) => _onPreviewPanUpdate(details, size),
                      onPanEnd: _onPreviewPanEnd,
                      child: CustomPaint(
                        painter: TemplateOutlinePainter(
                          viewRectMm: _currentView(),
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
                  );
                },
              ),
            ),
          ),
        ],
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
