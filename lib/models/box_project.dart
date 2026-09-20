import '../dxf/dxf_json_codec.dart';
import '../geometry/tessellate.dart';
import '../geometry/transform.dart';
import 'dxf_entity.dart';
import 'hole.dart';
import 'placed_template.dart';
import 'vec2.dart';

/// A simple rectangular fallback outline, used before any real box template
/// has loaded.
List<DxfEntity> defaultRectangleOutline({double width = 150, double height = 90}) {
  return [
    DxfPolyline([
      const PolyVertex(Vec2(0, 0)),
      PolyVertex(Vec2(width, 0)),
      PolyVertex(Vec2(width, height)),
      PolyVertex(Vec2(0, height)),
    ], closed: true),
  ];
}

/// Gap (mm) between the two plates of a two-layer project on the canvas
/// (plate 1 above, plate 2 below).
const double kLayerGapMm = 20;

class BoxProject {
  final String name;

  /// Which box template this outline came from (for display only).
  final String? boxTemplateId;

  /// The enclosure outline, normalized so its bounding box's min corner is
  /// at (0, 0) — everything else (placed templates, holes) is positioned
  /// relative to that.
  final List<DxfEntity> boxOutline;

  /// Two-layer mode: the second plate's box template and its outline, kept
  /// normalized like [boxOutline] (bounding box min corner at (0, 0)); on
  /// the canvas it is shown under plate 1 (see [layer2SheetOutline]).
  /// Null for an ordinary single-plate project.
  final String? layer2TemplateId;
  final List<DxfEntity>? layer2Outline;

  final List<PlacedTemplate> placedTemplates;
  final List<Hole> holes;

  /// 3D/STL/3MF export settings — kept on the project so Save/Open round
  /// trips them instead of resetting to defaults every session.
  final double plateThicknessMm;
  final bool addStandoffs;
  final double standoffHeightMm;
  final double standoffWallThicknessMm;

  BoxProject({
    this.name = 'Untitled Box',
    this.boxTemplateId,
    List<DxfEntity>? boxOutline,
    this.layer2TemplateId,
    this.layer2Outline,
    this.placedTemplates = const [],
    this.holes = const [],
    this.plateThicknessMm = 5,
    this.addStandoffs = false,
    this.standoffHeightMm = 3,
    this.standoffWallThicknessMm = 2,
  }) : boxOutline = boxOutline ?? defaultRectangleOutline();

  bool get dualLayer => layer2Outline != null;

  /// Plate 2's own bounding box.
  BoundingBox get layer2BoundingBox => entitiesBoundingBox(layer2Outline ?? const []);

  /// Plate 1's outline in sheet coordinates: in a two-layer project it is
  /// lifted above plate 2 ([kLayerGapMm] clear of its top edge).
  List<DxfEntity> get layer1SheetOutline {
    if (!dualLayer) return boxOutline;
    return placeEntities(boxOutline, delta: Vec2(0, layer2BoundingBox.height + kLayerGapMm));
  }

  /// Plate 2's outline in sheet coordinates: under plate 1, left-aligned with
  /// it, sitting at the sheet's origin.
  List<DxfEntity> get layer2SheetOutline => layer2Outline ?? const [];

  /// The outline of each plate (one or two), in sheet coordinates.
  List<List<DxfEntity>> get plateOutlines => [layer1SheetOutline, if (dualLayer) layer2SheetOutline];

  List<BoundingBox> get plateBoxes => [for (final o in plateOutlines) entitiesBoundingBox(o)];

  /// Every plate outline together, i.e. everything drawn as "the box".
  List<DxfEntity> get sheetOutline => [for (final o in plateOutlines) ...o];

