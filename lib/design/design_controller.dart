import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../geometry/placed_entities.dart';
import '../geometry/tessellate.dart';
import '../geometry/transform.dart';
import '../models/box_project.dart';
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

  PlacedTemplate? _clipboardTemplate;
  Hole? _clipboardHole;

  static const Vec2 _pasteOffset = Vec2(10, 10);

  String _newId(String prefix) => '$prefix-${_nextId++}';

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

  /// Applies [templateId] (a box-category template) as the enclosure
  /// outline, normalizing its geometry so the bounding box's min corner
  /// sits at (0, 0) — the coordinate frame everything else is placed in.
  void applyBoxTemplate(String templateId) {
    final template = library.byId(templateId);
    if (template == null) return;
    final box = template.boundingBox;
    final normalized = placeEntities(template.entities, delta: Vec2(-box.minX, -box.minY));
    project = project.copyWith(boxTemplateId: templateId, boxOutline: normalized);
    _clampIntoBox();
    notifyListeners();
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

  /// Keeps every hole and placed template entirely within the box outline's
  /// bounding box: an item dropped, dragged, typed or loaded outside it is
  /// pushed back in (it can't be seen, selected or cut out there anyway).
  /// An item larger than the box is aligned to the box's min corner.
  void _clampIntoBox() {
    if (project.boxOutline.isEmpty) return;
    final box = entitiesBoundingBox(project.boxOutline);
    Vec2 shiftFor(BoundingBox b) {
      double axis(double min, double max, double boxMin, double boxMax) {
        if (min < boxMin - 1e-9) return boxMin - min;
        if (max > boxMax + 1e-9) return math.max(boxMax - max, boxMin - min);
        return 0;
      }

      return Vec2(axis(b.minX, b.maxX, box.minX, box.maxX), axis(b.minY, b.maxY, box.minY, box.maxY));
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
