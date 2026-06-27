@Timeout(Duration(seconds: 60))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/engine/isolate_runner.dart';
import 'package:stunda/src/engine/onnx_bundle.dart';

import 'support/fakes.dart';

/// Runs a worker entry in-process against a real port and returns every event
/// it sent before the terminal `null` sentinel.
Future<List<Object?>> _drain(Future<void> Function(SendPort) run) async {
  final receive = ReceivePort();
  // The entry awaits internally and always ends by sending a null sentinel.
  // Collect up to (not including) that first null; the sentinel terminates the
  // stream so we never close the port out from under in-flight messages.
  final collected = receive
      .takeWhile((m) => m != null)
      .cast<Object?>()
      .toList();
  await run(receive.sendPort);
  final events = await collected;
  receive.close();
  return events;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('worker_entries'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // These tests run the worker entry points IN-PROCESS (not via Isolate.spawn)
  // against a real ReceivePort, so the worker bodies — invisible to coverage
  // when they run on a spawned isolate — are exercised directly.

  group('buildWorkerRunner', () {
    test('returns a plain system runner when no bundle dir is given', () {
      expect(buildWorkerRunner(null), isA<SystemProcessRunner>());
    });

    test('routes exiftool through the bundle when a dir is given', () {
      final runner = buildWorkerRunner('/some/bundle/dir');
      expect(runner, isA<ExiftoolRunner>());
    });
  });

  group('resolveWorkerExiftool', () {
    test('returns the passed value without probing', () async {
      expect(await resolveWorkerExiftool(true), isTrue);
      expect(await resolveWorkerExiftool(false), isFalse);
    });

    test('probes the host when given null', () async {
      // Real probe: returns a bool either way (true/false depending on host).
      expect(await resolveWorkerExiftool(null), isA<bool>());
    });
  });

  test('previewCacheDir points under the system temp dir', () {
    expect(previewCacheDir().path, contains('stunda_preview_cache'));
  });

  group('pumpEvents', () {
    test('forwards each event then a null sentinel', () async {
      final events = await _drain(
        (port) => pumpEvents<int>(
          port,
          Stream.fromIterable([1, 2, 3]),
          onError: (m) => -1,
        ),
      );
      expect(events, [1, 2, 3]); // the trailing null sentinel is stripped
    });

    test('converts a stream error via onError before the sentinel', () async {
      final events = await _drain(
        (port) => pumpEvents<String>(
          port,
          Stream<String>.error(StateError('boom')),
          onError: (m) => 'converted: $m',
        ),
      );
      expect(events.single, startsWith('converted:'));
    });
  });

  group('worker entry happy paths (in-process)', () {
    test('scanEntry scans a tree and ends with a ScanDoneEvent', () async {
      await writeJpegWithDate(tmp, 'a.jpg');
      final events = await _drain(
        (port) => scanEntry(ScanRequest(port: port, roots: [tmp.path])),
      );
      expect(events.whereType<ScanDoneEvent>(), isNotEmpty);
    });

    test('tagEntry tags a JPEG from a GPX in-process', () async {
      final naive = DateTime(2026, 6, 22, 12, 43, 38);
      final jpg = await writeJpegWithDate(
        tmp,
        't.jpg',
        dateTimeOriginal: naive,
      );
      final gpx = writeGpx(tmp, 'track.gpx', naive);
      final events = await _drain(
        (port) => tagEntry(
          TagRequest(
            port: port,
            photos: [jpg],
            gpxFiles: [gpx],
            kmlFiles: const [],
            googleFiles: const [],
            options: const TagOptions(overwrite: true, replace: true),
            exiftoolAvailable: false,
            bundleDir: null,
          ),
        ),
      );
      expect(events.whereType<DoneEvent>(), isNotEmpty);
      expect(events.whereType<ItemEvent>().single.row.location, isNotNull);
    });

    test('pruneEntry over an empty tree ends cleanly', () async {
      final events = await _drain(
        (port) => pruneEntry(
          PruneRequest(
            port: port,
            roots: [tmp.path],
            options: const PruneOptions(dryRun: true),
          ),
        ),
      );
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(events.whereType<DoneEvent>(), isNotEmpty);
    });

    test('trashPathsEntry deletes exactly the given file', () async {
      final a = File('${tmp.path}/a.raf')..writeAsStringSync('x');
      final events = await _drain(
        (port) => trashPathsEntry(
          TrashPathsRequest(port: port, paths: [a.path], delete: true),
        ),
      );
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(events.whereType<DoneEvent>(), isNotEmpty);
      expect(a.existsSync(), isFalse);
    });

    test(
      'readImageMetaEntry sends a FileMeta per path then a sentinel',
      () async {
        final jpg = await writeJpegWithDate(
          tmp,
          'r.jpg',
          dateTimeOriginal: DateTime(2026, 3, 3, 3),
        );
        final events = await _drain(
          (port) => readImageMetaEntry(
            ReadImageMetaRequest(port: port, paths: [jpg], bundleDir: null),
          ),
        );
        expect(events.whereType<FileMeta>().map((m) => m.path), [jpg]);
      },
    );

    test('fixDatesEntry reports a result per file in-process', () async {
      final jpg = await writeJpegWithDate(
        tmp,
        'd.jpg',
        dateTimeOriginal: DateTime(2026, 3, 4, 5, 6, 7),
      );
      final events = await _drain(
        (port) => fixDatesEntry(
          FixDatesRequest(
            port: port,
            files: [jpg],
            mode: FixDatesMode.exif,
            dryRun: true,
            exiftoolAvailable: false,
            bundleDir: null,
          ),
        ),
      );
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(events.whereType<ItemEvent>(), isNotEmpty);
      expect(events.whereType<DoneEvent>(), isNotEmpty);
    });

    test(
      'hashFilesEntry hashes via the batch path and ticks per file',
      () async {
        final jpg = await writeJpegWithDate(tmp, 'h.jpg');
        final txt = File('${tmp.path}/notes.txt')
          ..writeAsStringSync('not image');
        final events = await _drain(
          (port) => hashFilesEntry(
            HashFilesRequest(
              port: port,
              paths: [jpg, txt.path],
              bundleDir: null,
            ),
          ),
        );
        // The JPEG hashes (via the batch fallback decode); the text file is
        // skipped (undecodable) — but both still emit a progress tick.
        final hashed = events.whereType<HashedFile>().toList();
        expect(hashed.map((h) => h.path), [jpg]);
        // One `1` tick per input file (hashed or skipped) keeps the bar moving.
        final ticks = events.whereType<int>().toList();
        expect(ticks, [1, 1]);
      },
    );

    test(
      'hashFilesEntry runs Tier-2 detection when a model is bundled',
      () async {
        final bundleDir = _onnxBundleDir();
        final hasBundle =
            bundleDir != null &&
            (resolveOnnxBundle(bundleDir)?.isComplete ?? false);
        if (!hasBundle) {
          markTestSkipped('no ONNX bundle (run tool/fetch-onnx.sh)');
          return;
        }
        // A real photo of a person, hashed with NO people metadata, so the only
        // way it gets a non-zero peopleScore is the Tier-2 native detector.
        final person = p.join(tmp.path, 'person.jpg');
        File(
          person,
        ).writeAsBytesSync(File(_fixture('person.jpg')).readAsBytesSync());
        final events = await _drain(
          (port) => hashFilesEntry(
            HashFilesRequest(
              port: port,
              paths: [person],
              bundleDir: null,
              onnxBundleDir: bundleDir,
            ),
          ),
        );
        final hashed = events.whereType<HashedFile>().single;
        expect(hashed.peopleScore, greaterThan(0.5));
      },
    );

    test('hashFilesEntry processes more than one chunk', () async {
      // More paths than [hashBatchChunk] forces a second batch iteration. The
      // files are non-images (skipped) but each still ticks, so progress reaches
      // the total across both chunks.
      final paths = [
        for (var i = 0; i < hashBatchChunk + 5; i++)
          (File('${tmp.path}/n$i.txt')..writeAsStringSync('x')).path,
      ];
      final events = await _drain(
        (port) => hashFilesEntry(
          HashFilesRequest(port: port, paths: paths, bundleDir: null),
        ),
      );
      expect(events.whereType<HashedFile>(), isEmpty);
      expect(events.whereType<int>(), hasLength(paths.length));
    });

    test('extractPreviewEntry returns null for a non-RAW file', () async {
      final txt = File('${tmp.path}/notes.txt')..writeAsStringSync('hi');
      final receive = ReceivePort();
      final first = receive.first;
      await extractPreviewEntry(
        ExtractPreviewRequest(
          port: receive.sendPort,
          path: txt.path,
          full: false,
          bundleDir: null,
        ),
      );
      final result = await first;
      receive.close();
      expect(result, isNull);
    });
  });
}

/// An image fixture under test/fixtures/ (cwd is the package root in tests).
String _fixture(String name) {
  for (final base in const [
    ['test', 'fixtures'],
    ['app', 'test', 'fixtures'],
  ]) {
    final path = p.joinAll([Directory.current.path, ...base, name]);
    if (File(path).existsSync()) return path;
  }
  return p.join('test', 'fixtures', name);
}

/// The repo's `app/assets/onnx/<platform>/` bundle dir (populated by
/// tool/fetch-onnx.sh), found by walking up from the working directory, or null.
String? _onnxBundleDir() {
  final platform = onnxPlatformSubdir(Platform.operatingSystem);
  if (platform == null) return null;
  var dir = Directory.current.absolute.path;
  for (var i = 0; i < 6; i++) {
    final candidate = p.join(dir, 'app', 'assets', 'onnx', platform);
    if (Directory(candidate).existsSync()) return candidate;
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}
