import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/src/state/app_controller.dart';
import 'package:gpsphototag_gui/src/state/input_summary.dart';
import 'package:gpsphototag_gui/src/state/wizard_step.dart';

ToolStatus _tool(String id, {bool present = true}) => ToolStatus(
      id: id,
      name: id,
      present: present,
      purpose: 'test',
      required: false,
    );

InputSummary _summaryWith(List<String> photos) => InputSummary.from(
      folder: '/photos',
      photos: photos,
      gpxFiles: const [],
      googleFiles: const [],
    );

void main() {
  group('step-advance logic', () {
    test('toolkit is unsatisfied until results arrive, then advances to input',
        () {
      final c = AppController();
      expect(c.step, WizardStep.toolkit);
      expect(c.isStepSatisfied(WizardStep.toolkit), isFalse);

      c.debugSetToolkit([_tool('exiftool')]);
      expect(c.isStepSatisfied(WizardStep.toolkit), isTrue);

      c.completeAndAdvance();
      expect(c.isCompleted(WizardStep.toolkit), isTrue);
      expect(c.step, WizardStep.input);
    });

    test('completeAndAdvance is a no-op when the step is unsatisfied', () {
      final c = AppController();
      c.completeAndAdvance();
      expect(c.step, WizardStep.toolkit);
      expect(c.isCompleted(WizardStep.toolkit), isFalse);
    });

    test('input needs at least one included photo', () {
      final c = AppController()..debugSetStep(WizardStep.input);
      expect(c.isStepSatisfied(WizardStep.input), isFalse);

      c.debugSetSummary(_summaryWith(['/photos/a.jpg', '/photos/b.jpg']));
      expect(c.isStepSatisfied(WizardStep.input), isTrue);
      expect(c.includedCount, 2);
    });

    test('review reflects include/exclude toggles', () {
      final c = AppController()
        ..debugSetSummary(_summaryWith(['/photos/a.jpg', '/photos/b.jpg']));
      c.setIncluded('/photos/a.jpg', false);
      expect(c.includedCount, 1);
      expect(c.includedPhotos, ['/photos/b.jpg']);
    });

    test('goTo only revisits completed or earlier steps', () {
      final c = AppController()
        ..debugSetStep(WizardStep.review,
            completed: {WizardStep.toolkit, WizardStep.input});
      c.goTo(WizardStep.run); // not completed, later -> ignored
      expect(c.step, WizardStep.review);
      c.goTo(WizardStep.toolkit); // completed -> allowed
      expect(c.step, WizardStep.toolkit);
    });
  });

  group('options', () {
    test('embed RAW mode is rejected without exiftool', () {
      final c = AppController();
      c.setRawMode(RawMode.embed);
      expect(c.rawMode, RawMode.auto);

      c.debugSetToolkit([_tool('exiftool')]);
      c.setRawMode(RawMode.embed);
      expect(c.rawMode, RawMode.embed);
    });

    test('in-place run sets overwrite; copy run sets outDir', () {
      final c = AppController();
      expect(c.buildTagOptions().overwrite, isTrue);
      expect(c.buildTagOptions().outDir, isNull);

      c.setCopyToFolder(true);
      c.setOutDir('/out');
      final opts = c.buildTagOptions();
      expect(opts.overwrite, isFalse);
      expect(opts.outDir, '/out');
    });

    test('output step needs a destination only when copying', () {
      final c = AppController()..debugSetStep(WizardStep.output);
      expect(c.isStepSatisfied(WizardStep.output), isTrue);
      c.setCopyToFolder(true);
      expect(c.isStepSatisfied(WizardStep.output), isFalse);
      c.setOutDir('/out');
      expect(c.isStepSatisfied(WizardStep.output), isTrue);
    });
  });

  group('activity log', () {
    test('debug log entries raise the unread count and markLogRead clears it',
        () {
      final c = AppController();
      c.debugAddLog('hello');
      c.debugAddLog('world', level: LogLevel.error);
      expect(c.unreadCount, 2);
      expect(c.logEntries.length, 2);
      c.markLogRead();
      expect(c.unreadCount, 0);
    });
  });
}
