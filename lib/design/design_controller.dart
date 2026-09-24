import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../geometry/placed_entities.dart';
import '../geometry/tessellate.dart';
import '../geometry/transform.dart';
import '../models/box_project.dart';
import '../models/dxf_entity.dart';
import '../models/hole.dart';
import '../models/hole_preset.dart';
import '../models/placed_template.dart';
import '../models/vec2.dart';
import '../services/template_library.dart';

/// Owns the [BoxProject] being edited and all mutation/selection state for
/// the canvas and property panel.
class DesignController extends ChangeNotifier {
  final TemplateLibrary library;

  DesignController(this.library) {
    library.addListener(notifyListeners);
  }

  BoxProject project = BoxProject();
  String? selectedId;
  int _nextId = 1;

  bool measureModeEnabled = false;
  Vec2? measureStart;
  Vec2? measureEnd;

  /// When set, dragging a placed template or hole snaps its position to
  /// this grid size (mm); null means free placement (no snapping).
  double? snapToGridMm = 1.0;
  static const snapToGridOptionsMm = [1.0, 2.0, 5.0, 10.0, 20.0];

  void setSnapToGridMm(double? value) {
    snapToGridMm = value;
    notifyListeners();
  }

  /// Rounds [position] to the nearest [snapToGridMm] multiple, or returns
  /// it unchanged when snapping is off.
  Vec2 snapToGrid(Vec2 position) {
    final grid = snapToGridMm;
    if (grid == null) return position;
    double roundTo(double v) => (v / grid).round() * grid;
    return Vec2(roundTo(position.x), roundTo(position.y));
  }

  PlacedTemplate? _clipboardTemplate;
  Hole? _clipboardHole;

  static const Vec2 _pasteOffset = Vec2(10, 10);

  String _newId(String prefix) => '$prefix-${_nextId++}';

  /// Bumps [_nextId] past every numeric suffix already used by [loaded]'s
  /// placed templates and holes, so newly created items can never reuse an
  /// id a loaded project brought with it. Without this, `_nextId` kept
  /// counting from wherever it happened to be (1, for a freshly launched
  /// app) regardless of what the loaded project already contained, so
  /// adding a new hole/template after opening a project could mint an id
  /// (e.g. "hole-4") that collides with one already in the file — and two
  /// items sharing an id both render as selected whenever either is
  /// clicked, since selection is just an `id == selectedId` match.
  void _resyncNextId(BoxProject loaded) {
    var maxSeen = 0;
    for (final id in [
      ...loaded.placedTemplates.map((p) => p.id),
      ...loaded.holes.map((h) => h.id),
    ]) {
      final suffix = int.tryParse(id.split('-').last);
      if (suffix != null && suffix > maxSeen) maxSeen = suffix;
    }
    if (maxSeen >= _nextId) _nextId = maxSeen + 1;
  }

  /// Copies the selected placed template or hole to an internal clipboard,
  /// ready for [pasteClipboard].
  void copySelected() {
    final template = selectedTemplate;
    if (template != null) {
      _clipboardTemplate = template;
      _clipboardHole = null;
      return;
    }
    final hole = selectedHole;
    if (hole != null) {
      _clipboardHole = hole;
      _clipboardTemplate = null;
    }
  }

  /// Pastes whatever [copySelected] last captured as a new item, offset
  /// from the original so the copy is visibly distinct, and selects it.
  void pasteClipboard() {
    final template = _clipboardTemplate;
    if (template != null) {
      final copy = PlacedTemplate(
        id: _newId('placed'),
        templateId: template.templateId,
        position: template.position.add(_pasteOffset),
        rotationDeg: template.rotationDeg,
      );
      project = project.copyWith(placedTemplates: [...project.placedTemplates, copy]);
      selectedId = copy.id;
      _clampIntoBox();
      notifyListeners();
      return;
    }
    final hole = _clipboardHole;
    if (hole != null) {
      final copy = Hole(
        id: _newId('hole'),
        type: hole.type,
        position: hole.position.add(_pasteOffset),
        rotationDeg: hole.rotationDeg,
        diameter: hole.diameter,
        slotLength: hole.slotLength,
        slotWidth: hole.slotWidth,
      );
      project = project.copyWith(holes: [...project.holes, copy]);
      selectedId = copy.id;
      _clampIntoBox();
      notifyListeners();
    }
  }

