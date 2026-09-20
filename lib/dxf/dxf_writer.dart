import '../models/dxf_entity.dart';

/// A single-line text note for [writeDxfLayered].
class DxfTextItem {
  final String text;
  final double x;
  final double y;
  final double height;
  final double rotationDeg;

  const DxfTextItem(this.text, this.x, this.y, this.height, this.rotationDeg);
}

/// Writes a minimal, valid ASCII DXF R12 file: a HEADER section (just enough
/// for CAD/CAM tools to recognize units) and an ENTITIES section. No
/// TABLES/BLOCKS section is needed since entities default to layer "0",
/// which always exists implicitly.
String writeDxf(List<DxfEntity> entities) {
  return writeDxfLayered({'0': entities});
}

/// Same output as [writeDxf], but each entry in [entitiesByLayer] becomes
/// its own named DXF layer (group code 8), declared up front in a TABLES
/// section so CAD/CAM tools that expect layers to exist before they're
/// referenced (rather than auto-creating them) still show them -- e.g. for
/// assigning a different drill bit/tool per hole-size layer.
String writeDxfLayered(Map<String, List<DxfEntity>> entitiesByLayer, {List<DxfTextItem> texts = const [], String textLayer = 'Notes'}) {
  final buffer = StringBuffer();
  if (texts.isNotEmpty && !entitiesByLayer.containsKey(textLayer)) {
    entitiesByLayer = {...entitiesByLayer, textLayer: <DxfEntity>[]};
  }

  void pair(int code, Object value) {
    buffer.writeln(code);
    buffer.writeln(value);
  }

  final layerNames = entitiesByLayer.keys.map(_sanitizeLayerName).toList();

  pair(0, 'SECTION');
  pair(2, 'HEADER');
  pair(9, r'$ACADVER');
  pair(1, 'AC1009');
  pair(9, r'$INSUNITS');
  pair(70, 4); // 4 = millimeters
  pair(0, 'ENDSEC');

  // Layer "0" always exists implicitly and doesn't need declaring; only
  // emit a TABLES section when there's at least one other layer to declare.
  final declaredLayers = layerNames.where((l) => l != '0').toList();
  if (declaredLayers.isNotEmpty) {
    pair(0, 'SECTION');
    pair(2, 'TABLES');
    pair(0, 'TABLE');
    pair(2, 'LAYER');
    pair(70, declaredLayers.length);
    for (final layer in declaredLayers) {
      pair(0, 'LAYER');
      pair(2, layer);
      pair(70, 0);
      pair(62, 7); // color 7 = default (black/white)
      pair(6, 'CONTINUOUS');
    }
    pair(0, 'ENDTAB');
    pair(0, 'ENDSEC');
  }

  pair(0, 'SECTION');
  pair(2, 'ENTITIES');
  for (final MapEntry(:key, :value) in entitiesByLayer.entries) {
    final layer = _sanitizeLayerName(key);
    for (final entity in value) {
      _writeEntity(pair, entity, layer);
    }
  }
  for (final t in texts) {
    pair(0, 'TEXT');
    pair(8, _sanitizeLayerName(textLayer));
    pair(10, _fmt(t.x));
    pair(20, _fmt(t.y));
    pair(30, _fmt(0));
    pair(40, _fmt(t.height));
    pair(1, t.text);
    pair(50, _fmt(t.rotationDeg));
  }
  pair(0, 'ENDSEC');
  pair(0, 'EOF');

  return buffer.toString();
}

/// DXF/AutoCAD layer names can't contain `<>/\":;?*|,=` or be empty.
String _sanitizeLayerName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[<>/\\":;?*|,=]'), '_').trim();
  return cleaned.isEmpty ? '0' : cleaned;
}

String _fmt(double v) => v.toStringAsFixed(6);

void _writeEntity(void Function(int, Object) pair, DxfEntity entity, String layer) {
  switch (entity) {
    case DxfLine e:
      pair(0, 'LINE');
      pair(8, layer);
      pair(10, _fmt(e.start.x));
      pair(20, _fmt(e.start.y));
      pair(30, '0.0');
      pair(11, _fmt(e.end.x));
      pair(21, _fmt(e.end.y));
      pair(31, '0.0');
    case DxfCircle e:
      pair(0, 'CIRCLE');
      pair(8, layer);
      pair(10, _fmt(e.center.x));
      pair(20, _fmt(e.center.y));
      pair(30, '0.0');
      pair(40, _fmt(e.radius));
    case DxfArc e:
      pair(0, 'ARC');
      pair(8, layer);
      pair(10, _fmt(e.center.x));
      pair(20, _fmt(e.center.y));
      pair(30, '0.0');
      pair(40, _fmt(e.radius));
      pair(50, _fmt(e.startAngleDeg));
      pair(51, _fmt(e.endAngleDeg));
    case DxfPolyline e:
      pair(0, 'LWPOLYLINE');
      pair(8, layer);
      pair(90, e.vertices.length);
      pair(70, e.closed ? 1 : 0);
      for (final v in e.vertices) {
        pair(10, _fmt(v.point.x));
        pair(20, _fmt(v.point.y));
        if (v.bulge != 0) {
          pair(42, _fmt(v.bulge));
        }
      }
  }
}
