import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'src/engine/device_photo_library.dart';
import 'src/engine/exiftool_bundle.dart';
import 'src/engine/onnx_bundle.dart';
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

  // On mobile the ONNX models ship as assets and must be copied to real files;
  // on desktop they are vendored next to the executable. The ONNX Runtime
  // library is loader-resolved on mobile and bundle-relative on desktop.
  final isMobile = Platform.isAndroid || Platform.isIOS;
  final onnxBundleDir = isMobile
      ? await prepareMobileOnnxBundle(support.path)
      : locateBundledOnnx();

  // Resolve the tile cache dir ONCE here (never per tile), build the persistent
  // browse-cache + provider, and best-effort seed the low-zoom world view so
  // the first open of the map paints immediately instead of grey.
  final cacheRoot = await getApplicationCacheDirectory();
  final tileCache = TileCache(client: http.Client(), root: cacheRoot);
  unawaited(seedLowZoomTiles(tileCache));

  // On mobile the app drives the device photo library directly (enumerate +
  // export proxies + native trash/GPS-write); on desktop there is none and the
  // controller stays in its filesystem mode.
  final photoLibrary = isMobile ? DevicePhotoLibrary() : null;

  runApp(
    StundaApp(
      exiftoolBundleDir: isMobile ? null : locateBundledExiftool(),
      onnxBundleDir: onnxBundleDir,
      prefs: prefs,
      tileProvider: CachingTileProvider(cache: tileCache),
      photoLibrary: photoLibrary,
      // RAW/JPEG pairing only maps cleanly on Android (separate MediaStore
      // assets); iOS fuses RAW+JPEG into one asset, so it's disabled there.
      mobileRawPruning: Platform.isAndroid,
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
    this.onnxBundleDir,
    this.prefs,
    this.tileProvider,
    this.photoLibrary,
    this.mobileRawPruning = false,
  });

  /// The controller to use; a fresh one is created when null.
  final AppController? controller;

  /// On-disk dir of the bundled exiftool, forwarded into a freshly built
  /// controller (ignored when [controller] is injected).
  final String? exiftoolBundleDir;

  /// On-disk dir of the bundled ONNX Runtime lib + detector model, forwarded
  /// into a freshly built controller (ignored when [controller] is injected).
  final String? onnxBundleDir;

  /// Persisted preferences forwarded into a freshly built controller (ignored
  /// when [controller] is injected).
  final AppPrefs? prefs;

  /// The map tile provider (backed by the persistent disk cache) exposed to the
  /// Explore screen; when null, Explore uses a plain network provider.
  final TileProvider? tileProvider;

  /// The device photo library on mobile (null on desktop), forwarded into a
  /// freshly built controller so it scans the library instead of a folder
  /// (ignored when [controller] is injected).
  final DevicePhotoLibrary? photoLibrary;

  /// Whether RAW pruning is available on this mobile platform (Android only;
  /// see [AppController.supportsRawPruning]). Ignored when [controller] is
  /// injected.
  final bool mobileRawPruning;

  @override
  State<StundaApp> createState() => _StundaAppState();
}

class _StundaAppState extends State<StundaApp> {
  late final AppController _controller =
      widget.controller ??
      AppController(
        exiftoolBundleDir: widget.exiftoolBundleDir,
        onnxBundleDir: widget.onnxBundleDir,
        prefs: widget.prefs,
        photoLibrary: widget.photoLibrary,
        requestPhotoAccess: widget.photoLibrary?.requestAccess,
        mobileRawPruning: widget.mobileRawPruning,
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
    // (an injected controller in tests must not spawn a server isolate) and
    // only on desktop — the MCP TCP/stdio server is a desktop-only feature and
    // its exiftool probe would misfire on mobile (no bundled exiftool there).
    if (widget.controller == null && !_controller.isMobile) {
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
