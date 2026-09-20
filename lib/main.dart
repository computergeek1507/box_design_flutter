import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design/design_controller.dart';
import 'design/box_canvas.dart';
import 'services/hole_preset_library.dart';
import 'services/template_library.dart';
import 'services/theme_settings.dart';
import 'widgets/app_colors.dart';
import 'widgets/left_palette.dart';
import 'widgets/right_property_panel.dart';
import 'widgets/top_toolbar.dart';
import 'version.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeSettings = ThemeSettings();
  await themeSettings.load();
  runApp(BoxDesignApp(themeSettings: themeSettings));
}

class BoxDesignApp extends StatefulWidget {
  /// Pass an already-loaded instance (see [main]) to avoid a flash of the
  /// wrong theme at startup; otherwise the saved choice loads in the
  /// background.
  final ThemeSettings? themeSettings;

  const BoxDesignApp({super.key, this.themeSettings});

  @override
  State<BoxDesignApp> createState() => _BoxDesignAppState();
}

class _BoxDesignAppState extends State<BoxDesignApp> {
  late final ThemeSettings _themeSettings = widget.themeSettings ?? (ThemeSettings()..load());

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeSettings,
      builder: (context, _) => MaterialApp(
        title: 'Box Design',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, brightness: Brightness.dark),
        ),
        themeMode: _themeSettings.mode,
        home: BoxDesignHomePage(themeSettings: _themeSettings),
      ),
    );
  }
}

class BoxDesignHomePage extends StatefulWidget {
  final ThemeSettings? themeSettings;

  const BoxDesignHomePage({super.key, this.themeSettings});

  @override
  State<BoxDesignHomePage> createState() => _BoxDesignHomePageState();
}

class _BoxDesignHomePageState extends State<BoxDesignHomePage> {
  final TemplateLibrary _library = TemplateLibrary();
  final HolePresetLibrary _holePresetLibrary = HolePresetLibrary();
  late final DesignController _controller = DesignController(_library);
  final FocusNode _canvasFocusNode = FocusNode();
  late final Future<void> _initialLoad = _library.loadBuiltIns().then((_) async {
    await _library.loadUserTemplates();
    final defaultBox = _library.defaultBoxTemplate;
    if (defaultBox != null) _controller.applyBoxTemplate(defaultBox.id);
    // Fire-and-forget: refreshes/extends the bundled set from GitHub in the
    // background once the UI is already up on the bundled templates, so a
    // slow or unreachable network never delays first paint.
    _library.loadRemoteDefaults();
    _holePresetLibrary.loadRemoteDefaults();
  });

  @override
  void dispose() {
    _canvasFocusNode.dispose();
    _holePresetLibrary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: FutureBuilder<void>(
              future: _initialLoad,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Focus(
                  focusNode: _canvasFocusNode,
                  autofocus: true,
                  onKeyEvent: (node, event) => _handleKeyEvent(event),
                  child: Column(
                    children: [
                      TopToolbar(controller: _controller, themeSettings: widget.themeSettings),
                      Expanded(
                        child: Row(
                          children: [
                            SizedBox(
                              width: 240,
                              child: LeftPalette(
                                library: _library,
                                holePresetLibrary: _holePresetLibrary,
                                controller: _controller,
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: ColoredBox(
                                color: canvasBackground(context),
                                child: BoxCanvas(
                                  controller: _controller,
                                  focusNode: _canvasFocusNode,
                                ),
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            SizedBox(
                              width: 280,
                              child: RightPropertyPanel(controller: _controller),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            right: 6,
            bottom: 4,
            child: IgnorePointer(
              child: Text(
                'v$appVersion',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Delete/Backspace deletes the selected item; Ctrl/Cmd+C and Ctrl/Cmd+V
  /// copy and paste it. These only apply while the canvas itself holds
  /// focus: on some platforms (e.g. Windows) a focused text field elsewhere
  /// does not reliably consume the key event before it bubbles up here, so
  /// we explicitly bail out rather than relying on that.
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_canvasFocusNode.hasPrimaryFocus) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      _controller.deleteSelected();
      return KeyEventResult.handled;
    }

    final isCtrlOrCmd =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (isCtrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyC) {
      _controller.copySelected();
      return KeyEventResult.handled;
    }
    if (isCtrlOrCmd && event.logicalKey == LogicalKeyboardKey.keyV) {
      _controller.pasteClipboard();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }
}
