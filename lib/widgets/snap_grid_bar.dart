import 'package:flutter/material.dart';

import '../design/design_controller.dart';

/// A bottom toolbar for choosing the canvas's snap-to-grid size (or turning
/// it off) when dragging a placed template or hole.
class SnapGridBar extends StatelessWidget {
  final DesignController controller;

  const SnapGridBar({super.key, required this.controller});

  String _fmt(double v) => v == v.roundToDouble() ? '${v.toStringAsFixed(0)}mm' : '${v}mm';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final selected = controller.snapToGridMm;
        return Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Row(
            children: [
              const Icon(Icons.grid_4x4, size: 18),
              const SizedBox(width: 8),
              const Text('Snap to grid:'),
              const SizedBox(width: 12),
              ChoiceChip(
                label: const Text('Off'),
                selected: selected == null,
                onSelected: (_) => controller.setSnapToGridMm(null),
              ),
              for (final size in DesignController.snapToGridOptionsMm) ...[
                const SizedBox(width: 6),
                ChoiceChip(
                  label: Text(_fmt(size)),
                  selected: selected == size,
                  onSelected: (_) => controller.setSnapToGridMm(size),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
