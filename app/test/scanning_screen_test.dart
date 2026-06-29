import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/screens/scanning_screen.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/controller_scope.dart';

import 'support/fakes.dart';

Future<void> _pump(WidgetTester tester, AppController c) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ControllerScope(
        controller: c,
        child: const Scaffold(body: ScanningScreen()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('desktop scanning screen shows the full per-category tally', (
    tester,
  ) async {
    final c = AppController(runner: FakeEngineRunner());
    await _pump(tester, c);
    // Folders / Files / Timeline are meaningful for a filesystem scan.
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Folders'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
  });

  testWidgets('mobile scanning screen shows only the photo count', (
    tester,
  ) async {
    // A photo library has no folders / GPS tracks / Timeline / unsupported, so
    // only the photo tally is shown while proxies are exported.
    final c = AppController(
      runner: FakeEngineRunner(),
      photoLibrary: FakePhotoLibrary(const []),
    );
    await _pump(tester, c);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Folders'), findsNothing);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Timeline'), findsNothing);
  });
}