  void toggleMeasureMode() {
    measureModeEnabled = !measureModeEnabled;
    measureStart = null;
    measureEnd = null;
    notifyListeners();
  }

  /// Click-to-measure (no dragging): the first click sets the starting
  /// point, the second sets the end point and completes the measurement,
  /// and a further click starts a brand new measurement from scratch.
  void placeMeasurePoint(Vec2 mm) {
    if (measureStart == null || measureEnd != null) {
      measureStart = mm;
      measureEnd = null;
    } else {
      measureEnd = mm;
    }
    notifyListeners();
  }

  void startMeasure(Vec2 mm) {
    measureStart = mm;
    measureEnd = mm;
    notifyListeners();
  }

  void updateMeasure(Vec2 mm) {
    if (measureStart == null) return;
    measureEnd = mm;
    notifyListeners();
  }

  List<DxfEntity> _normalized(List<DxfEntity> entities) {
    final b = entitiesBoundingBox(entities);
    return placeEntities(entities, delta: Vec2(-b.minX, -b.minY));
  }

  /// Applies [templateId] (a box-category template) as the box, normalizing
  /// its geometry so the bounding box's min corner sits at (0, 0) -- the
  /// coordinate frame everything else is placed in. The template decides the
  /// layer count: one with a second layer gives a two-layer project, any other
  /// gives a one-layer project (dropping whatever sat on the old plate 2).
  /// Items on a plate that changes size or moves come along with it.
  void applyBoxTemplate(String templateId) {
    final template = library.byId(templateId);
    if (template == null) return;
    final outline = _normalized(template.entities);
    final layer2 = template.layer2Entities;
    final BoxProject next;
    if (layer2 != null && layer2.isNotEmpty) {
      next = project.copyWith(
        boxTemplateId: templateId,
        boxOutline: outline,
        layer2TemplateId: templateId,
        layer2Outline: _normalized(layer2),
      );
    } else {
      _dropPlate2Items();
      next = project.copyWith(boxTemplateId: templateId, boxOutline: outline, clearLayer2: true);
    }
    _reflowInto(next);
    _clampIntoBox();
    notifyListeners();
  }

  /// Whether applying [templateId] would delete items sitting on plate 2
  /// (it is a one-layer template and the project is currently two-layer).
  int itemsLostByApplying(String templateId) {
    final layer2 = library.byId(templateId)?.layer2Entities;
    return layer2 != null && layer2.isNotEmpty ? 0 : itemsOnLayer2;
  }

