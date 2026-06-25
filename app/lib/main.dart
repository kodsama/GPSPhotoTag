import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/engine/exiftool_bundle.dart';
import 'src/state/app_controller.dart';
import 'src/state/app_prefs.dart';
import 'src/state/controller_scope.dart';
import 'src/theme/app_theme.dart';
import 'src/widgets/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final prefs = await AppPrefs.load(support.path);
  runApp(StundaApp(exiftoolBundleDir: locateBundledExiftool(), prefs: prefs));
}

/// Root of the Stunda desktop GUI.
///
/// Owns the single [AppController], publishes it to the tree via
/// [ControllerScope], and rebuilds [MaterialApp] when the theme mode changes.
class StundaApp extends StatefulWidget {
  /// Creates the app, optionally with an injected [controller] (tests). When no
  /// controller is injected, builds one wired to the bundled [exiftoolBundleDir]
  /// located in `main`.
  const StundaApp({
    super.key,
    this.controller,
    this.exiftoolBundleDir,
    this.prefs,
  });

  /// The controller to use; a fresh one is created when null.
  final AppController? controller;

  /// On-disk dir of the bundled exiftool, forwarded into a freshly built
  /// controller (ignored when [controller] is injected).
  final String? exiftoolBundleDir;

  /// Persisted preferences forwarded into a freshly built controller (ignored
  /// when [controller] is injected).
  final AppPrefs? prefs;

  @override
  State<StundaApp> createState() => _StundaAppState();
}

class _StundaAppState extends State<StundaApp> {
  late final AppController _controller =
      widget.controller ??
      AppController(
        exiftoolBundleDir: widget.exiftoolBundleDir,
        prefs: widget.prefs,
      );

  @override
  void initState() {
    super.initState();
    // Always-on MCP endpoint for LLM clients, started only for the real app
    // (an injected controller in tests must not spawn a server isolate).
    if (widget.controller == null) {
      _controller.mcp.start();
      // Silent startup probe — surfaces a dismissible banner only if exiftool
      // can't launch. Non-blocking; the walkthrough stays fully usable.
      _controller.checkEnvironment();
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ControllerScope(
      controller: _controller,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => MaterialApp(
          title: 'Stunda',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: _controller.themeMode,
          home: const AppShell(),
        ),
      ),
    );
  }
}
