import 'package:flutter/material.dart';

import '../design/design_controller.dart';
import '../models/dxf_entity.dart';
import '../models/hole.dart';
import '../models/placed_template.dart';
import '../models/vec2.dart';
import '../services/simple_math.dart';

class RightPropertyPanel extends StatefulWidget {
  final DesignController controller;

  const RightPropertyPanel({super.key, required this.controller});

  @override
  State<RightPropertyPanel> createState() => _RightPropertyPanelState();
}

class _RightPropertyPanelState extends State<RightPropertyPanel> {
  String? _lastSelectedId;
  final _xController = TextEditingController();
  final _yController = TextEditingController();
  final _rotController = TextEditingController();
  final _diameterController = TextEditingController();
  final _lengthController = TextEditingController();
  final _widthController = TextEditingController();
  final _mountingHoleController = TextEditingController();
  final _xFocus = FocusNode();
  final _yFocus = FocusNode();
  final _diameterFocus = FocusNode();
  final _lengthFocus = FocusNode();
  final _widthFocus = FocusNode();
  final _mountingHoleFocus = FocusNode();

  DesignController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChanged);
    _syncFields(force: true);
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    for (final c in [_xController, _yController, _rotController, _diameterController, _lengthController, _widthController, _mountingHoleController]) {
      c.dispose();
    }
    for (final f in [_xFocus, _yFocus, _diameterFocus, _lengthFocus, _widthFocus, _mountingHoleFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    final selectionChanged = controller.selectedId != _lastSelectedId;
    _lastSelectedId = controller.selectedId;
    // Always keep unfocused fields live (e.g. after a canvas drag) so a
    // later edit to one field never commits a stale value for another.
    // A field mid-edit is left alone so we don't clobber the user's typing.
    _syncFields(force: selectionChanged);
    setState(() {});
  }

  void _syncFields({required bool force}) {
    final placed = controller.selectedTemplate;
    final hole = controller.selectedHole;
    if (placed != null) {
      if (force || !_xFocus.hasFocus) _xController.text = placed.position.x.toStringAsFixed(2);
      if (force || !_yFocus.hasFocus) _yController.text = placed.position.y.toStringAsFixed(2);
      _rotController.text = placed.rotationDeg.toStringAsFixed(0);
      final effective = placed.holeDiameterOverride ?? _bakedInHoleDiameter(placed);
      if ((force || !_mountingHoleFocus.hasFocus) && effective != null) {
        _mountingHoleController.text = effective.toStringAsFixed(1);
      }
    } else if (hole != null) {
      if (force || !_xFocus.hasFocus) _xController.text = hole.position.x.toStringAsFixed(2);
      if (force || !_yFocus.hasFocus) _yController.text = hole.position.y.toStringAsFixed(2);
      _rotController.text = hole.rotationDeg.toStringAsFixed(0);
      if (force || !_diameterFocus.hasFocus) _diameterController.text = hole.diameter.toStringAsFixed(1);
      if (force || !_lengthFocus.hasFocus) _lengthController.text = hole.slotLength.toStringAsFixed(1);
      if (force || !_widthFocus.hasFocus) _widthController.text = hole.slotWidth.toStringAsFixed(1);
    }
  }

  void _applyPosition() {
    final x = tryEvalMath(_xController.text);
    final y = tryEvalMath(_yController.text);
    if (x == null || y == null) return;
    final placed = controller.selectedTemplate;
    final hole = controller.selectedHole;
    if (placed != null) {
      controller.movePlacedTemplate(placed.id, Vec2(x, y));
    } else if (hole != null) {
      controller.updateHole(hole.id, (h) => h.copyWith(position: Vec2(x, y)));
    }
  }

  String _holeTitle(Hole hole) {
    switch (hole.type) {
      case HoleType.screw:
        return 'Screw Hole';
      case HoleType.zipTie:
        return 'Zip-Tie Holes';
      case HoleType.slot:
        return 'Slot';
      case HoleType.rectangle:
        return 'Rectangular Slot';
    }
  }

  void _applyRotation(double degrees) {
    final placed = controller.selectedTemplate;
    final hole = controller.selectedHole;
    if (placed != null) {
      controller.rotatePlacedTemplate(placed.id, degrees);
    } else if (hole != null) {
      controller.updateHole(hole.id, (h) => h.copyWith(rotationDeg: degrees));
    }
    _rotController.text = degrees.toStringAsFixed(0);
  }

  /// The diameter baked into the template's own geometry (its first round
  /// mounting hole), or null if it has none — used both as the field's
  /// starting value and to decide whether to show the field at all.
  double? _bakedInHoleDiameter(PlacedTemplate placed) {
    final template = controller.library.byId(placed.templateId);
    if (template == null) return null;
    for (final e in template.entities) {
      if (e is DxfCircle) return e.radius * 2;
    }
    return null;
  }

  void _applyMountingHoleDiameter(PlacedTemplate placed) {
    final d = tryEvalMath(_mountingHoleController.text);
    if (d == null || d <= 0) return;
    controller.setMountingHoleDiameter(placed.id, d);
  }

  @override
  Widget build(BuildContext context) {
    final placed = controller.selectedTemplate;
    final hole = controller.selectedHole;

    if (placed == null && hole == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Select an item to edit its properties.'),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            placed != null ? (controller.library.byId(placed.templateId)?.name ?? placed.templateId) : _holeTitle(hole!),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _numberField('X (mm)', _xController, _xFocus, _applyPosition)),
              const SizedBox(width: 8),
              Expanded(child: _numberField('Y (mm)', _yController, _yFocus, _applyPosition)),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Rotation'),
          Wrap(
            spacing: 6,
            children: [
              for (final deg in [0.0, 90.0, 180.0, 270.0])
                OutlinedButton(onPressed: () => _applyRotation(deg), child: Text('${deg.toInt()}°')),
            ],
          ),
          if (placed != null && _bakedInHoleDiameter(placed) != null) ...[
            const SizedBox(height: 12),
            _numberField('Mounting hole size (mm)', _mountingHoleController, _mountingHoleFocus, () => _applyMountingHoleDiameter(placed)),
            if (placed.holeDiameterOverride != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    controller.setMountingHoleDiameter(placed.id, null);
                    _mountingHoleController.text = _bakedInHoleDiameter(placed)!.toStringAsFixed(1);
                  },
                  child: const Text('Reset to template default'),
                ),
              ),
          ],
          if (hole != null && hole.type == HoleType.screw) ...[
            const SizedBox(height: 12),
            _numberField('Diameter (mm)', _diameterController, _diameterFocus, () {
              final d = tryEvalMath(_diameterController.text);
              if (d != null) controller.updateHole(hole.id, (h) => h.copyWith(diameter: d));
            }),
          ],
          if (hole != null && hole.type == HoleType.zipTie) ...[
            const SizedBox(height: 12),
            _numberField('Hole spacing (mm)', _lengthController, _lengthFocus, () {
              final v = tryEvalMath(_lengthController.text);
              if (v != null) controller.updateHole(hole.id, (h) => h.copyWith(slotLength: v));
            }),
            const SizedBox(height: 8),
            _numberField('Hole diameter (mm)', _widthController, _widthFocus, () {
              final v = tryEvalMath(_widthController.text);
              if (v != null) controller.updateHole(hole.id, (h) => h.copyWith(slotWidth: v));
            }),
          ],
          if (hole != null && (hole.type == HoleType.slot || hole.type == HoleType.rectangle)) ...[
            const SizedBox(height: 12),
            _numberField('Width (mm)', _lengthController, _lengthFocus, () {
              final v = tryEvalMath(_lengthController.text);
              if (v != null) controller.updateHole(hole.id, (h) => h.copyWith(slotLength: v));
            }),
            const SizedBox(height: 8),
            _numberField('Height (mm)', _widthController, _widthFocus, () {
              final v = tryEvalMath(_widthController.text);
              if (v != null) controller.updateHole(hole.id, (h) => h.copyWith(slotWidth: v));
            }),
          ],
          const SizedBox(height: 20),
          FilledButton.tonal(
            onPressed: controller.deleteSelected,
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _numberField(String label, TextEditingController fieldController, FocusNode focusNode, VoidCallback onSubmit) {
    return TextField(
      controller: fieldController,
      focusNode: focusNode,
      decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      // Commit on every keystroke, not just on blur/submit -- selecting a
      // different item on the canvas (a plain tap or the start of a drag)
      // calls DesignController.select() directly, which is not routed
      // through this field's onTapOutside. Without a live commit here, an
      // edit still in progress when that happens is silently discarded
      // instead of saved, which reads as the field "reverting".
      onChanged: (_) => onSubmit(),
      onSubmitted: (_) => onSubmit(),
      onEditingComplete: onSubmit,
      onTapOutside: (_) {
        onSubmit();
        focusNode.unfocus();
      },
    );
  }
}
