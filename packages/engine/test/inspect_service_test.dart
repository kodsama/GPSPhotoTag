import 'dart:convert';

import 'package:stunda_engine/src/app/inspect_service.dart';
import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/services/keep_pipeline.dart';
import 'package:test/test.dart';

/// Answers the two exiftool reads `inspectPhotos` makes, keyed by which tags
/// the argument list asks for.
class _FakeRunner implements ProcessRunner {
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);
    final paths = args.where((a) => !a.startsWith('-')).toList();
    if (args.contains('-Make')) {
      return ProcResult(
        0,
        jsonEncode([
          for (final p in paths)
            {
              'SourceFile': p,
              'Make': 'FUJIFILM',
              'Model': 'X-T4',
              'LensModel': 'XF23mmF1.4',
              'ISO': 320,
              'FNumber': 1.4,
            },
        ]),
        '',
      );
    }
    return ProcResult(
      0,
      jsonEncode([
        for (final p in paths)
          {
            'SourceFile': p,
            'ImageWidth': 6240,
            'ImageHeight': 4160,
            'GPSLatitude': 59.33,
            'GPSLongitude': 18.07,
            'DateTimeOriginal': '2026:09:09 10:00:00',
          },
      ]),
      '',
    );
  }
}

void main() {
  test(
    'inspectPhotos merges dimensions, GPS and camera into one record',
    () async {
      final runner = _FakeRunner();

      final info = await inspectPhotos(['/lib/a.jpg'], runner: runner);

      expect(info, hasLength(1));
      final json = info.single.toJson();
      expect(json['path'], '/lib/a.jpg');
      expect(json['width'], 6240);
      expect(json['hasGps'], isTrue);
      expect(json['make'], 'FUJIFILM');
      expect(json['lens'], 'XF23mmF1.4');
      // One batched call per source, not one per photo.
      expect(runner.calls, hasLength(2));
    },
  );

  test('a photo exiftool omits still yields a bare record', () async {
    final info = await inspectPhotos([
      '/lib/a.jpg',
      '/lib/ghost.jpg',
    ], runner: _FakeRunner());

    expect(info.map((i) => i.path), ['/lib/a.jpg', '/lib/ghost.jpg']);
    expect(info.every((i) => i.path.isNotEmpty), isTrue);
  });

  group('keepPipelineFromNames', () {
    test('an empty list is the standard pipeline', () {
      expect(
        keepPipelineFromNames([])!.steps.map((s) => s.rule),
        KeepPipeline.standard.steps.map((s) => s.rule),
      );
    });

    test('the given order becomes the priority, enabled', () {
      final pipeline = keepPipelineFromNames(['people', 'resolution'])!;

      expect(pipeline.steps.take(2).map((s) => s.rule), [
        KeepRule.people,
        KeepRule.resolution,
      ]);
      expect(pipeline.steps.take(2).every((s) => s.enabled), isTrue);
    });

    test('omitted rules are appended disabled, never dropped', () {
      final pipeline = keepPipelineFromNames(['quality'])!;

      expect(
        pipeline.steps.map((s) => s.rule).toSet(),
        KeepRule.values.toSet(),
      );
      expect(pipeline.steps.first.enabled, isTrue);
      expect(pipeline.steps.skip(1).every((s) => !s.enabled), isTrue);
    });

    test('a repeated rule is kept once', () {
      final pipeline = keepPipelineFromNames(['people', 'people'])!;

      expect(
        pipeline.steps.where((s) => s.rule == KeepRule.people),
        hasLength(1),
      );
    });

    test('an unknown rule is null so callers report bad_input', () {
      expect(keepPipelineFromNames(['sharpness']), isNull);
    });
  });
}
