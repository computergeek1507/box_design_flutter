import 'dart:convert';
import 'dart:typed_data';

import '../dxf/dxf_writer.dart';
import '../geometry/placed_annotations.dart';
import '../geometry/placed_entities.dart';
import '../models/annotation.dart';
import '../models/box_project.dart';
import '../models/dxf_entity.dart';
import '../models/hole.dart';
import 'template_library.dart';

/// Flattens a [BoxProject] into a single absolute-coordinate entity list:
/// the box outline, every placed template's geometry (transformed by its
/// position/rotation), and every hole's cut geometry.
List<DxfEntity> assembleProjectEntities(BoxProject project, TemplateLibrary library) {
  final entities = <DxfEntity>[...project.sheetOutline];

  for (final placed in project.placedTemplates) {
    final template = library.byId(placed.templateId);
    if (template == null) continue;
    entities.addAll(placedTemplateEntities(template, placed));
  }

  for (final hole in project.holes) {
    entities.addAll(hole.toEntities());
  }

  return entities;
}

/// Every placed template's drawing-layer notes, in absolute coordinates.
PlacedNotes assembleProjectNotes(BoxProject project, TemplateLibrary library) {
  final shapes = <DxfEntity>[];
  final texts = <PlacedText>[];
  for (final placed in project.placedTemplates) {
    final template = library.byId(placed.templateId);
    if (template == null) continue;
    final notes = placedTemplateNotes(template, placed);
    shapes.addAll(notes.shapes);
    texts.addAll(notes.texts);
  }
  return PlacedNotes(shapes, texts);
}

/// Same coverage as [assembleProjectEntities], but grouped into named DXF
/// layers instead of one flat list: the box outline and every placed
/// template's non-hole footprint geometry each get their own layer, while
/// every round hole -- whether baked into a placed template (a mounting
/// hole) or a project [Hole] -- is grouped by its own diameter (e.g.
/// "Holes_4.50mm") so a CAM tool can assign one drill bit per layer. Slot
/// and rectangle cutouts, which don't have a single "diameter", get their
/// own size-labeled layer too (by width, or width x length).
Map<String, List<DxfEntity>> assembleProjectLayers(BoxProject project, TemplateLibrary library) {
  final layers = <String, List<DxfEntity>>{};
  void add(String layer, DxfEntity entity) => layers.putIfAbsent(layer, () => []).add(entity);

  final outlines = project.plateOutlines;
  for (var i = 0; i < outlines.length; i++) {
    for (final entity in outlines[i]) {
      add(i == 0 ? 'Outline' : 'Outline_Layer${i + 1}', entity);
    }
  }

  for (final placed in project.placedTemplates) {
    final template = library.byId(placed.templateId);
    if (template == null) continue;
    for (final entity in placedTemplateEntities(template, placed)) {
      if (entity is DxfCircle) {
        add(_holeLayerName(entity.radius * 2), entity);
      } else {
        add('Templates', entity);
      }
    }
  }

  for (final hole in project.holes) {
    switch (hole.type) {
      case HoleType.screw:
        add(_holeLayerName(hole.diameter), hole.toEntities().single);
      case HoleType.zipTie:
        for (final entity in hole.toEntities()) {
          add(_holeLayerName(hole.slotWidth), entity);
        }
      case HoleType.slot:
        add('Slots_${_mmLabel(hole.slotWidth)}mm', hole.toEntities().single);
      case HoleType.rectangle:
        add('Rects_${_mmLabel(hole.slotLength)}x${_mmLabel(hole.slotWidth)}mm', hole.toEntities().single);
    }
  }

  return layers;
}

String _holeLayerName(double diameterMm) => 'Holes_${_mmLabel(diameterMm)}mm';

/// Formats a millimeter size for use in a layer name: fixed to 2 decimal
/// places, then trims trailing zeros (and a trailing '.') so "5" stays "5"
/// while "4.5" stays "4.5" and "3.175" rounds to "3.18".
String _mmLabel(double mm) {
  var s = mm.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

Uint8List exportProjectAsDxfBytes(BoxProject project, TemplateLibrary library) {
  final layers = assembleProjectLayers(project, library);
  final notes = assembleProjectNotes(project, library);
  if (notes.shapes.isNotEmpty) layers['Notes'] = [...notes.shapes];
  final texts = [for (final t in notes.texts) DxfTextItem(t.text, t.anchor.x, t.anchor.y, t.height, t.rotationDeg)];
  return Uint8List.fromList(utf8.encode(writeDxfLayered(layers, texts: texts)));
}
