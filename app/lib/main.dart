import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'src/engine/exiftool_bundle.dart';
import 'src/i18n/app_localizations.dart';
import 'src/explore/map_tile_provider.dart';
import 'src/explore/tile_cache.dart';
import 'src/explore/tile_provider_scope.dart';
import 'src/state/app_controller.dart';
import 'src/state/app_prefs.dart';
import 'src/state/controller_scope.dart';
import 'src/theme/app_theme.dart';
import 'src/widgets/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final prefs = await AppPrefs.load(support.path);

  // Resolve the tile cache dir ONCE here (never per tile), build the persistent
  // browse-cache + provider, and best-effort seed the low-zoom world view so
  // the first open of the map paints immediately instead of grey.
  final cacheRoot = await getApplicationCacheDirectory();
  final tileCache = TileCache(client: http.Client(), root: cacheRoot);
  unawaited(seedLowZoomTiles(tileCache));

  runApp(
    StundaApp(
      exiftoolBundleDir: locateBundledExiftool(),
      prefs: prefs,
      tileProvider: CachingTileProvider(cache: tileCache),
    ),
  );
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
    this.tileProvider,
  });

  /// The controller to use; a fresh one is created when null.
  final AppController? controller;

  /// On-disk dir of the bundled exiftool, forwarded into a freshly built
  /// controller (ignored when [controller] is injected).
  final String? exiftoolBundleDir;

  /// Persisted preferences forwarded into a freshly built controller (ignored
  /// when [controller] is injected).
  final AppPrefs? prefs;

  /// The map tile provider (backed by the persistent disk cache) exposed to the
  /// Explore screen; when null, Explore uses a plain network provider.
  final TileProvider? tileProvider;

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

  /// Drives the close-while-running guard's warning SnackBar (the [AppShell]
  /// Scaffold is below this widget, so a top-level messenger is needed).
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Guards quit/close while a background run is in flight.
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    // Always-on MCP endpoint for LLM clients, started only for the real app
    // (an injected controller in tests must not spawn a server isolate).
    if (widget.controller == null) {
      _controller.mcp.start();
      // Silent startup probe — surfaces a dismissible banner only if exiftool
      // can't launch. Non-blocking; the walkthrough stays fully usable.
      _controller.checkEnvironment();
    }
  }

  /// Blocks quitting while any action is running, warning the user to cancel it
  /// first; otherwise allows the app to exit. The decision itself is the
  /// controller's pure [AppController.exitDecision].
  Future<AppExitResponse> _onExitRequested() async {
    final decision = _controller.exitDecision;
    final messenger = _messengerKey.currentState;
    if (decision == AppExitResponse.cancel && messenger != null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(messenger.context.tr('exit_running'))),
        );
    }
    return decision;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tileProvider = widget.tileProvider;
    final app = ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        title: 'Stunda',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messengerKey,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: _controller.themeMode,
        locale: _controller.localeCode == null
            ? null
            : Locale(_controller.localeCode!),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        localeResolutionCallback: (deviceLocale, supported) => resolveLocale(
          override: _controller.localeCode,
          system: deviceLocale,
        ),
        home: const AppShell(),
      ),
    );
    return ControllerScope(
      controller: _controller,
      child: tileProvider == null
          ? app
          : TileProviderScope(tileProvider: tileProvider, child: app),
    );
  }
}
