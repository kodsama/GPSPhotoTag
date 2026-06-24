@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/src/engine/isolate_runner.dart';

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
            gpxFiles: ['${tmp.path}/does-not-exist.gpx'],
            googleFiles: const [],
            options: const TagOptions(overwrite: true),
          )
          .toList();

      // _loadGpx throws on the unreadable file; the worker converts it to an
      // ErrorEvent and still sends the sentinel, so the stream closes cleanly.
      expect(events.whereType<ErrorEvent>(), isNotEmpty);
    },
  );
}