  Vec2 _center(BoundingBox b) => Vec2((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2);

  /// Switches to [next]'s plates, carrying every item along with the plate
  /// it sits on (a plate that moved or was replaced shifts its items by the
  /// change in its own origin).
  void _reflowInto(BoxProject next) {
    final oldBoxes = project.plateBoxes;
    final newBoxes = next.plateBoxes;
    Vec2 shiftFor(Vec2 c) {
      final i = project.plateIndexForPoint(c);
      final j = math.min(i, newBoxes.length - 1);
      return Vec2(newBoxes[j].minX - oldBoxes[i].minX, newBoxes[j].minY - oldBoxes[i].minY);
    }

    final placed = [
      for (final p in project.placedTemplates)
        () {
          final template = library.byId(p.templateId);
          final c = template == null ? p.position : _center(entitiesBoundingBox(placedTemplateEntities(template, p)));
          return p.copyWith(position: p.position.add(shiftFor(c)));
        }(),
    ];
    final holes = [for (final h in project.holes) h.copyWith(position: h.position.add(shiftFor(_center(h.boundingBox))))];
    project = next.copyWith(placedTemplates: placed, holes: holes);
  }

  /// How many holes/templates currently sit on plate 2.
  int get itemsOnLayer2 {
    if (!project.dualLayer) return 0;
    var n = 0;
    for (final p in project.placedTemplates) {
      final t = library.byId(p.templateId);
      final c = t == null ? p.position : _center(entitiesBoundingBox(placedTemplateEntities(t, p)));
      if (project.plateIndexForPoint(c) == 1) n++;
    }
    for (final h in project.holes) {
      if (project.plateIndexForPoint(_center(h.boundingBox)) == 1) n++;
    }
    return n;
  }

  /// Removes every hole/template that sits on plate 2 (no-op for a one-layer
  /// project).
  void _dropPlate2Items() {
    if (!project.dualLayer) return;
    bool onPlate2(Vec2 c) => project.plateIndexForPoint(c) == 1;
    final placed = [
      for (final p in project.placedTemplates)
        if (!onPlate2(() {
          final t = library.byId(p.templateId);
          return t == null ? p.position : _center(entitiesBoundingBox(placedTemplateEntities(t, p)));
        }()))
          p,
    ];
    final holes = [for (final h in project.holes) if (!onPlate2(_center(h.boundingBox))) h];
    project = project.copyWith(placedTemplates: placed, holes: holes);
    if (selectedId != null && !placed.any((p) => p.id == selectedId) && !holes.any((h) => h.id == selectedId)) selectedId = null;
  }

  void setPlateThicknessMm(double value) {
    if (value <= 0) return;
    project = project.copyWith(plateThicknessMm: value);
    notifyListeners();
  }

  void setAddStandoffs(bool value) {
    project = project.copyWith(addStandoffs: value);
    notifyListeners();
  }

  void setStandoffHeightMm(double value) {
    if (value <= 0) return;
    project = project.copyWith(standoffHeightMm: value);
    notifyListeners();
  }

  void setStandoffWallThicknessMm(double value) {
    if (value <= 0) return;
    project = project.copyWith(standoffWallThicknessMm: value);
    notifyListeners();
  }

  void newProject() {
    final defaultBox = library.defaultBoxTemplate;
    project = BoxProject(
      boxTemplateId: defaultBox?.id,
      boxOutline: defaultBox == null
          ? null
          : placeEntities(defaultBox.entities, delta: Vec2(-defaultBox.boundingBox.minX, -defaultBox.boundingBox.minY)),
    );
    selectedId = null;
    notifyListeners();
  }

  void loadProject(BoxProject loaded) {
    project = loaded;
    selectedId = null;
    _resyncNextId(loaded);
    _clampIntoBox();
    notifyListeners();
  }

  void select(String? id) {
    selectedId = id;
    notifyListeners();
  }

  void addPlacedTemplate(String templateId, Vec2 position) {
    final placed = PlacedTemplate(
      id: _newId('placed'),
      templateId: templateId,
      position: position,
    );
    project = project.copyWith(placedTemplates: [...project.placedTemplates, placed]);
    selectedId = placed.id;
    _clampIntoBox();
    notifyListeners();
  }

  void movePlacedTemplate(String id, Vec2 newPosition) {
    project = project.copyWith(
      placedTemplates: [
        for (final p in project.placedTemplates)
          if (p.id == id) p.copyWith(position: newPosition) else p,
      ],
    );
    _clampIntoBox();
    notifyListeners();
  }

  void rotatePlacedTemplate(String id, double rotationDeg) {
    project = project.copyWith(
      placedTemplates: [
        for (final p in project.placedTemplates)
          if (p.id == id) p.copyWith(rotationDeg: rotationDeg) else p,
      ],
    );
    _clampIntoBox();
    notifyListeners();
  }

  /// Resizes every round mounting hole baked into a placed template's own
  /// geometry at once. Pass null to go back to the template's own size.
  void setMountingHoleDiameter(String id, double? diameterMm) {
    project = project.copyWith(
      placedTemplates: [
        for (final p in project.placedTemplates)
          if (p.id == id) p.withHoleDiameterOverride(diameterMm) else p,
      ],
    );
    _clampIntoBox();
    notifyListeners();
  }

  void addHoleFromPreset(HolePreset preset, Vec2 position) {
    final hole = Hole(
      id: _newId('hole'),
      type: preset.type,
      position: position,
      diameter: preset.diameter,
      slotLength: preset.slotLength,
      slotWidth: preset.slotWidth,
    );
    project = project.copyWith(holes: [...project.holes, hole]);
    selectedId = hole.id;
    _clampIntoBox();
    notifyListeners();
  }

  void updateHole(String id, Hole Function(Hole) update) {
    project = project.copyWith(
      holes: [
        for (final h in project.holes)
          if (h.id == id) update(h) else h,
      ],
    );
    _clampIntoBox();
    notifyListeners();
  }

  void deleteSelected() {
    if (selectedId == null) return;
    project = project.copyWith(
      placedTemplates: project.placedTemplates.where((p) => p.id != selectedId).toList(),
      holes: project.holes.where((h) => h.id != selectedId).toList(),
    );
    selectedId = null;
    notifyListeners();
  }

  PlacedTemplate? get selectedTemplate {
    final id = selectedId;
    if (id == null) return null;
    for (final p in project.placedTemplates) {
      if (p.id == id) return p;
    }
    return null;
  }

  Hole? get selectedHole {
    final id = selectedId;
    if (id == null) return null;
    for (final h in project.holes) {
      if (h.id == id) return h;
    }
    return null;
  }

  /// How far (mm) an item may hang past the box outline's bounding box; the
  /// canvas shows this much room around the box.
  static const double overhangMm = 10;

  /// Keeps every hole and placed template within [overhangMm] of the box
  /// outline's bounding box: an item dropped, dragged, typed or loaded further
  /// out is pushed back (it can't be seen or selected out there). A little
  /// overhang is allowed so an item can sit partly off the edge, e.g. a
  /// slot open to the side. An item larger than that is aligned to the
  /// allowance's min corner. A two-layer box gets no overhang: its plates sit
  /// side by side, so an item hanging off one would sit over the other.
  void _clampIntoBox() {
    if (project.boxOutline.isEmpty) return;
    final overhang = project.dualLayer ? 0.0 : overhangMm;
    final boxes = project.plateBoxes;
    Vec2 shiftFor(BoundingBox b) {
      final box = boxes[project.plateIndexForPoint(_center(b))];
      double axis(double min, double max, double boxMin, double boxMax) {
        if (min < boxMin - 1e-9) return boxMin - min;
        if (max > boxMax + 1e-9) return math.max(boxMax - max, boxMin - min);
        return 0;
      }

      return Vec2(
        axis(b.minX, b.maxX, box.minX - overhang, box.maxX + overhang),
        axis(b.minY, b.maxY, box.minY - overhang, box.maxY + overhang),
      );
    }

    var changed = false;
    final placed = [
      for (final p in project.placedTemplates)
        () {
          final template = library.byId(p.templateId);
          if (template == null) return p;
          final shift = shiftFor(entitiesBoundingBox(placedTemplateEntities(template, p)));
          if (shift.x == 0 && shift.y == 0) return p;
          changed = true;
          return p.copyWith(position: p.position.add(shift));
        }(),
    ];
    final holes = [
      for (final h in project.holes)
        () {
          final shift = shiftFor(h.boundingBox);
          if (shift.x == 0 && shift.y == 0) return h;
          changed = true;
          return h.copyWith(position: h.position.add(shift));
        }(),
    ];
    if (changed) project = project.copyWith(placedTemplates: placed, holes: holes);
  }

  @override
  void dispose() {
    library.removeListener(notifyListeners);
    super.dispose();
  }
}
