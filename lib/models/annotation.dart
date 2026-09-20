import 'dxf_entity.dart';
import 'vec2.dart';

enum AnnotationType { text, line, rect, circle }

/// One item on a template's drawing layer: a note that helps you place the
/// item (e.g. "USB this side", a keep-out box) and is drawn on the canvas and
/// in the PDF/DXF, but never cut or printed. Coordinates are in the
/// template's own local mm space.
///
/// Field use by [type]:
/// * text: ([x], [y]) is the bottom-left of the text, [height] the letter
///   height in mm, [rotationDeg] its angle.
/// * line: ([x], [y]) to ([x2], [y2]).
/// * rect: ([x], [y]) is the min corner, [width] x [height] its size.
/// * circle: ([x], [y]) is the center, [radius] its radius.
class Annotation {
  final AnnotationType type;
  final String text;
  final double x;
  final double y;
  final double x2;
  final double y2;
  final double width;
  final double height;
  final double radius;
  final double rotationDeg;

  const Annotation({
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

  /// The geometry for line/rect/circle notes (empty for text).
  List<DxfEntity> toEntities() {
    switch (type) {
      case AnnotationType.text:
        return const [];
      case AnnotationType.line:
        return [DxfLine(Vec2(x, y), Vec2(x2, y2))];
      case AnnotationType.rect:
        return [
          DxfPolyline([
            PolyVertex(Vec2(x, y)),
            PolyVertex(Vec2(x + width, y)),
            PolyVertex(Vec2(x + width, y + height)),
            PolyVertex(Vec2(x, y + height)),
          ], closed: true),
        ];
      case AnnotationType.circle:
        return [DxfCircle(Vec2(x, y), radius)];
    }
  }

  Map<String, dynamic> toJson() {
    switch (type) {
      case AnnotationType.text:
        return {'type': 'text', 'text': text, 'x': x, 'y': y, 'height': height, 'rotationDeg': rotationDeg};
      case AnnotationType.line:
        return {'type': 'line', 'start': {'x': x, 'y': y}, 'end': {'x': x2, 'y': y2}};
      case AnnotationType.rect:
        return {'type': 'rect', 'x': x, 'y': y, 'width': width, 'height': height};
      case AnnotationType.circle:
        return {'type': 'circle', 'center': {'x': x, 'y': y}, 'radius': radius};
    }
  }

  factory Annotation.fromJson(Map<String, dynamic> json) {
    double n(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
    switch (json['type'] as String) {
      case 'text':
        return Annotation(
          type: AnnotationType.text,
          text: json['text'] as String? ?? '',
          x: n(json['x']),
          y: n(json['y']),
          height: n(json['height'], 5),
          rotationDeg: n(json['rotationDeg']),
        );
      case 'line':
        final s = json['start'] as Map<String, dynamic>, e = json['end'] as Map<String, dynamic>;
        return Annotation(type: AnnotationType.line, x: n(s['x']), y: n(s['y']), x2: n(e['x']), y2: n(e['y']));
      case 'rect':
        return Annotation(
          type: AnnotationType.rect,
          x: n(json['x']),
          y: n(json['y']),
          width: n(json['width'], 10),
          height: n(json['height'], 5),
        );
      case 'circle':
        final c = json['center'] as Map<String, dynamic>;
        return Annotation(type: AnnotationType.circle, x: n(c['x']), y: n(c['y']), radius: n(json['radius'], 5));
      default:
        throw FormatException('Unknown annotation type: ${json['type']}');
    }
  }
}

/// A text note after a template's position/rotation has been applied.
class PlacedText {
  final String text;
  final Vec2 anchor;
  final double height;
  final double rotationDeg;

  const PlacedText(this.text, this.anchor, this.height, this.rotationDeg);
}

/// A template's drawing layer after placement: line/rect/circle notes as
/// plain entities plus the text notes.
class PlacedNotes {
  final List<DxfEntity> shapes;
  final List<PlacedText> texts;

  const PlacedNotes(this.shapes, this.texts);

  static const empty = PlacedNotes([], []);
}
