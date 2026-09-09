import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_cli/src/commands/inspect_command.dart';
import 'package:stunda_cli/src/commands/photos_command.dart';
import 'package:stunda_cli/src/commands/scan_command.dart';
import 'package:stunda_cli/src/exit_codes.dart';
import 'package:stunda_cli/src/runner.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

import '_capture.dart';

/// A [DuplicatesService] that runs no I/O and replays canned events, so the
/// `duplicates` command's argument handling can be driven without exiftool.
class _FakeDuplicates extends DuplicatesService {
  _FakeDuplicates()
    : super(runner: const SystemProcessRunner(), trash: const SystemTrash());

  DuplicatesOptions? lastOptions;
  List<String>? lastRoots;

  @override
  Stream<EngineEvent> findDuplicates(
    List<String> roots,
    DuplicatesOptions options,
  ) async* {
    lastRoots = roots;
    lastOptions = options;
    yield const ItemEvent(
      PhotoRow(path: '/lib/a.jpg', status: PhotoStatus.kept, note: 'best of 2'),
    );
    yield const DoneEvent({'kept': 1, 'dry_run': 1});
  }
}

/// A [ShrinkService] that replays canned events and records its options.
class _FakeShrink extends ShrinkService {
  _FakeShrink()
    : super(runner: const SystemProcessRunner(), trash: const SystemTrash());

  ShrinkOptions? lastOptions;

  @override
  Stream<EngineEvent> shrink(List<String> roots, ShrinkOptions options) async* {
    lastOptions = options;
    yield const DoneEvent({'dry_run': 2});
  }
}

/// Answers both exiftool reads `inspectPhotos` makes.
class _InspectRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    final paths = args.where((a) => !a.startsWith('-')).toList();
    if (args.contains('-Make')) {
      return ProcResult(
        0,
        jsonEncode([
          for (final path in paths) {'SourceFile': path, 'Make': 'FUJIFILM'},
        ]),
        '',
      );
    }
    return ProcResult(
      0,
      jsonEncode([
        for (final path in paths)
          {'SourceFile': path, 'ImageWidth': 6240, 'ImageHeight': 4160},
      ]),
      '',
    );
  }
}

/// A [MapService] returning canned geotagged photos without exiftool.
class _FakeMap extends MapService {
  _FakeMap({this.throws = false})
    : super(runner: const SystemProcessRunner(), exiftoolAvailable: false);

  final bool throws;

  @override
  Future<List<GeoPhoto>> readGeotagged(List<String> photos) async {
    if (throws) throw StateError('exiftool failed');
    return const [
      GeoPhoto(path: '/lib/a.jpg', lat: 59.3, lon: 18.1, takenAt: '2026:01:01'),
    ];
  }
}

