import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/main.dart' as app_main;
import 'package:stunda/main.dart';
import 'package:stunda/src/explore/map_tile_provider.dart';
import 'package:stunda/src/explore/tile_cache.dart';
import 'package:stunda/src/explore/tile_provider_scope.dart';
import 'package:stunda/src/screens/scanning_screen.dart';
import 'package:stunda/src/screens/welcome_screen.dart';
import 'package:stunda/src/screens/workspace_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/widgets/activity_log_panel.dart';
import 'package:stunda/src/widgets/warning_banner.dart';

import 'support/fakes.dart';

ToolStatus _tool(String id, {bool present = true, String? version}) =>
    ToolStatus(
      id: id,
      name: id,
      present: present,
      version: version,
      purpose: 'unlocks $id',
      required: false,
    );

Future<void> _pumpApp(WidgetTester tester, AppController controller) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(StundaApp(controller: controller));
  await tester.pump();
}

void main() {
  testWidgets('AppShell renders the header and the welcome screen', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool', version: '12.0')]);
    await _pumpApp(tester, controller);

    expect(find.text('Stunda'), findsWidgets);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(controller.screen, AppScreen.welcome);
    expect(find.text('Choose photo library'), findsOneWidget);
  });

  testWidgets('the welcome screen shows the drop hint and Add folder', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);

    expect(find.text('Drop folders or photos here'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Add folder'), findsOneWidget);
  });

  testWidgets('tapping Add folder on welcome adds a root and scans', (
    tester,
  ) async {
    final fake = FakeEngineRunner(scanEvents: [ScanDoneEvent(fakeScan())]);
    final controller = AppController(
      runner: fake,
      pickFolder: () async => '/pics',
    )..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add folder'));
    await tester.pumpAndSettle();

    expect(controller.roots, ['/pics']);
    expect(controller.screen, AppScreen.workspace);
  });

  testWidgets('the workspace shows Add folder and removable root chips', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')])
      ..debugSetScan(fakeScan(), roots: ['/a', '/b']);
    await _pumpApp(tester, controller);

    expect(find.widgetWithText(OutlinedButton, 'Add folder'), findsOneWidget);
    // One chip per root (basename labels).
    expect(find.widgetWithText(Chip, 'a'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'b'), findsOneWidget);

    // Deleting a chip rescans the remaining root.
    await tester.tap(find.byTooltip('Remove from library').first);
    await tester.pumpAndSettle();
    expect(controller.roots.length, 1);
  });

  testWidgets('the scanning screen shows live tallies and the folder name', (
    tester,
  ) async {
    // A scan stream that emits progress then holds open, so the scanning
    // screen (with the folder name) stays on screen for assertions.
    final fake = FakeEngineRunner(
      keepOpen: true,
      scanEvents: const [ScanProgressEvent(ScanProgress(files: 5, photos: 3))],
    );
    addTearDown(fake.release);
    final controller = AppController(runner: fake)
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);
    unawaited(controller.startScan('/Users/me/Pictures'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ScanningScreen), findsOneWidget);
    expect(find.text('Scanning your library…'), findsOneWidget);
    expect(find.text('Pictures'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('3'), findsWidgets); // live photo tally

    // Release and pump a frame (no settle: the indeterminate bar never stops).
    fake.release();
    await tester.pump();
  });

  testWidgets('picking a library scans it and lands on the workspace', (
    tester,
  ) async {
    final controller = AppController(
      runner: FakeEngineRunner(
        scanEvents: [
          const ScanProgressEvent(ScanProgress(files: 2, photos: 1)),
          ScanDoneEvent(fakeScan(gpxFiles: const ['/library/t.gpx'])),
        ],
      ),
      pickFolder: () async => '/library',
    )..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);

    await tester.tap(find.text('Choose photo library'));
    await tester.pumpAndSettle();

    expect(controller.screen, AppScreen.workspace);
    expect(find.byType(WorkspaceScreen), findsOneWidget);
  });

  group('warning banner', () {
    testWidgets('shows when an environment warning is set', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        probeToolkit: () async => [_tool('exiftool', present: false)],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(find.byType(WarningBanner), findsOneWidget);
      expect(find.textContaining("ExifTool couldn't start"), findsOneWidget);
    });

    testWidgets('hides after the close button is tapped', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        probeToolkit: () async => [_tool('exiftool', present: false)],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();

      expect(controller.warningDismissed, isTrue);
      expect(find.textContaining("ExifTool couldn't start"), findsNothing);
    });

    testWidgets('renders nothing when no warning is set', (tester) async {
      final controller = AppController(
        runner: FakeEngineRunner(),
        probeToolkit: () async => [_tool('exiftool')],
      );
      await controller.checkEnvironment();
      await _pumpApp(tester, controller);

      expect(controller.environmentWarning, isNull);
      expect(find.textContaining("ExifTool couldn't start"), findsNothing);
    });
  });

  testWidgets('a provided tileProvider is published via TileProviderScope', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('apptiles');
    addTearDown(() => root.deleteSync(recursive: true));
    final provider = CachingTileProvider(
      cache: TileCache(
        client: MockClient((_) async => http.Response('', 200)),
        root: root,
      ),
    );
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      StundaApp(controller: controller, tileProvider: provider),
    );
    await tester.pump();

    expect(find.byType(TileProviderScope), findsOneWidget);
    final scope = tester.widget<TileProviderScope>(
      find.byType(TileProviderScope),
    );
    expect(scope.tileProvider, same(provider));
  });

  testWidgets('main() boots the real app end to end', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Fake the platform dirs main() resolves (support/cache) so no plugin
    // channel is needed; point them at a temp dir.
    final dirs = Directory.systemTemp.createTempSync('main_boot');
    addTearDown(() => dirs.deleteSync(recursive: true));
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(dirs.path);
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);

    await tester.runAsync(() async {
      // The best-effort, unawaited tile seed in main() will try the network;
      // override the HttpClient so it fails fast offline instead of hanging.
      await HttpOverrides.runZoned(() async {
        await app_main.main();
        await tester.pump();
        expect(find.byType(StundaApp), findsOneWidget);

        // Let the async startup probe + offline seed settle before teardown.
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }, createHttpClient: (_) => _OfflineHttpClient());
    });
  });

  testWidgets(
    'with no injected controller, StundaApp builds its own and starts services',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(() async {
        // No `controller:` -> the State builds a real AppController, starts the
        // MCP server isolate, and runs the environment probe (initState branch).
        await tester.pumpWidget(const StundaApp(prefs: null));
        await tester.pump();

        // The real app stands up on its welcome screen.
        expect(find.byType(WelcomeScreen), findsOneWidget);

        // Let the async environment probe (real exiftool) settle while the
        // controller is still mounted, so its notifyListeners runs before
        // dispose.
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.pump();

        // Tear the app down: dispose() (controller == null branch) stops the
        // MCP isolate and frees the controller.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        // Let the spawned server isolate finish shutting down cleanly.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
    },
  );

  testWidgets('MCP status no longer lives in the header', (tester) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);
    expect(find.textContaining('MCP'), findsNothing);
  });

  testWidgets('the settings menu appearance item flips the theme', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')]);
    await _pumpApp(tester, controller);

    // The standalone toggle is gone — the theme lives in the overflow menu.
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Appearance:'));
    await tester.pumpAndSettle();
    expect(controller.themeMode, isNot(ThemeMode.system));
  });

  testWidgets(
    'activity-log button lives in the header (not a FAB), toggles the panel',
    (tester) async {
      final controller = AppController(runner: FakeEngineRunner())
        ..debugSetToolkit([_tool('exiftool')])
        ..debugAddLog('first event')
        ..debugAddLog('second event');
      await _pumpApp(tester, controller);

      expect(find.byType(ActivityLogPanel), findsOneWidget);
      // The log button is no longer a floating action button.
      expect(find.byType(FloatingActionButton), findsNothing);

      // It rides in the header as a tappable button.
      final logButton = find.byTooltip('Activity log');
      expect(logButton, findsOneWidget);

      await tester.tap(logButton);
      await tester.pumpAndSettle();

      expect(find.text('Activity log'), findsOneWidget);
      expect(find.text('first event'), findsOneWidget);
      expect(find.text('second event'), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      // Still in the header, still not a FAB.
      expect(find.byTooltip('Activity log'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    },
  );

  testWidgets('the header log button shows the unread-count badge', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner())
      ..debugSetToolkit([_tool('exiftool')])
      ..debugAddLog('first event')
      ..debugAddLog('second event');
    await _pumpApp(tester, controller);

    // Two unread entries -> the badge reads "2", overlaid on the header button.
    expect(controller.unreadCount, 2);
    // The badge "2" sits in the innermost Stack wrapping the log icon.
    final logBadgeStack = find
        .ancestor(
          of: find.byIcon(Icons.receipt_long),
          matching: find.byType(Stack),
        )
        .first;
    expect(
      find.descendant(of: logBadgeStack, matching: find.text('2')),
      findsOneWidget,
    );

    // Opening the log marks it read, so the badge disappears.
    await tester.tap(find.byTooltip('Activity log'));
    await tester.pumpAndSettle();
    expect(controller.unreadCount, 0);
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.byIcon(Icons.receipt_long),
              matching: find.byType(Stack),
            )
            .first,
        matching: find.text('2'),
      ),
      findsNothing,
    );
  });
}

/// A path_provider stub so `main()` can resolve its support/cache dirs in tests
/// without a platform channel.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this._root);
  final String _root;

  @override
  Future<String?> getApplicationSupportPath() async => _root;
  @override
  Future<String?> getApplicationCachePath() async => _root;
  @override
  Future<String?> getApplicationDocumentsPath() async => _root;
  @override
  Future<String?> getTemporaryPath() async => _root;
}

/// An [HttpClient] that refuses every connection, so the best-effort tile seed
/// in `main()` fails fast offline instead of touching the real network.
class _OfflineHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  noSuchMethod(Invocation invocation) =>
      throw const SocketExceptionStub('offline in tests');
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub(this.message);
  final String message;
  @override
  String toString() => 'SocketExceptionStub: $message';
}
