import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/state/app_controller.dart';
import 'package:stunda/src/state/controller_scope.dart';
import 'package:stunda/src/widgets/drop_zone.dart';

import 'support/fakes.dart';

Future<void> _pump(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ControllerScope(
        controller: controller,
        child: const Scaffold(body: DropZone(child: SizedBox(height: 80))),
      ),
    ),
  );
  await tester.pump();
}

DropTarget _target(WidgetTester tester) =>
    tester.widget<DropTarget>(find.byType(DropTarget));

final _origin = DropEventDetails(
  localPosition: Offset.zero,
  globalPosition: Offset.zero,
);

void main() {
  testWidgets('drag enter then exit toggles the highlight border', (
    tester,
  ) async {
    final controller = AppController(runner: FakeEngineRunner());
    await _pump(tester, controller);

    AnimatedContainer box() =>
        tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    BoxBorder? border() => (box().decoration! as BoxDecoration).border;

    expect((border()! as Border).top.color, Colors.transparent);

    _target(tester).onDragEntered!(_origin);
    await tester.pump();
    expect((border()! as Border).top.color, isNot(Colors.transparent));

    _target(tester).onDragExited!(_origin);
    await tester.pump();
    expect((border()! as Border).top.color, Colors.transparent);
  });

  testWidgets('dropping supported files adds them as roots', (tester) async {
    final controller = AppController(runner: FakeEngineRunner());
    await controller.startScan('/a');
    await _pump(tester, controller);

    final dir = Directory.systemTemp.createTempSync('dz');
    addTearDown(() => dir.deleteSync(recursive: true));
    final jpg = File('${dir.path}/a.jpg')..writeAsStringSync('x');

    _target(tester).onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(jpg.path)],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.roots, ['/a', jpg.path]);
  });

  testWidgets('an empty drop is a no-op', (tester) async {
    final controller = AppController(runner: FakeEngineRunner());
    await controller.startScan('/a');
    await _pump(tester, controller);

    _target(tester).onDragDone!(
      const DropDoneDetails(
        files: [],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();

    expect(controller.roots, ['/a']);
  });
}