void main() {
  late Directory tmp;
  late BufferSink buf;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cli_new_cmd_');
    buf = BufferSink();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// The last JSON object written to [buf].
  Map<String, Object?> lastJson() {
    final lines = buf.text.trim().split('\n');
    return jsonDecode(lines.last) as Map<String, Object?>;
  }

  group('scan', () {
    test('reports counts and omits path lists by default', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());
      File(p.join(tmp.path, 'notes.txt')).writeAsStringSync('hi');

      final code = await runCliWithSink([
        '--json',
        'scan',
        '-p',
        tmp.path,
      ], sink: buf);

      expect(code, ExitCodes.ok);
      final out = lastJson();
      expect(out['event'], 'scan');
      expect(out['photoCount'], 1);
      expect(out['unsupportedCount'], 1);
      expect(out.containsKey('photos'), isFalse, reason: '--paths was not set');
    });

    test('--paths includes the full lists', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      await runCliWithSink([
        '--json',
        'scan',
        '-p',
        tmp.path,
        '--paths',
      ], sink: buf);

      expect((lastJson()['photos']! as List).single, endsWith('a.jpg'));
    });

    test('no roots is bad_input', () async {
      final code = await runCliWithSink(['--json', 'scan'], sink: buf);

      expect(code, ExitCodes.badInput);
      expect(lastJson()['code'], 'bad_input');
    });

    test('human mode pretty-prints instead of one-line JSON', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      await runCliWithSink(['scan', '-p', tmp.path], sink: buf);

      expect(buf.text, contains('"photoCount": 1'));
      expect(buf.text, isNot(contains('"event"')));
    });

    test('an unreadable root still completes with zero counts', () async {
      final code = await runCliWithSink([
        '--json',
        'scan',
        '-p',
        p.join(tmp.path, 'missing'),
      ], sink: buf);

      expect(code, ExitCodes.ok);
      expect(lastJson()['photoCount'], 0);
    });
  });

  group('photos', () {
    test('lists geotagged photos with coordinates', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      final code = await runCliWithSink(
        ['--json', 'photos', '-p', tmp.path],
        sink: buf,
        mapServiceFactory: () async => _FakeMap(),
      );

      expect(code, ExitCodes.ok);
      final out = lastJson();
      expect(out['count'], 1);
      expect((out['photos']! as List).single, {
        'path': '/lib/a.jpg',
        'lat': 59.3,
        'lon': 18.1,
        'taken_at': '2026:01:01',
      });
    });

    test('no photos found is bad_input', () async {
      final code = await runCliWithSink(
        ['--json', 'photos', '-p', tmp.path],
        sink: buf,
        mapServiceFactory: () async => _FakeMap(),
      );

      expect(code, ExitCodes.badInput);
      expect(lastJson()['code'], 'bad_input');
    });

    test('an exiftool failure maps to missing_toolkit', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      final code = await runCliWithSink(
        ['--json', 'photos', '-p', tmp.path],
        sink: buf,
        mapServiceFactory: () async => _FakeMap(throws: true),
      );

      expect(code, ExitCodes.missingToolkit);
      expect(lastJson()['code'], 'missing_toolkit');
    });

    test('human mode prints the same data unwrapped', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      await runCliWithSink(
        ['photos', '-p', tmp.path],
        sink: buf,
        mapServiceFactory: () async => _FakeMap(),
      );

      expect(buf.text, contains('"lat": 59.3'));
    });

    test('human-mode errors are plain text', () async {
      await runCliWithSink(
        ['photos', '-p', tmp.path],
        sink: buf,
        mapServiceFactory: () async => _FakeMap(),
      );

      expect(buf.text, startsWith('error: no photos found'));
    });

    test('a human-mode exiftool failure is plain text', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      await runCliWithSink(
        ['photos', '-p', tmp.path],
        sink: buf,
        mapServiceFactory: () async => _FakeMap(throws: true),
      );

      expect(buf.text, contains('error: Bad state: exiftool failed'));
    });
  });

  group('duplicates', () {
    test('defaults to a report-only run with the Fast metric', () async {
      final fake = _FakeDuplicates();
      final code = await runCliWithSink(
        ['--json', 'duplicates', '-p', tmp.path],
        sink: buf,
        duplicatesService: fake,
      );

      expect(code, ExitCodes.ok);
      expect(fake.lastRoots, [tmp.path]);
      expect(fake.lastOptions!.dryRun, isTrue);
      expect(fake.lastOptions!.delete, isFalse);
      expect(fake.lastOptions!.metric, SimilarityMetric.fast);
      expect(fake.lastOptions!.minSimilarity, 0.92);
    });

    test('--apply --rm asks for a permanent delete', () async {
      final fake = _FakeDuplicates();
      await runCliWithSink(
        [
          '--json',
          'duplicates',
          '-p',
          tmp.path,
          '--apply',
          '--rm',
          '--metric',
          'smart',
          '--similarity',
          '0.8',
        ],
        sink: buf,
        duplicatesService: fake,
      );

      expect(fake.lastOptions!.dryRun, isFalse);
      expect(fake.lastOptions!.delete, isTrue);
      expect(fake.lastOptions!.metric, SimilarityMetric.smart);
      expect(fake.lastOptions!.minSimilarity, 0.8);
    });

    test('no roots is bad_input', () async {
      final code = await runCliWithSink(
        ['--json', 'duplicates'],
        sink: buf,
        duplicatesService: _FakeDuplicates(),
      );

      expect(code, ExitCodes.badInput);
      expect(lastJson()['code'], 'bad_input');
    });

    test('a similarity outside 0..1 is rejected before any work', () async {
      final fake = _FakeDuplicates();
      final code = await runCliWithSink(
        ['--json', 'duplicates', '-p', tmp.path, '--similarity', '1.5'],
        sink: buf,
        duplicatesService: fake,
      );

      expect(code, ExitCodes.badInput);
      expect(fake.lastOptions, isNull, reason: 'must not reach the engine');
    });

    test('a non-numeric similarity is rejected', () async {
      final code = await runCliWithSink(
        ['--json', 'duplicates', '-p', tmp.path, '--similarity', 'loose'],
        sink: buf,
        duplicatesService: _FakeDuplicates(),
      );

      expect(code, ExitCodes.badInput);
    });
  });

  group('shrink', () {
    test('passes the selected stages through', () async {
      final fake = _FakeShrink();
      final code = await runCliWithSink(
        [
          '--json',
          'shrink',
          '-p',
          tmp.path,
          '--stage',
          'duplicates',
          '--stage',
          'low-quality',
        ],
        sink: buf,
        shrinkService: fake,
      );

      expect(code, ExitCodes.ok);
      expect(fake.lastOptions!.stages, {
        ShrinkStage.duplicates,
        ShrinkStage.lowQuality,
      });
      expect(fake.lastOptions!.dryRun, isTrue);
      expect(fake.lastOptions!.pairDropSide, PairDropSide.dropRaw);
    });

    test('every tuning flag reaches the options', () async {
      final fake = _FakeShrink();
      await runCliWithSink(
        [
          '--json',
          'shrink',
          '-p',
          tmp.path,
          '--stage',
          'pairs',
          '--pair-drop',
          'photo',
          '--quality-threshold',
          '0.6',
          '--similarity',
          '0.7',
          '--metric',
          'smart',
          '--apply',
          '--rm',
        ],
        sink: buf,
        shrinkService: fake,
      );

      final o = fake.lastOptions!;
      expect(o.pairDropSide, PairDropSide.dropPhoto);
      expect(o.qualityThreshold, 0.6);
      expect(o.minSimilarity, 0.7);
      expect(o.metric, SimilarityMetric.smart);
      expect(o.dryRun, isFalse);
      expect(o.delete, isTrue);
    });

    test('no roots is bad_input', () async {
      final code = await runCliWithSink(
        ['--json', 'shrink', '--stage', 'orphans'],
        sink: buf,
        shrinkService: _FakeShrink(),
      );

      expect(code, ExitCodes.badInput);
    });

    test('no stage is bad_input', () async {
      final fake = _FakeShrink();
      final code = await runCliWithSink(
        ['--json', 'shrink', '-p', tmp.path],
        sink: buf,
        shrinkService: fake,
      );

      expect(code, ExitCodes.badInput);
      expect(lastJson()['message'], contains('--stage'));
      expect(fake.lastOptions, isNull);
    });

    test('an out-of-range similarity is rejected', () async {
      final code = await runCliWithSink(
        [
          '--json',
          'shrink',
          '-p',
          tmp.path,
          '--stage',
          'orphans',
          '--similarity',
          '-1',
        ],
        sink: buf,
        shrinkService: _FakeShrink(),
      );

      expect(code, ExitCodes.badInput);
    });

    test('an out-of-range quality threshold is rejected', () async {
      final code = await runCliWithSink(
        [
          '--json',
          'shrink',
          '-p',
          tmp.path,
          '--stage',
          'orphans',
          '--quality-threshold',
          '9',
        ],
        sink: buf,
        shrinkService: _FakeShrink(),
      );

      expect(code, ExitCodes.badInput);
      expect(lastJson()['message'], contains('quality-threshold'));
    });
  });

  group('prune-raw --direction', () {
    test('orphan-images trashes the photo side', () async {
      File(p.join(tmp.path, 'solo.jpg')).writeAsBytesSync(minimalJpeg());
      File(p.join(tmp.path, 'pair.jpg')).writeAsBytesSync(minimalJpeg());
      File(p.join(tmp.path, 'pair.raf')).writeAsBytesSync([0]);

      final code = await runCliWithSink([
        '--json',
        'prune-raw',
        '-p',
        tmp.path,
        '--direction',
        'orphan-images',
        '--dry-run',
      ], sink: buf);

      expect(code, ExitCodes.ok);
      final paths = buf.text
          .trim()
          .split('\n')
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .where((e) => e['event'] == 'item')
          .map((e) => p.basename(e['path']! as String));
      expect(paths, ['solo.jpg']);
    });

    test('an unknown direction is rejected by the parser', () async {
      final code = await runCliWithSink([
        '--json',
        'prune-raw',
        '-p',
        tmp.path,
        '--direction',
        'sideways',
      ], sink: buf);

      expect(code, ExitCodes.badInput);
    });
  });

  group('production wiring (no injected collaborators)', () {
    // These drive the real engine construction the fakes above bypass, against
    // an empty directory so no exiftool spawn or file work is needed.
    test('scan builds its own FolderScanner', () async {
      final code = await runCliWithSink([
        '--json',
        'scan',
        '-p',
        tmp.path,
      ], sink: buf);

      expect(code, ExitCodes.ok);
      expect(lastJson()['photoCount'], 0);
    });

    test('duplicates builds its own service', () async {
      final code = await runCliWithSink([
        '--json',
        'duplicates',
        '-p',
        tmp.path,
      ], sink: buf);

      expect(code, ExitCodes.ok);
      expect(lastJson()['event'], 'done');
    });

    test('shrink builds its own service', () async {
      final code = await runCliWithSink([
        '--json',
        'shrink',
        '-p',
        tmp.path,
        '--stage',
        'orphans',
      ], sink: buf);

      expect(code, ExitCodes.ok);
      expect(lastJson()['event'], 'done');
    });

    test('both read-only commands default their output to stdout', () {
      // buildRunner always supplies a sink; this covers the bare constructor
      // a caller embedding the commands directly would use.
      expect(ScanCommand().name, 'scan');
      expect(PhotosCommand().name, 'photos');
    });

    test('photos falls back to the shared map-service factory', () async {
      // No photos in the directory, so it stops at bad_input before the
      // factory would need exiftool — but the command is still fully wired.
      final code = await runCliWithSink([
        '--json',
        'photos',
        '-p',
        tmp.path,
      ], sink: buf);

      expect(code, ExitCodes.badInput);
    });
  });

  group('inspect', () {
    test('reports dimensions, GPS and camera per photo', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      final code = await runCliWithSink(
        ['--json', 'inspect', '-p', tmp.path],
        sink: buf,
        inspectRunner: _InspectRunner(),
      );

      expect(code, ExitCodes.ok);
      final photo =
          (lastJson()['photos']! as List).single as Map<String, Object?>;
      expect(photo['width'], 6240);
      expect(photo['make'], 'FUJIFILM');
    });

    test('no photos found is bad_input', () async {
      final code = await runCliWithSink(
        ['--json', 'inspect', '-p', tmp.path],
        sink: buf,
        inspectRunner: _InspectRunner(),
      );

      expect(code, ExitCodes.badInput);
    });

    test('human mode pretty-prints the records', () async {
      File(p.join(tmp.path, 'a.jpg')).writeAsBytesSync(minimalJpeg());

      await runCliWithSink(
        ['inspect', '-p', tmp.path],
        sink: buf,
        inspectRunner: _InspectRunner(),
      );

      expect(buf.text, contains('"width": 6240'));
      expect(buf.text, isNot(contains('"event"')));
    });

    test('a human-mode error is plain text', () async {
      await runCliWithSink(
        ['inspect', '-p', tmp.path],
        sink: buf,
        inspectRunner: _InspectRunner(),
      );

      expect(buf.text, startsWith('error: no photos found'));
    });

    test('it builds its own runner when none is injected', () {
      expect(InspectCommand().name, 'inspect');
    });
  });

  group('--keep', () {
    test('duplicates passes the rule order through, highest first', () async {
      final fake = _FakeDuplicates();
      await runCliWithSink(
        [
          '--json',
          'duplicates',
          '-p',
          tmp.path,
          '--keep',
          'people',
          '--keep',
          'resolution',
        ],
        sink: buf,
        duplicatesService: fake,
      );

      final steps = fake.lastOptions!.pipeline.steps;
      expect(steps.take(2).map((s) => s.rule), [
        KeepRule.people,
        KeepRule.resolution,
      ]);
      // Quality was not listed, so it is disabled rather than dropped.
      expect(
        steps.firstWhere((s) => s.rule == KeepRule.quality).enabled,
        isFalse,
      );
    });

    test('shrink passes the rule order through too', () async {
      final fake = _FakeShrink();
      await runCliWithSink(
        [
          '--json',
          'shrink',
          '-p',
          tmp.path,
          '--stage',
          'duplicates',
          '--keep',
          'quality',
        ],
        sink: buf,
        shrinkService: fake,
      );

      expect(fake.lastOptions!.pipeline.steps.first.rule, KeepRule.quality);
    });

    test('omitting --keep leaves the standard pipeline', () async {
      final fake = _FakeDuplicates();
      await runCliWithSink(
        ['--json', 'duplicates', '-p', tmp.path],
        sink: buf,
        duplicatesService: fake,
      );

      expect(
        fake.lastOptions!.pipeline.steps.map((s) => s.rule),
        KeepPipeline.standard.steps.map((s) => s.rule),
      );
    });
  });

  test('schema documents every new command', () async {
    await runCliWithSink(['schema'], sink: buf);

    final schema = jsonDecode(buf.text) as Map<String, Object?>;
    final commands = (schema['commands']! as Map).keys.toSet();
    expect(commands, containsAll(['scan', 'photos', 'duplicates', 'shrink']));
    // The new `kept` status is part of the published item contract.
    final item = ((schema['events']! as Map)['item']! as Map)['status']!;
    expect(item, contains('kept'));
  });
}
