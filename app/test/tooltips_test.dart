// Locks the localized hover tooltips onto the interactive controls: each test
// pumps a surface and asserts its tooltips exist (find.byTooltip resolves the
// English fallback the tests pump in). Guards the tooltip wiring against
// accidental removal and keeps the i18n keys referenced from real widgets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/actions/duplicates_action.dart';
import 'package:stunda/src/actions/prune_action.dart';
import 'package:stunda/src/screens/welcome_screen.dart';
import 'package:stunda/src/screens/workspace_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/state/app_prefs.dart';
import 'package:stunda/src/state/duplicates_model.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/content_panel.dart';
import 'package:stunda/src/widgets/library_bar.dart';
import 'package:stunda/src/widgets/settings_dialog.dart';

import 'support/fakes.dart';

HashedFile _hf(String path) => HashedFile(
  path: path,
  width: 100,
  height: 100,
  fileSize: 2048,
  basename: path,
  isRaw: false,
);

Widget _host(AppController c, Widget child) => ControllerScope(
  controller: c,
  child: MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// Hosts a self-scrolling surface (e.g. the [SettingsDialog], an AlertDialog
/// with its own scroll view) WITHOUT an outer [SingleChildScrollView], so an
/// inner [ReorderableListView]'s viewport is never asked for intrinsics.
Widget _hostNoScroll(AppController c, Widget child) => ControllerScope(
  controller: c,
  child: MaterialApp(home: Scaffold(body: child)),
);

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('welcome: choose-library and drop-zone tooltips', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    await tester.pumpWidget(_host(c, const WelcomeScreen()));

    expect(
      find.byTooltip('Pick a folder of photos to open as your library'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Drag folders or photos here to open them'),
      findsOneWidget,
    );
  });

  testWidgets('library bar: add-folder and change-library tooltips', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
    await tester.pumpWidget(
      _host(c, LibraryBar(scan: fakeScan(photos: const ['/library/a.jpg']))),
    );

    expect(
      find.byTooltip('Add another folder to this library'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Open a different folder as your library'),
      findsOneWidget,
    );
  });

  testWidgets('library bar: each removable root chip has a remove tooltip', (
    tester,
  ) async {
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(scan, roots: const ['/one', '/two']);
    await tester.pumpWidget(_host(c, LibraryBar(scan: scan)));

    expect(find.byTooltip('Remove from library'), findsNWidgets(2));
  });

  testWidgets('workspace: action cards and readiness chips have tooltips', (
    tester,
  ) async {
    _bigView(tester);
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
    await tester.pumpWidget(_host(c, const WorkspaceScreen()));
    await tester.pump();

    // The Explore card's description, surfaced as the card tooltip.
    expect(
      find.byTooltip(
        'Open this action: Browse your geotagged photos on a live, '
        'zoomable map.',
      ),
      findsOneWidget,
    );
    // One readiness chip tooltip per action card (four actions).
    expect(
      find.byTooltip('Whether this action is ready to run'),
      findsNWidgets(LibraryAction.all.length),
    );
  });

  testWidgets('duplicates: similarity slider and keep-rule tooltips', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScreen(AppScreen.action, action: LibraryAction.duplicates);
    await tester.pumpWidget(_host(c, DuplicatesAction()));

    expect(
      find.byTooltip(
        'Drag toward Loose to also catch lightly-edited near-duplicates',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Drag to reorder priority'), findsWidgets);
    expect(find.byTooltip('Turn this keep rule on or off'), findsWidgets);
  });

  testWidgets('duplicates: pair, remove-right and remove-button tooltips', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetDuplicatePairs([
        DuplicatePair(
          kept: _hf('/library/a.jpg'),
          other: _hf('/library/b.jpg'),
        ),
      ]);
    await tester.pumpWidget(_host(c, DuplicatesAction()));
    await tester.pump();

    // The pair defaults to "remove right selected", so its checkbox + the
    // remove button both expose their tooltips.
    expect(find.byTooltip('Remove the file on the right'), findsOneWidget);
    expect(
      find.byTooltip('Move the selected duplicates to the Trash'),
      findsOneWidget,
    );

    // Deselecting flips the checkbox tooltip to the keep-both message.
    c.setDuplicateRemoval(0, false);
    await tester.pump();
    expect(find.byTooltip('Keep both files — remove neither'), findsOneWidget);
  });

  testWidgets('prune: direction options, chips and move button tooltips', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner())
      ..debugSetScan(
        fakeScan(photos: const ['/library/orphan.raf', '/library/lonely.jpg']),
      )
      ..debugSetScreen(AppScreen.action, action: LibraryAction.pruneRaw);
    await tester.pumpWidget(_host(c, const PruneAction()));
    await tester.pump();

    expect(
      find.byTooltip('Show RAW files that have no matching photo'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Show photos that have no matching RAW'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Show or hide these files in the list'),
      findsNWidgets(3),
    );
    expect(
      find.byTooltip('Move the selected files to the Trash'),
      findsOneWidget,
    );
  });

  testWidgets('settings: language, theme, background and intensity tooltips', (
    tester,
  ) async {
    _bigView(tester);
    final c = AppController(runner: FakeEngineRunner(), prefs: AppPrefs())
      // A background image so the reset affordance (and its tooltip) renders.
      ..setBackgroundImagePath('/bg.jpg');
    await tester.pumpWidget(_hostNoScroll(c, SettingsDialog(controller: c)));
    await tester.pump();

    expect(find.byTooltip('Choose the app language'), findsOneWidget);
    expect(
      find.byTooltip('Choose light, dark, or follow the system'),
      findsOneWidget,
    );
    expect(find.byTooltip('Pick a custom background image'), findsOneWidget);
    expect(find.byTooltip('Use the default background'), findsOneWidget);
    expect(
      find.byTooltip('How strongly the background is veiled'),
      findsOneWidget,
    );
    // The Home actions section: a drag handle + a show/hide toggle per action.
    expect(find.byTooltip('Drag to reorder the action cards'), findsWidgets);
    expect(find.byTooltip('Show or hide this action card'), findsWidgets);
  });

  testWidgets('file list: select-all/none and filename-preview tooltips', (
    tester,
  ) async {
    final c = AppController(
      runner: FakeEngineRunner(
        imageMeta: {'/library/a.jpg': const FileMeta(path: '/library/a.jpg')},
      ),
    )..debugSetScan(fakeScan(photos: const ['/library/a.jpg']));
    await tester.pumpWidget(
      _host(c, ContentPanel(scan: fakeScan(photos: const ['/library/a.jpg']))),
    );

    // Open the drill-down dialog for the JPG group.
    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Select every file in this group'), findsOneWidget);
    expect(find.byTooltip('Clear the selection'), findsOneWidget);
    expect(find.byTooltip('Open a preview of this photo'), findsOneWidget);
  });
}
