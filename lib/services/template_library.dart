import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:http/http.dart' as http;

import '../dxf/dxf_parser.dart';
import '../models/controller_template.dart';
import 'user_template_store.dart';

/// Raw-content base URL for this project's own bundled templates —
/// `loadRemoteDefaults` fetches `index.json` + each listed template from
/// here, so the app can pick up templates added to the repo after this
/// build without an app update.
const String defaultTemplateRepoUrl =
    'https://raw.githubusercontent.com/computergeek1507/box_design_flutter/main/assets/templates';

/// Holds every template available to the palette: bundled placeholders,
/// user-imported DXF/JSON templates, and (optionally) ones fetched from a
/// remote repo.
class TemplateLibrary extends ChangeNotifier {
  final List<ControllerTemplate> _templates = [];
  final UserTemplateStore _userTemplateStore = UserTemplateStore();

  List<ControllerTemplate> get templates => List.unmodifiable(_templates);

  List<ControllerTemplate> get userMadeTemplates =>
      _templates.where((t) => t.source == TemplateSource.userMade).toList();

  ControllerTemplate? byId(String id) {
    for (final t in _templates) {
      if (t.id == id) return t;
    }
    return null;
  }

  List<ControllerTemplate> byCategory(TemplateCategory category) =>
      _templates.where((t) => t.category == category).toList();

  ControllerTemplate? get defaultBoxTemplate {
    final boxes = byCategory(TemplateCategory.box);
    return boxes.isEmpty ? null : boxes.first;
  }

  Future<void> loadBuiltIns() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assetPaths = manifest
        .listAssets()
        .where((p) => p.startsWith('assets/templates/') && p.endsWith('.json') && !p.endsWith('/index.json'));
    for (final path in assetPaths) {
      final raw = await rootBundle.loadString(path);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _templates.add(ControllerTemplate.fromJson(json, source: TemplateSource.builtIn));
    }
    notifyListeners();
  }

  ControllerTemplate importDxf(String id, String name, String dxfContent, TemplateCategory category) {
    final entities = parseDxf(dxfContent);
    final template = ControllerTemplate(
      id: id,
      name: name,
      entities: entities,
      source: TemplateSource.imported,
      category: category,
    );
    _templates.add(template);
    notifyListeners();
    return template;
  }

  ControllerTemplate importJson(String jsonContent) {
    final json = jsonDecode(jsonContent) as Map<String, dynamic>;
    final template = ControllerTemplate.fromJson(json, source: TemplateSource.imported);
    _templates.add(template);
    notifyListeners();
    return template;
  }

  /// Loads previously-saved user-made templates (see [saveUserTemplate])
  /// from local storage -- call once at startup, alongside [loadBuiltIns].
  Future<void> loadUserTemplates() async {
    final saved = await _userTemplateStore.loadAll();
    _templates.addAll(saved);
    notifyListeners();
  }

  /// Saves [template] as a user-made template (from the Template Maker) and
  /// persists the full user-made set to local storage so it survives an app
  /// restart. Any template (built-in, remote, imported, or user-made) can be
  /// opened in the Template Maker and re-saved this way, but its id must
  /// stay unique: re-saving your own previously-saved user-made template
  /// under the same id updates it in place, while saving under an id that
  /// belongs to some *other* template (e.g. editing a copy of a bundled
  /// template) is never allowed to collide with or replace that original --
  /// it's suffixed (`_2`, `_3`, ...) into a fresh, unique id instead. Returns
  /// the saved template, whose id may differ from [template]'s for that
  /// reason.
  Future<ControllerTemplate> saveUserTemplate(ControllerTemplate template) async {
    final isOwnUpdate = _templates.any((t) => t.id == template.id && t.source == TemplateSource.userMade);

    var id = template.id;
    if (!isOwnUpdate) {
      final existingIds = _templates.map((t) => t.id).toSet();
      if (existingIds.contains(id)) {
        var suffix = 2;
        while (existingIds.contains('${template.id}_$suffix')) {
          suffix++;
        }
        id = '${template.id}_$suffix';
      }
    }

    _templates.removeWhere((t) => t.id == id && t.source == TemplateSource.userMade);
    final saved = ControllerTemplate(
      id: id,
      name: template.name,
      entities: template.entities,
      source: TemplateSource.userMade,
      category: template.category,
      annotations: template.annotations,
      layer2Entities: template.layer2Entities,
    );
    _templates.add(saved);
    notifyListeners();
    await _userTemplateStore.saveAll(userMadeTemplates);
    return saved;
  }

  /// Fetches `<repoBaseUrl>/index.json` — a JSON list of `{"id": ...,
  /// "file": ...}` entries (see `tool/gen_placeholder_templates.dart`'s
  /// `writeIndex`) — then GETs each `<repoBaseUrl>/<file>` template JSON
  /// and adds it to the library, replacing any bundled template with the
  /// same id.
  Future<int> fetchRemoteTemplates(String repoBaseUrl) async {
    final base = repoBaseUrl.endsWith('/') ? repoBaseUrl.substring(0, repoBaseUrl.length - 1) : repoBaseUrl;
    final indexResponse = await http.get(Uri.parse('$base/index.json'));
    if (indexResponse.statusCode != 200) {
      throw Exception('Failed to fetch template index: HTTP ${indexResponse.statusCode}');
    }
    final index = jsonDecode(indexResponse.body) as List<dynamic>;
    var count = 0;
    for (final entry in index) {
      final file = (entry as Map<String, dynamic>)['file'] as String;
      final response = await http.get(Uri.parse('$base/$file'));
      if (response.statusCode != 200) continue;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _templates.removeWhere((t) => t.id == json['id']);
      _templates.add(ControllerTemplate.fromJson(json, source: TemplateSource.remote));
      count++;
    }
    notifyListeners();
    return count;
  }

  /// Best-effort refresh from [defaultTemplateRepoUrl] — call after
  /// [loadBuiltIns] so the app still works offline on the bundled set.
  /// Any failure (offline, blocked, repo unreachable) is swallowed.
  Future<void> loadRemoteDefaults() async {
    try {
      await fetchRemoteTemplates(defaultTemplateRepoUrl);
    } catch (_) {
      // Bundled templates already loaded; a remote refresh is optional.
    }
  }

  Future<void> remove(String id) async {
    final wasUserMade = _templates.any((t) => t.id == id && t.source == TemplateSource.userMade);
    _templates.removeWhere((t) => t.id == id);
    notifyListeners();
    if (wasUserMade) {
      await _userTemplateStore.saveAll(userMadeTemplates);
    }
  }
}
