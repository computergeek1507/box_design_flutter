import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/design_controller.dart';
import '../services/dxf_export.dart';
import '../services/file_io.dart';
import '../services/pdf_export.dart';
import '../services/project_io.dart';
import '../services/stl_export.dart';
import '../services/theme_settings.dart';
import '../services/threemf_export.dart';
import '../template_maker/template_maker_screen.dart';

enum _ExportFormat { dxf, pdf, stl, threeMf }

class TopToolbar extends StatefulWidget {
  final DesignController controller;
  final ThemeSettings? themeSettings;

  const TopToolbar({super.key, required this.controller, this.themeSettings});

  @override
  State<TopToolbar> createState() => _TopToolbarState();
}

class _TopToolbarState extends State<TopToolbar> {
  late final _thicknessController = TextEditingController(text: _fmt(controller.project.plateThicknessMm));
  late final _standoffHeightController = TextEditingController(text: _fmt(controller.project.standoffHeightMm));
  late final _standoffWallController = TextEditingController(text: _fmt(controller.project.standoffWallThicknessMm));
  final _thicknessFocus = FocusNode();
  final _standoffHeightFocus = FocusNode();
  final _standoffWallFocus = FocusNode();

  DesignController get controller => widget.controller;

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  void dispose() {
    _thicknessController.dispose();
    _standoffHeightController.dispose();
    _standoffWallController.dispose();
    _thicknessFocus.dispose();
    _standoffHeightFocus.dispose();
    _standoffWallFocus.dispose();
    super.dispose();
  }