  /// The index of the plate closest to [p] (0 for a single-plate project).
  int plateIndexForPoint(Vec2 p) {
    final boxes = plateBoxes;
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      final dx = p.x < b.minX ? b.minX - p.x : (p.x > b.maxX ? p.x - b.maxX : 0.0);
      final dy = p.y < b.minY ? b.minY - p.y : (p.y > b.maxY ? p.y - b.maxY : 0.0);
      final d = dx * dx + dy * dy;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// The whole sheet (both plates).
  BoundingBox get boxBoundingBox => entitiesBoundingBox(sheetOutline);
  double get boxWidth => boxBoundingBox.width;
  double get boxHeight => boxBoundingBox.height;

  BoxProject copyWith({
    String? name,
    String? boxTemplateId,
    List<DxfEntity>? boxOutline,
    String? layer2TemplateId,
    List<DxfEntity>? layer2Outline,
    bool clearLayer2 = false,
    List<PlacedTemplate>? placedTemplates,
    List<Hole>? holes,
    double? plateThicknessMm,
    bool? addStandoffs,
    double? standoffHeightMm,
    double? standoffWallThicknessMm,
  }) {
    return BoxProject(
      name: name ?? this.name,
      boxTemplateId: boxTemplateId ?? this.boxTemplateId,
      boxOutline: boxOutline ?? this.boxOutline,
      layer2TemplateId: clearLayer2 ? null : (layer2TemplateId ?? this.layer2TemplateId),
      layer2Outline: clearLayer2 ? null : (layer2Outline ?? this.layer2Outline),
      placedTemplates: placedTemplates ?? this.placedTemplates,
      holes: holes ?? this.holes,
      plateThicknessMm: plateThicknessMm ?? this.plateThicknessMm,
      addStandoffs: addStandoffs ?? this.addStandoffs,
      standoffHeightMm: standoffHeightMm ?? this.standoffHeightMm,
      standoffWallThicknessMm: standoffWallThicknessMm ?? this.standoffWallThicknessMm,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'boxTemplateId': boxTemplateId,
        'boxOutline': entitiesToJson(boxOutline),
        if (layer2Outline != null) 'layer2Outline': entitiesToJson(layer2Outline!),
        if (layer2TemplateId != null) 'layer2TemplateId': layer2TemplateId,
        'placedTemplates': placedTemplates.map((p) => p.toJson()).toList(),
        'holes': holes.map((h) => h.toJson()).toList(),
        'plateThicknessMm': plateThicknessMm,
        'addStandoffs': addStandoffs,
        'standoffHeightMm': standoffHeightMm,
        'standoffWallThicknessMm': standoffWallThicknessMm,
      };

  factory BoxProject.fromJson(Map<String, dynamic> json) => BoxProject(
        name: json['name'] as String? ?? 'Untitled Box',
        boxTemplateId: json['boxTemplateId'] as String?,
        boxOutline: json['boxOutline'] != null
            ? entitiesFromJson(json['boxOutline'] as List<dynamic>)
            : defaultRectangleOutline(
                width: (json['boxWidth'] as num?)?.toDouble() ?? 150,
                height: (json['boxHeight'] as num?)?.toDouble() ?? 90,
              ),
        layer2TemplateId: json['layer2TemplateId'] as String?,
        layer2Outline: json['layer2Outline'] == null ? null : entitiesFromJson(json['layer2Outline'] as List<dynamic>),
        placedTemplates: (json['placedTemplates'] as List<dynamic>? ?? [])
            .map((p) => PlacedTemplate.fromJson(p as Map<String, dynamic>))
            .toList(),
        holes: (json['holes'] as List<dynamic>? ?? [])
            .map((h) => Hole.fromJson(h as Map<String, dynamic>))
            .toList(),
        plateThicknessMm: (json['plateThicknessMm'] as num?)?.toDouble() ?? 5,
        addStandoffs: json['addStandoffs'] as bool? ?? false,
        standoffHeightMm: (json['standoffHeightMm'] as num?)?.toDouble() ?? 3,
        standoffWallThicknessMm: (json['standoffWallThicknessMm'] as num?)?.toDouble() ?? 2,
      );
}
