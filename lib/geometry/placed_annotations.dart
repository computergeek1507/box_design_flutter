import '../models/annotation.dart';
import '../models/controller_template.dart';
import '../models/placed_template.dart';
import '../models/vec2.dart';
import 'transform.dart';

/// [notes] moved/rotated into place the same way [placeEntities] places a
/// template's geometry (rotate about the local origin, then translate).
PlacedNotes placeAnnotations(List<Annotation> notes, {Vec2 delta = const Vec2(0, 0), double rotationDeg = 0}) {
  if (notes.isEmpty) return PlacedNotes.empty;
  final shapes = placeEntities(
    [for (final n in notes) ...n.toEntities()],
    delta: delta,
    rotationDeg: rotationDeg,
  );
  final texts = [
    for (final n in notes)
      if (n.type == AnnotationType.text)
        PlacedText(n.text, Vec2(n.x, n.y).rotated(rotationDeg).add(delta), n.height, n.rotationDeg + rotationDeg),
  ];
  return PlacedNotes(shapes, texts);
}

PlacedNotes placedTemplateNotes(ControllerTemplate template, PlacedTemplate placed) =>
    placeAnnotations(template.annotations, delta: placed.position, rotationDeg: placed.rotationDeg);
