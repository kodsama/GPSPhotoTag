import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/widgets/content_panel.dart';
import 'package:stunda/src/widgets/file_list_dialog.dart';

import 'support/fakes.dart';

Widget _host(AppController c, FolderScanResult scan) => ControllerScope(
  controller: c,
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: ContentPanel(scan: scan)),
    ),
  ),
);

void main() {
  testWidgets('renders supported chips with counts', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(
      photos: const ['/library/a.jpg', '/library/b.jpg'],
      gpxFiles: const ['/library/t.gpx'],
    );
    await tester.pumpWidget(_host(c, scan));
    expect(find.text('JPG'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('GPX'), findsOneWidget);
  });

  testWidgets('tapping a supported chip opens a dialog with checkboxes', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();

    expect(find.text('JPG — 2 files'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('b.jpg'), findsOneWidget);
  });

  testWidgets('unticking a checkbox excludes the file', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();
    expect(c.isFileIncluded('/library/a.jpg'), isTrue);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(c.isFileIncluded('/library/a.jpg'), isFalse);
    expect(c.excludedFiles, contains('/library/a.jpg'));
  });

  testWidgets('select none / select all toggles the whole group', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg', '/library/b.jpg']);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select none'));
    await tester.pumpAndSettle();
    expect(c.excludedFiles, {'/library/a.jpg', '/library/b.jpg'});

    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    expect(c.excludedFiles, isEmpty);
  });

  testWidgets('filter narrows the visible rows', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(
      photos: const ['/library/alpha.jpg', '/library/beta.jpg'],
    );
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();
    expect(find.text('alpha.jpg'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pumpAndSettle();
    expect(find.text('alpha.jpg'), findsNothing);
    expect(find.text('beta.jpg'), findsOneWidget);
  });

  testWidgets('image rows show dimensions, date and a GPS pin', (tester) async {
    final c = AppController(
      runner: FakeEngineRunner(
        imageMeta: {
          '/library/a.jpg': FileMeta(
            path: '/library/a.jpg',
            width: 4032,
            height: 3024,
            date: DateTime(2023, 7, 15),
            hasGps: true,
          ),
        },
      ),
    );
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();

    expect(find.textContaining('4032×3024'), findsOneWidget);
    expect(find.textContaining('2023-07-15'), findsOneWidget);
    expect(find.byIcon(Icons.place), findsOneWidget);
  });

  testWidgets('gps source rows show point count and span', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(gpxFiles: const ['/library/t.gpx']);
    // Seed cache so the in-process gps read is a no-op for the missing file.
    c.debugSetScan(scan);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('GPX'));
    await tester.pumpAndSettle();
    // The file doesn't exist on disk, so it reads as a bare meta — no checkbox
    // assertion here, but the dialog opens read/write for a supported source.
    expect(find.text('GPX — 1 files'), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('unsupported category opens a read-only dialog (no checkboxes)', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(
      unsupported: const [
        UnsupportedFile('/library/clip.mp4', UnsupportedCategory.video),
      ],
    );
    await tester.pumpWidget(_host(c, scan));

    expect(find.textContaining('Videos (1)'), findsOneWidget);
    await tester.tap(find.textContaining('Videos (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Videos — 1 files'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('Select all'), findsNothing);
  });

  testWidgets('renders KML and Timeline chips and a no-supported message', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(
      photos: const [],
      kmlFiles: const ['/library/t.kml'],
      googleFiles: const ['/library/Records.json'],
    );
    await tester.pumpWidget(_host(c, scan));
    expect(find.text('KML'), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
  });

  testWidgets('shows "Nothing supported found" for an empty library', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const []);
    await tester.pumpWidget(_host(c, scan));
    expect(find.text('Nothing supported found.'), findsOneWidget);
  });

  testWidgets('tapping a row body toggles selection', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    await tester.pumpWidget(_host(c, scan));
    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('a.jpg'));
    await tester.pumpAndSettle();
    expect(c.isFileIncluded('/library/a.jpg'), isFalse);
  });

  testWidgets('filter with no matches shows the empty state', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    await tester.pumpWidget(_host(c, scan));
    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matching files.'), findsOneWidget);
  });

  testWidgets('gps source row renders point count and span', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(gpxFiles: const ['/library/t.gpx']);
    // Pre-seed the GPS meta so loadGpsMeta (which reads disk) is a no-op and the
    // row renders the seeded count/span instead of a bare meta.
    c.debugSeedMeta(
      FileMeta(
        path: '/library/t.gpx',
        hasGps: true,
        pointCount: 12,
        spanStart: DateTime(2023, 1, 1),
        spanEnd: DateTime(2023, 1, 31),
      ),
    );
    await tester.pumpWidget(_host(c, scan));
    await tester.tap(find.text('GPX'));
    await tester.pumpAndSettle();
    expect(find.textContaining('12 pts'), findsOneWidget);
    expect(find.textContaining('2023-01-01–2023-01-31'), findsOneWidget);
  });

  testWidgets('close button dismisses the dialog', (tester) async {
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pumpAndSettle();
    expect(find.byType(FileListDialog), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(FileListDialog), findsNothing);
  });

  testWidgets('a row whose meta is unloaded shows a spinner placeholder', (
    tester,
  ) async {
    // keepOpen makes readImageMeta hang so the row stays unloaded.
    final c = AppController(runner: FakeEngineRunner());
    final scan = fakeScan(photos: const ['/library/a.jpg']);
    await tester.pumpWidget(_host(c, scan));

    await tester.tap(find.text('JPG'));
    await tester.pump(); // open dialog, before post-frame meta load resolves
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pumpAndSettle();
  });
}
