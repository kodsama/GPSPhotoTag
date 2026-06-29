import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/main.dart';
import 'package:stunda/src/actions/prune_action.dart';
import 'package:stunda/src/actions/tag_action.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/app_screen.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/state/library_action.dart';
import 'package:stunda/src/widgets/drop_zone.dart';
import 'package:stunda_engine/stunda_engine.dart';

import 'support/fakes.dart';

LibraryAsset _asset(String id, {String? filename, double? lat, double? lng}) =>
    LibraryAsset(
      id: id,
      filename: filename ?? '$id.jpg',
      width: 100,
      height: 100,
      byteSize: 1,
      latitude: lat,
      longitude: lng,
    );

AppController _mobile(
  FakePhotoLibrary lib, {
  bool granted = true,
  bool rawPruning = false,
  Future<List<String>> Function()? pickTracks,
}) => AppController(
  runner: FakeEngineRunner(),
  photoLibrary: lib,
  requestPhotoAccess: () async => granted,
  pickTrackFiles: pickTracks,
  mobileRawPruning: rawPruning,
);

Future<void> _pump(WidgetTester tester, AppController controller) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(StundaApp(controller: controller));
  await tester.pump();
}

void main() {
  testWidgets('mobile welcome shows the scan button, not a drop zone', (
    tester,
  ) async {
    final c = _mobile(FakePhotoLibrary([_asset('a')]));
    await _pump(tester, c);
    expect(find.text('Scan photo library'), findsOneWidget);
    expect(find.byType(DropZone), findsNothing);
  });

  testWidgets('tapping scan lands on the workspace', (tester) async {
    final c = _mobile(FakePhotoLibrary([_asset('a')]));
    await _pump(tester, c);
    await tester.tap(find.text('Scan photo library'));
    await tester.pumpAndSettle();
    expect(c.screen, AppScreen.workspace);
  });

  testWidgets('denied access shows the permission message', (tester) async {
    final c = _mobile(FakePhotoLibrary([_asset('a')]), granted: false);
    await _pump(tester, c);
    await tester.tap(find.text('Scan photo library'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Photo access is needed'), findsOneWidget);
  });

  testWidgets('DropZone passes the child through on mobile (no DropTarget)', (
    tester,
  ) async {
    final c = _mobile(FakePhotoLibrary(const []));
    await tester.pumpWidget(
      ControllerScope(
        controller: c,
        child: const MaterialApp(
          home: DropZone(
            child: Text('child', textDirection: TextDirection.ltr),
          ),
        ),
      ),
    );
    expect(find.text('child'), findsOneWidget);
  });

  testWidgets('mobile tag action shows the track picker form', (tester) async {
    final c = _mobile(
      FakePhotoLibrary([_asset('a')]),
      pickTracks: () async => ['/picked.gpx'],
    );
    await c.scanLibrary();
    c.openAction(LibraryAction.tag);
    await _pump(tester, c);

    expect(find.byType(TagAction), findsOneWidget);
    expect(find.text('Pick GPS track files'), findsOneWidget);
    // Picking a file lists it.
    await tester.tap(find.text('Pick GPS track files'));
    await tester.pumpAndSettle();
    expect(find.text('/picked.gpx'), findsOneWidget);
  });

  testWidgets('mobile tag dry-run shows the preview label', (tester) async {
    final c = _mobile(
      FakePhotoLibrary([_asset('a')]),
      pickTracks: () async => ['/picked.gpx'],
    );
    await c.scanLibrary();
    c.openAction(LibraryAction.tag);
    c.setDryRun(true);
    await _pump(tester, c);
    expect(find.text('Preview 1 photos'), findsOneWidget);
  });

  testWidgets('iOS prune action shows the explanatory warning', (tester) async {
    // iOS (rawPruning false): the Photos library fuses RAW+JPEG, so warn.
    final c = _mobile(FakePhotoLibrary([_asset('a')]));
    await c.scanLibrary();
    c.openAction(LibraryAction.pruneRaw);
    await _pump(tester, c);
    expect(find.byType(PruneAction), findsOneWidget);
    expect(find.textContaining('not on iPhone'), findsOneWidget);
  });

  testWidgets('Android prune action shows the review, not the warning', (
    tester,
  ) async {
    // Android (rawPruning true): RAW + JPEG are separate assets that pair.
    final c = _mobile(
      FakePhotoLibrary([
        _asset('raw1', filename: 'IMG_1.DNG'),
        _asset('raw2', filename: 'IMG_2.DNG'),
      ]),
      rawPruning: true,
    );
    await c.scanLibrary();
    c.openAction(LibraryAction.pruneRaw);
    await _pump(tester, c);
    expect(find.byType(PruneAction), findsOneWidget);
    expect(find.textContaining('not on iPhone'), findsNothing);
    expect(c.pruneCandidates, ['IMG_1.DNG', 'IMG_2.DNG']);
  });
}
