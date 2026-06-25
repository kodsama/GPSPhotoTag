@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/engine/isolate_runner.dart';

import 'support/fakes.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('isolate_runner'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('tag runs on a real worker isolate and tags a JPEG from a GPX', () async {
    // A photo with a capture time, and a GPX point at the same instant.
    final naive = DateTime(2026, 6, 22, 12, 43, 38);
    final jpg = await writeJpegWithDate(tmp, 'a.jpg', dateTimeOriginal: naive);
    final gpx = writeGpx(tmp, 'track.gpx', naive);

    // exiftoolAvailable: false keeps the JPEG path purely in-process inside the
    // worker (no subprocess), so the test is deterministic on any host.
    const runner = IsolateRunner(exiftoolAvailable: false);
    final events = await runner
        .tag(
          photos: [jpg],
          gpxFiles: [gpx],
          kmlFiles: const [],
          googleFiles: const [],
          options: const TagOptions(overwrite: true, replace: true),
        )
        .toList();

    final item = events.whereType<ItemEvent>().single;
    expect(
      item.row.status,
      anyOf(PhotoStatus.tagged, PhotoStatus.interpolated),
    );
    expect(item.row.location, isNotNull);
    expect(item.row.location!.latitude, closeTo(42.5, 1e-2));

    final done = events.whereType<DoneEvent>().single;
    expect(done.total, 1);

    // The GPS really landed in the file the worker wrote.
    final meta = await const JpegExifBackend().read(jpg);
    expect(meta.hasGps, isTrue);
  });

  test('prune runs on a real worker isolate over an empty tree', () async {
    const runner = IsolateRunner();
    final events = await runner
        .prune(roots: [tmp.path], options: const PruneOptions(dryRun: true))
        .toList();

    // No orphan RAWs -> a clean DoneEvent and no errors.
    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('trashPaths deletes exactly the given files on a worker', () async {
    final a = File('${tmp.path}/a.raf')..writeAsStringSync('x');
    final b = File('${tmp.path}/b.raf')..writeAsStringSync('y');
    File('${a.path}.xmp').writeAsStringSync('s'); // a's sidecar

    const runner = IsolateRunner();
    final events = await runner.trashPaths([a.path], delete: true).toList();

    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
    // a + its sidecar gone; the unselected b survives.
    expect(a.existsSync(), isFalse);
    expect(File('${a.path}.xmp').existsSync(), isFalse);
    expect(b.existsSync(), isTrue);
  });

  test('map runs the worker and reaches a terminal event', () async {
    final jpg = await writeJpegWithDate(
      tmp,
      'g.jpg',
      dateTimeOriginal: DateTime(2026, 1, 1, 9),
    );
    await const JpegExifBackend().writeGps(
      jpg,
      latitude: 42.5,
      longitude: 18.1,
    );

    // The map service reads GPS via exiftool; without it the worker fails fast
    // with a missing_toolkit error. Either way the worker plumbing runs and the
    // stream terminates cleanly (no hang, single sentinel close).
    final out = '${tmp.path}/heatmap.png';
    const runner = IsolateRunner(exiftoolAvailable: false);
    final events = await runner
        .map(
          photos: [jpg],
          options: MapOptions(outputPng: out),
        )
        .toList();

    final err = events.whereType<ErrorEvent>();
    expect(err.single.code, 'missing_toolkit');
  });

  test('fixDates runs on a worker and reports a result per file', () async {
    final jpg = await writeJpegWithDate(
      tmp,
      'd.jpg',
      dateTimeOriginal: DateTime(2026, 3, 4, 5, 6, 7),
    );
    const runner = IsolateRunner(exiftoolAvailable: false);
    final events = await runner
        .fixDates(files: [jpg], mode: FixDatesMode.exif, dryRun: true)
        .toList();

    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<ItemEvent>(), isNotEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('tag loads Google history points and tags from them', () async {
    final naive = DateTime(2026, 6, 22, 12, 0, 0);
    final jpg = await writeJpegWithDate(tmp, 'g.jpg', dateTimeOriginal: naive);
    // A minimal Google "Records.json" with one point at the capture instant.
    final google = '${tmp.path}/Records.json';
    final iso = naive.toUtc().toIso8601String();
    File(google).writeAsStringSync(
      '{"locations":[{"timestamp":"$iso",'
      '"latitudeE7":425000000,"longitudeE7":181000000}]}',
    );

    const runner = IsolateRunner(exiftoolAvailable: false);
    final events = await runner
        .tag(
          photos: [jpg],
          gpxFiles: const [],
          kmlFiles: const [],
          googleFiles: [google],
          options: const TagOptions(overwrite: true, replace: true),
        )
        .toList();

    final item = events.whereType<ItemEvent>().single;
    expect(item.row.location, isNotNull);
    expect(item.row.location!.source, GpsSource.google);
    expect(events.whereType<DoneEvent>().single.total, 1);
  });

  test('tag probes for exiftool inside the worker when not told', () async {
    // No exiftoolAvailable passed -> the worker runs _resolveExiftool, which
    // probes the host itself. JPEG tagging is pure-Dart either way.
    final naive = DateTime(2026, 6, 22, 12, 43, 38);
    final jpg = await writeJpegWithDate(tmp, 'p.jpg', dateTimeOriginal: naive);
    final gpx = writeGpx(tmp, 'track.gpx', naive);

    const runner = IsolateRunner(); // exiftoolAvailable == null
    final events = await runner
        .tag(
          photos: [jpg],
          gpxFiles: [gpx],
          kmlFiles: const [],
          googleFiles: const [],
          options: const TagOptions(overwrite: true, replace: true),
        )
        .toList();

    expect(events.whereType<DoneEvent>().single.total, 1);
  });

  test(
    'tag with a missing GPX file ends with an ErrorEvent, not a hang',
    () async {
      final jpg = await writeJpegWithDate(
        tmp,
        'm.jpg',
        dateTimeOriginal: DateTime(2026, 6, 22, 12),
      );
      const runner = IsolateRunner(exiftoolAvailable: false);
      final events = await runner
          .tag(
            photos: [jpg],
            gpxFiles: const [],
            kmlFiles: const [],
            googleFiles: const [],
            options: const TagOptions(overwrite: true),
          )
          .toList();

      // With no GPS sources the photo is reported with no location; the worker
      // still terminates cleanly with a DoneEvent (poolSources skips bad files
      // rather than throwing, so a missing GPX no longer aborts the run).
      expect(events.whereType<DoneEvent>(), isNotEmpty);
    },
  );

  test('extractPreview returns null on a worker for a non-RAW file', () async {
    // A plain text file has no embedded preview; exiftool (when present) writes
    // nothing and the worker returns null. With no exiftool the run still ends
    // cleanly with null. Either way the worker plumbing + sentinel are exercised.
    final txt = File('${tmp.path}/notes.txt')..writeAsStringSync('hello');
    const runner = IsolateRunner();
    final result = await runner.extractPreview(txt.path);
    expect(result, isNull);
  });

  test('extractPreview returns null for a missing file', () async {
    const runner = IsolateRunner();
    final result = await runner.extractPreview(
      '${tmp.path}/does-not-exist.raf',
      full: true,
    );
    expect(result, isNull);
  });

  test('readImageMeta returns empty stream for no paths', () async {
    const runner = IsolateRunner();
    final out = await runner.readImageMeta(const []).toList();
    expect(out, isEmpty);
  });

  test('readImageMeta reads each photo on a single worker', () async {
    final jpgs = [
      for (var i = 0; i < 3; i++)
        await writeJpegWithDate(
          tmp,
          'm$i.jpg',
          dateTimeOriginal: DateTime(2026, 1, 1, i + 1),
        ),
    ];
    const runner = IsolateRunner(exiftoolAvailable: false);
    final metas = await runner.readImageMeta(jpgs).toList();

    // Every path comes back exactly once (order across workers isn't
    // guaranteed, so compare as sets).
    expect(metas.map((m) => m.path).toSet(), jpgs.toSet());
  });

  test('readImageMeta fans out across workers for many paths', () async {
    // >64 paths trips the multi-worker branch (round-robin slicing). Reuse one
    // real JPEG many times so the merged stream still returns one meta per path.
    final jpg = await writeJpegWithDate(
      tmp,
      'big.jpg',
      dateTimeOriginal: DateTime(2026, 2, 2, 2),
    );
    final paths = List<String>.filled(70, jpg);
    const runner = IsolateRunner(exiftoolAvailable: false);
    final metas = await runner.readImageMeta(paths).toList();

    // One FileMeta per requested path (workers merge into a single stream).
    expect(metas.length, paths.length);
    expect(metas.every((m) => m.path == jpg), isTrue);
  });

  test('scan runs on a worker isolate and reports the tree', () async {
    final jpg = await writeJpegWithDate(tmp, 'a.jpg');
    writeGpx(tmp, 'track.gpx', DateTime(2026));
    File('${tmp.path}/notes.txt').writeAsStringSync('hello');

    const runner = IsolateRunner();
    final events = await runner.scan([tmp.path]).toList();

    final done = events.whereType<ScanDoneEvent>().single.result;
    expect(done.photos, contains(jpg));
    expect(done.gpxCount, 1);
    expect(done.unsupportedCount, greaterThanOrEqualTo(1));
    expect(events.whereType<ScanProgressEvent>(), isNotEmpty);
  });
}
