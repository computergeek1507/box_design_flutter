import 'dart:convert';

import 'package:flutter/material.dart';

import '../design/design_controller.dart';
import '../models/controller_template.dart';
import '../models/palette_drag_item.dart';
import '../services/file_io.dart';
import '../services/hole_preset_library.dart';
import '../services/template_library.dart';
import '../template_maker/template_maker_screen.dart';

/// Compares two names the way a person would rather than plain lexicographic
/// order, so e.g. "K8-Max" sorts before "K16" before "K40" (plain string
/// comparison puts "K16" < "K32" < "K40" < "K8", since '1' < '3' < '4' < '8'
/// as characters, regardless of how many digits follow). Splits each name
/// into runs of digits vs. non-digits and compares digit runs numerically.
int _naturalCompare(String a, String b) {
  final aParts = RegExp(r'\d+|\D+').allMatches(a).map((m) => m.group(0)!).toList();
  final bParts = RegExp(r'\d+|\D+').allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < aParts.length && i < bParts.length; i++) {
    final x = aParts[i];
    final y = bParts[i];
    final xIsNum = RegExp(r'^\d+$').hasMatch(x);
    final yIsNum = RegExp(r'^\d+$').hasMatch(y);
    final cmp = (xIsNum && yIsNum) ? int.parse(x).compareTo(int.parse(y)) : x.toLowerCase().compareTo(y.toLowerCase());
    if (cmp != 0) return cmp;
  }
  return aParts.length.compareTo(bParts.length);
}

class LeftPalette extends StatefulWidget {
  final TemplateLibrary library;
  final HolePresetLibrary holePresetLibrary;
  final DesignController controller;

  const LeftPalette({
    super.key,
    required this.library,
    required this.holePresetLibrary,
    required this.controller,
  });

  @override
  State<LeftPalette> createState() => _LeftPaletteState();
}

class _LeftPaletteState extends State<LeftPalette> {
  String _filter = '';

  Future<void> _importJson() async {
    final picked = await pickFile(allowedExtensions: ['json'], dialogTitle: 'Import Template JSON');
    if (picked == null) return;
    try {
      widget.library.importJson(utf8.decode(picked.bytes));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to import: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.library, widget.holePresetLibrary, widget.controller]),
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                children: [
                  _boxSection(),
                  const Divider(height: 1),
                  _categorySection('Controllers', TemplateCategory.controller, filter: _filter),
                  _categorySection('Controller Add-ons', TemplateCategory.controllerAddon, filter: _filter),
                  _categorySection('Receivers', TemplateCategory.receiver, filter: _filter),
                  _categorySection('Power Supplies', TemplateCategory.powerSupply, filter: _filter),
                  _categorySection('Power Distribution', TemplateCategory.powerDistribution, filter: _filter),
                  _genericHolesSection(filter: _filter),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _filterField(),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _importJson, child: const Text('Import JSON Template')),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _applyBox(ControllerTemplate box) async {
    final lost = widget.controller.itemsLostByApplying(box.id);
    if (lost > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove layer 2?'),
          content: Text('${box.name} has one layer. Layer 2 has $lost item(s) on it, and switching deletes layer 2 and everything on it.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Switch')),
          ],
        ),
      );
      if (ok != true) return;
    }
    widget.controller.applyBoxTemplate(box.id);
  }

  Widget _boxSection() {
    final boxes = widget.library.byCategory(TemplateCategory.box)..sort((a, b) => _naturalCompare(a.name, b.name));
    final project = widget.controller.project;
    final activeId = project.boxTemplateId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text('Box Template', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final box in boxes)
          ListTile(
            dense: true,
            selected: box.id == activeId,
            selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
            leading: Icon(box.id == activeId ? Icons.check_circle : Icons.circle_outlined),
            title: Text(box.name),
            trailing: box.source == TemplateSource.userMade
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person, size: 18),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 18),
                        tooltip: 'Edit template',
                        onPressed: () => _editTemplate(box),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'Remove template',
                        onPressed: () => _removeUserTemplate(box),
                      ),
                    ],
                  )
                : null,
            onTap: () => _applyBox(box),
          ),
        if (boxes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('No box templates loaded', style: TextStyle(color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _filterField() {
    return TextField(
      decoration: const InputDecoration(
        labelText: 'Filter templates & holes',
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 18),
        border: OutlineInputBorder(),
      ),
      onChanged: (v) => setState(() => _filter = v),
    );
  }

  void _editTemplate(ControllerTemplate template) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TemplateMakerScreen(library: widget.library, initialTemplate: template),
    ));
  }

  Future<void> _removeUserTemplate(ControllerTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove template?'),
        content: Text('This deletes "${template.name}" from your saved templates. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.library.remove(template.id);
  }

  Widget _categorySection(String title, TemplateCategory category, {String filter = ''}) {
    var items = widget.library.byCategory(category);
    if (filter.trim().isNotEmpty) {
      final needle = filter.trim().toLowerCase();
      items = items.where((t) => t.name.toLowerCase().contains(needle)).toList();
    }
    items.sort((a, b) => _naturalCompare(a.name, b.name));
    return ExpansionTile(
      title: Text(title),
      initiallyExpanded: true,
      children: [
        for (final template in items)
          Draggable<PaletteDragItem>(
            data: TemplateDragItem(template.id),
            feedback: _dragFeedback(template.name),
            child: ListTile(
              dense: true,
              leading: template.source == TemplateSource.userMade
                  ? const Icon(Icons.person, size: 18)
                  : null,
              title: Text(template.name),
              trailing: template.source == TemplateSource.userMade
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          tooltip: 'Edit template',
                          onPressed: () => _editTemplate(template),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: 'Remove template',
                          onPressed: () => _removeUserTemplate(template),
                        ),
                      ],
                    )
                  : null,
            ),
          ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              filter.trim().isNotEmpty ? 'No matches' : 'None yet',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
      ],
    );
  }

  Widget _genericHolesSection({String filter = ''}) {
    var presets = widget.holePresetLibrary.presets;
    if (filter.trim().isNotEmpty) {
      final needle = filter.trim().toLowerCase();
      presets = presets.where((p) => p.name.toLowerCase().contains(needle)).toList();
    }
    return ExpansionTile(
      title: const Text('Generic Holes'),
      initiallyExpanded: true,
      children: [
        for (final preset in presets)
          Draggable<PaletteDragItem>(
            data: HolePresetDragItem(preset),
            feedback: _dragFeedback(preset.name),
            child: ListTile(dense: true, title: Text(preset.name)),
          ),
        if (presets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              filter.trim().isNotEmpty ? 'No matches' : 'None yet',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
      ],
    );
  }

  Widget _dragFeedback(String label) {
    return Material(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(label),
      ),
    );
  }
}
