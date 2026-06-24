import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a TagService backed by the real registry (exiftool not required for
/// JPEG, which is all these tests touch).
TagService _service() => TagService(
      registry: BackendRegistry(
        runner: const SystemProcessRunner(),
        exiftoolAvailable: false,
      ),
    );

String _freshJpeg(Directory dir, String name) {
  final path = p.join(dir.path, name);
  File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
  return path;
}

Future<List<EngineEvent>> _collect(Stream<EngineEvent> s) => s.toList();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tagsvc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A photo timestamp and a GPX point at the same instant (tz-independent: both
  // derive from the same local DateTime when no EXIF offset is present).
  final naive = DateTime(2026, 6, 22, 12, 43, 38);
  final onTime = TimedPoint(
    latitude: 42.5,
    longitude: 18.1,
    time: naive.toUtc(),
  );

  test('refuses to write without out or overwrite', () async {
    final events = await _collect(_service().tag(
      photos: [_freshJpeg(tmp, 'a.jpg')],
      gpx: [onTime],
      options: const TagOptions(),
    ));
    expect(events.single, isA<ErrorEvent>());
    expect((events.single as ErrorEvent).code, 'bad_input');
  });

  test('no timestamp -> noTimestamp', () async {
    final events = await _collect(_service().tag(
      photos: [_freshJpeg(tmp, 'a.jpg')],
      gpx: [onTime],
      options: const TagOptions(overwrite: true),
    ));
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.noTimestamp);
  });

  test('tags a photo whose time matches the track', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    // Seed a capture time (and a throwaway GPS, which we will overwrite).
    await backend.writeGps(path, latitude: 0, longitude: 0,
        dateTimeOriginal: naive);

    final events = await _collect(_service().tag(
      photos: [path],
      gpx: [onTime],
      options: const TagOptions(overwrite: true, replace: true),
    ));
    final item = events.whereType<ItemEvent>().single;
    expect(
      item.row.status,
      anyOf(PhotoStatus.tagged, PhotoStatus.interpolated),
    );
    expect(item.row.location!.latitude, closeTo(42.5, 1e-3));

    final meta = await backend.read(path);
    expect(meta.hasGps, isTrue);

    final done = events.whereType<DoneEvent>().single;
    expect(done.total, 1);
  });

  test('already-tagged photo is skipped without replace', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    await backend.writeGps(path, latitude: 42.5, longitude: 18.1,
        dateTimeOriginal: naive);

    final events = await _collect(_service().tag(
      photos: [path],
      gpx: [onTime],
      options: const TagOptions(overwrite: true),
    ));
    expect(events.whereType<ItemEvent>().single.row.status,
        PhotoStatus.alreadyTagged);
  });

  test('no source within threshold -> noGps', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    await backend.writeGps(path, latitude: 0, longitude: 0,
        dateTimeOriginal: naive);

    final far = TimedPoint(
      latitude: 1,
      longitude: 1,
      time: naive.toUtc().add(const Duration(hours: 5)),
    );
    final events = await _collect(_service().tag(
      photos: [path],
      gpx: [far],
      options: const TagOptions(overwrite: true, replace: true),
    ));
    expect(events.whereType<ItemEvent>().single.row.status, PhotoStatus.noGps);
  });

  test('dry run reports a would-be fix but writes nothing', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    await backend.writeGps(path, latitude: 0, longitude: 0,
        dateTimeOriginal: naive);
    final before = File(path).readAsBytesSync();

    final events = await _collect(_service().tag(
      photos: [path],
      gpx: [onTime],
      options: const TagOptions(dryRun: true, replace: true),
    ));
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.dryRun);
    expect(item.row.location, isNotNull);
    // The file is byte-for-byte unchanged: dry run wrote nothing.
    expect(File(path).readAsBytesSync(), before);
  });
}