  /// Keeps the text fields showing the project's own values (e.g. right
  /// after Open/New loads a different project) without clobbering a field
  /// the user is actively typing into.
  void _syncFields() {
    if (!_thicknessFocus.hasFocus) _thicknessController.text = _fmt(controller.project.plateThicknessMm);
    if (!_standoffHeightFocus.hasFocus) _standoffHeightController.text = _fmt(controller.project.standoffHeightMm);
    if (!_standoffWallFocus.hasFocus) _standoffWallController.text = _fmt(controller.project.standoffWallThicknessMm);
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _themeButton(BuildContext context, ThemeSettings settings) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final (icon, label) = switch (settings.mode) {
          ThemeMode.light => (Icons.light_mode, 'Light'),
          ThemeMode.dark => (Icons.dark_mode, 'Dark'),
          ThemeMode.system => (Icons.brightness_auto, 'System'),
        };
        return PopupMenuButton<ThemeMode>(
          tooltip: 'Theme: $label',
          icon: Icon(icon),
          initialValue: settings.mode,
          onSelected: settings.setMode,
          itemBuilder: (_) => const [
            PopupMenuItem(value: ThemeMode.system, child: Text('System')),
            PopupMenuItem(value: ThemeMode.light, child: Text('Light')),
            PopupMenuItem(value: ThemeMode.dark, child: Text('Dark')),
          ],
        );
      },
    );
  }

  Widget _measureToggle(BuildContext context) {
    final active = controller.measureModeEnabled;
    final start = controller.measureStart;
    final end = controller.measureEnd;
    String? label;
    if (start != null && end != null) {
      final dx = end.x - start.x;
      final dy = end.y - start.y;
      final distance = math.sqrt(dx * dx + dy * dy);
      label = 'ΔX ${dx.toStringAsFixed(2)}  ΔY ${dy.toStringAsFixed(2)}  ${distance.toStringAsFixed(2)} mm';
    } else if (start != null) {
      label = 'Click a second point…';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        active
            ? FilledButton.icon(
                onPressed: () => controller.toggleMeasureMode(),
                icon: const Icon(Icons.straighten, size: 18),
                label: const Text('Measuring'),
              )
            : OutlinedButton.icon(
                onPressed: () => controller.toggleMeasureMode(),
                icon: const Icon(Icons.straighten, size: 18),
                label: const Text('Measure'),
              ),
        if (label != null) ...[
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ],
    );
  }

  Future<void> _runExport(BuildContext context, _ExportFormat format) async {
    switch (format) {
      case _ExportFormat.dxf:
        final bytes = exportProjectAsDxfBytes(controller.project, controller.library);
        final result = await saveBytes('${controller.project.name}.dxf', bytes, dialogTitle: 'Export DXF', mimeType: 'application/dxf');
        if (context.mounted) _snack(context, result != null ? 'DXF exported' : 'Export cancelled');
      case _ExportFormat.pdf:
        final bytes = await exportProjectAsPdfBytes(controller.project, controller.library);
        final result = await saveBytes('${controller.project.name}.pdf', bytes, dialogTitle: 'Export PDF', mimeType: 'application/pdf');
        if (context.mounted) _snack(context, result != null ? 'PDF exported' : 'Export cancelled');
      case _ExportFormat.stl:
        final bytes = exportProjectAsStlBytes(
          controller.project,
          controller.library,
          thicknessMm: controller.project.plateThicknessMm,
          addStandoffs: controller.project.addStandoffs,
          standoffHeight: controller.project.standoffHeightMm,
          standoffWallThickness: controller.project.standoffWallThicknessMm,
        );
        final result = await saveBytes('${controller.project.name}.stl', bytes, dialogTitle: 'Export STL', mimeType: 'model/stl');
        if (context.mounted) _snack(context, result != null ? 'STL exported' : 'Export cancelled');
      case _ExportFormat.threeMf:
        final bytes = exportProjectAs3mfBytes(
          controller.project,
          controller.library,
          thicknessMm: controller.project.plateThicknessMm,
          addStandoffs: controller.project.addStandoffs,
          standoffHeight: controller.project.standoffHeightMm,
          standoffWallThickness: controller.project.standoffWallThicknessMm,
        );
        final result = await saveBytes('${controller.project.name}.3mf', bytes, dialogTitle: 'Export 3MF', mimeType: 'model/3mf');
        if (context.mounted) _snack(context, result != null ? '3MF exported' : 'Export cancelled');
    }
  }

  Widget _exportMenu(BuildContext context) {
    return PopupMenuButton<_ExportFormat>(
      tooltip: 'Export',
      onSelected: (format) => _runExport(context, format),
      itemBuilder: (context) => const [
        PopupMenuItem(value: _ExportFormat.dxf, child: Text('Export DXF')),
        PopupMenuItem(value: _ExportFormat.pdf, child: Text('Export PDF')),
        PopupMenuItem(value: _ExportFormat.stl, child: Text('Export STL')),
        PopupMenuItem(value: _ExportFormat.threeMf, child: Text('Export 3MF')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.file_download_outlined, size: 18),
            const SizedBox(width: 6),
            const Text('Export'),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  void _showPrintSettingsDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          _syncFields();
          return AlertDialog(
            title: const Text('3D print settings'),
            content: SizedBox(
              width: 260,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _thicknessController,
                    focusNode: _thicknessFocus,
                    decoration: const InputDecoration(labelText: 'Plate thickness (mm)', isDense: true, border: OutlineInputBorder()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final parsed = double.tryParse(v);
                      if (parsed != null) controller.setPlateThicknessMm(parsed);
                    },
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Add standoffs'),
                    subtitle: const Text('On controller/receiver mounting holes'),
                    value: controller.project.addStandoffs,
                    onChanged: (v) => controller.setAddStandoffs(v ?? false),
                  ),
                  if (controller.project.addStandoffs) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _standoffHeightController,
                            focusNode: _standoffHeightFocus,
                            decoration: const InputDecoration(labelText: 'Height (mm)', isDense: true, border: OutlineInputBorder()),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: (v) {
                              final parsed = double.tryParse(v);
                              if (parsed != null) controller.setStandoffHeightMm(parsed);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _standoffWallController,
                            focusNode: _standoffWallFocus,
                            decoration: const InputDecoration(labelText: 'Wall (mm)', isDense: true, border: OutlineInputBorder()),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: (v) {
                              final parsed = double.tryParse(v);
                              if (parsed != null) controller.setStandoffWallThicknessMm(parsed);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Done')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final box = controller.library.byId(controller.project.boxTemplateId ?? '');
        return Material(
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(onPressed: () => controller.newProject(), child: const Text('New')),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TemplateMakerScreen(library: controller.library))),
                  child: const Text('Template Maker'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    final project = await openProject();
                    if (project != null) controller.loadProject(project);
                  },
                  child: const Text('Open'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    final result = await saveProject(controller.project);
                    if (context.mounted) _snack(context, result != null ? 'Project saved' : 'Save cancelled');
                  },
                  child: const Text('Save'),
                ),
                const VerticalDivider(width: 1),
                Text(
                  box == null
                      ? 'No box selected'
                      : controller.project.dualLayer
                          ? '${box.name} + layer 2 — ${controller.project.boxWidth.toStringAsFixed(0)}×${controller.project.boxHeight.toStringAsFixed(0)}mm'
                          : '${box.name} — ${controller.project.boxWidth.toStringAsFixed(0)}×${controller.project.boxHeight.toStringAsFixed(0)}mm',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const VerticalDivider(width: 1),
                _measureToggle(context),
                const VerticalDivider(width: 1),
                _exportMenu(context),
                IconButton(
                  onPressed: () => _showPrintSettingsDialog(context),
                  icon: const Icon(Icons.tune),
                  tooltip: '3D print settings',
                ),
                if (widget.themeSettings != null) _themeButton(context, widget.themeSettings!),
              ],
            ),
          ),
        );
      },
    );
  }
}
