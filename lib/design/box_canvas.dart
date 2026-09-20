import 'package:flutter/material.dart';

import '../geometry/placed_entities.dart';
import '../geometry/tessellate.dart';
import '../models/palette_drag_item.dart';
import '../models/vec2.dart';
import 'box_painter.dart';
import 'design_controller.dart';
import 'snap.dart';

const double pixelsPerMm = 4.0;

/// The interactive design surface: renders the box + placed templates +
/// holes, supports drag to move any item, and accepting templates/hole
/// presets dropped from the palette.
class BoxCanvas extends StatefulWidget {
  final DesignController controller;

  /// Reclaimed on every canvas interaction so keyboard shortcuts (copy,
  /// paste, delete) keep working after a property-panel text field was
  /// focused -- unfocusing that field doesn't hand focus back to this
  /// screen's shortcut handler on its own.
  final FocusNode? focusNode;

  const BoxCanvas({super.key, required this.controller, this.focusNode});

  @override
  State<BoxCanvas> createState() => _BoxCanvasState();
}

class _BoxCanvasState extends State<BoxCanvas> {
  final GlobalKey _contentKey = GlobalKey();
  final TransformationController _transformationController =
      TransformationController();
  String? _draggingId;

  DesignController get controller => widget.controller;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  /// Pans the view by [delta], which is expressed in the same (untransformed)
  /// content-pixel space as the drag events below -- InteractiveViewer's
  /// descendants already receive pointer deltas with the current zoom
  /// divided out, so applying the raw delta here lands 1:1 with screen
  /// movement at any zoom level, matching how the built-in pan gesture (kept
  /// off below, see [panEnabled]) would move things.
  void _panBy(Offset delta) {
    _transformationController.value = _transformationController.value.clone()
      ..translateByDouble(delta.dx, delta.dy, 0, 1);
  }

  Vec2 _localPxToMm(Offset localPx, double boxHeightMm) {
    return Vec2(
      localPx.dx / pixelsPerMm,
      boxHeightMm - localPx.dy / pixelsPerMm,
    );
  }

  Rect _mmBoxToScreenRect(BoundingBox boundingBox, double boxHeightMm) {
    final p1 = Offset(
      boundingBox.minX * pixelsPerMm,
      (boxHeightMm - boundingBox.maxY) * pixelsPerMm,
    );
    final p2 = Offset(
      boundingBox.maxX * pixelsPerMm,
      (boxHeightMm - boundingBox.minY) * pixelsPerMm,
    );
    return Rect.fromPoints(p1, p2).inflate(4);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final project = controller.project;
        final boxHeightMm = project.boxHeight;
        final contentWidth = project.boxWidth * pixelsPerMm;
        final contentHeight = project.boxHeight * pixelsPerMm;

        final itemOverlays = <Widget>[];
        for (final placed in project.placedTemplates) {
          final template = controller.library.byId(placed.templateId);
          if (template == null) continue;
          final entities = placedTemplateEntities(template, placed);
          final rect = _mmBoxToScreenRect(
            entitiesBoundingBox(entities),
            boxHeightMm,
          );
          itemOverlays.add(_dragHandle(rect, placed.id, boxHeightMm));
        }
        for (final hole in project.holes) {
          final rect = _mmBoxToScreenRect(hole.boundingBox, boxHeightMm);
          itemOverlays.add(_dragHandle(rect, hole.id, boxHeightMm));
        }

        return Listener(
          // Purely an observer -- doesn't join the gesture arena, so it
          // can't steal drags/pans from the detectors below.
          onPointerDown: (_) => widget.focusNode?.requestFocus(),
          child: DragTarget<PaletteDragItem>(
            onAcceptWithDetails: (details) {
              final box =
                  _contentKey.currentContext!.findRenderObject() as RenderBox;
              final local = box.globalToLocal(details.offset);
              final mm = _localPxToMm(local, boxHeightMm);
              switch (details.data) {
                case TemplateDragItem(templateId: final id):
                  controller.addPlacedTemplate(id, mm);
                case HolePresetDragItem(preset: final preset):
                  controller.addHoleFromPreset(preset, mm);
              }
            },
            builder: (context, candidateData, rejectedData) {
              return InteractiveViewer(
                transformationController: _transformationController,
                // Panning is handled manually by the background GestureDetector
                // below instead of InteractiveViewer's own pan gesture, so it
                // never competes with the per-item drag handles for the arena.
                panEnabled: false,
                scaleEnabled: true,
                minScale: 0.25,
                maxScale: 8,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(400),
                child: SizedBox(
                  key: _contentKey,
                  width: contentWidth,
                  height: contentHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: DesignPainter(
                            controller,
                            pixelsPerMm: pixelsPerMm,
                            isDark: Theme.of(context).brightness == Brightness.dark,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () => controller.select(null),
                          onPanUpdate: (details) => _panBy(details.delta),
                        ),
                      ),
                      ...itemOverlays,
                      if (controller.measureModeEnabled)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) => controller.placeMeasurePoint(
                              snapPoint(
                                _localPxToMm(
                                  details.localPosition,
                                  boxHeightMm,
                                ),
                                controller,
                              ),
                            ),
                            onPanStart: (details) => controller.startMeasure(
                              snapPoint(
                                _localPxToMm(
                                  details.localPosition,
                                  boxHeightMm,
                                ),
                                controller,
                              ),
                            ),
                            onPanUpdate: (details) => controller.updateMeasure(
                              snapPoint(
                                _localPxToMm(
                                  details.localPosition,
                                  boxHeightMm,
                                ),
                                controller,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _dragHandle(Rect rect, String id, double boxHeightMm) {
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          _draggingId = id;
          controller.select(id);
        },
        onPanUpdate: (details) {
          if (_draggingId != id) return;
          final deltaMm = Vec2(
            details.delta.dx / pixelsPerMm,
            -details.delta.dy / pixelsPerMm,
          );
          _moveItem(id, deltaMm);
        },
        onPanEnd: (_) => _draggingId = null,
        onTap: () => controller.select(id),
      ),
    );
  }

  void _moveItem(String id, Vec2 deltaMm) {
    for (final p in controller.project.placedTemplates) {
      if (p.id == id) {
        controller.movePlacedTemplate(id, p.position.add(deltaMm));
        return;
      }
    }
    for (final h in controller.project.holes) {
      if (h.id == id) {
        controller.updateHole(
          id,
          (hole) => hole.copyWith(position: hole.position.add(deltaMm)),
        );
        return;
      }
    }
  }
}
