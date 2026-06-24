import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A backend that returns a fixed [PhotoMeta] and records writeGps targets.
///
/// Lets tests drive the `_toUtc` offset path and the copy-to-out target path
/// without depending on real EXIF I/O.
class _FakeBackend implements ExifBackend {
  _FakeBackend(this._meta);

  final PhotoMeta _meta;
  final List<String> writes = [];

  @override
  bool supports(String path) => true;

  @override
  Future<PhotoMeta> read(String path) async => _meta;

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async => writes.add(path);
}

/// A backend whose writeGps always throws, to drive the error branch.
class _ThrowingBackend extends _FakeBackend {
  _ThrowingBackend(super.meta);

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async => throw StateError('boom');
}

/// A registry that can read but never write — drives the no-writer branch.
class _NoWriterRegistry extends _FakeRegistry {
  _NoWriterRegistry(super.backend);

  @override
  ExifBackend? writerFor(String path) => null;
}

/// A registry whose reader/writer is always [_backend] regardless of path.
class _FakeRegistry implements BackendRegistry {
  _FakeRegistry(this._backend);

  final _FakeBackend _backend;

  @override
  ExifBackend? readerFor(String path) => _backend;
  @override
  ExifBackend? writerFor(String path) => _backend;
  @override
  bool writesSidecar(String path) => false;
  @override
  bool get exiftoolAvailable => true;
  @override
  RawMode get rawMode => RawMode.auto;
}

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
    final events = await _collect(
      _service().tag(
        photos: [_freshJpeg(tmp, 'a.jpg')],
        gpx: [onTime],
        options: const TagOptions(),
      ),
    );
    expect(events.single, isA<ErrorEvent>());
    expect((events.single as ErrorEvent).code, 'bad_input');
  });

  test('no timestamp -> noTimestamp', () async {
    final events = await _collect(
      _service().tag(
        photos: [_freshJpeg(tmp, 'a.jpg')],
        gpx: [onTime],
        options: const TagOptions(overwrite: true),
      ),
    );
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.noTimestamp);
  });

  test('tags a photo whose time matches the track', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    // Seed a capture time (and a throwaway GPS, which we will overwrite).
    await backend.writeGps(
      path,
      latitude: 0,
      longitude: 0,
      dateTimeOriginal: naive,
    );

    final events = await _collect(
      _service().tag(
        photos: [path],
        gpx: [onTime],
        options: const TagOptions(overwrite: true, replace: true),
      ),
    );
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
    await backend.writeGps(
      path,
      latitude: 42.5,
      longitude: 18.1,
      dateTimeOriginal: naive,
    );

    final events = await _collect(
      _service().tag(
        photos: [path],
        gpx: [onTime],
        options: const TagOptions(overwrite: true),
      ),
    );
    expect(
      events.whereType<ItemEvent>().single.row.status,
      PhotoStatus.alreadyTagged,
    );
  });

  test('no source within threshold -> noGps', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    await backend.writeGps(
      path,
      latitude: 0,
      longitude: 0,
      dateTimeOriginal: naive,
    );

    final far = TimedPoint(
      latitude: 1,
      longitude: 1,
      time: naive.toUtc().add(const Duration(hours: 5)),
    );
    final events = await _collect(
      _service().tag(
        photos: [path],
        gpx: [far],
        options: const TagOptions(overwrite: true, replace: true),
      ),
    );
    expect(events.whereType<ItemEvent>().single.row.status, PhotoStatus.noGps);
  });

  test('unsupported format with no reader -> error', () async {
    // .heic with exiftool unavailable: readerFor returns null.
    final heic = p.join(tmp.path, 'a.heic');
    File(heic).writeAsBytesSync([0, 1, 2]);
    final events = await _collect(
      _service().tag(
        photos: [heic],
        gpx: [onTime],
        options: const TagOptions(overwrite: true),
      ),
    );
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.error);
    expect(item.row.note, contains('unsupported format'));
  });

  test('no write strategy -> error (sidecar disabled for embed)', () async {
    // .raf is readable via the sidecar backend (knows no sidecar exists, so no
    // capture time) — drive the no-writer branch with a fake instead.
    final meta = PhotoMeta(captureNaive: naive);
    final backend = _FakeBackend(meta);
    // Reader present, but writerFor null: a registry that reads but cannot write.
    final registry = _NoWriterRegistry(backend);
    final service = TagService(registry: registry);
    final events = await _collect(
      service.tag(
        photos: [p.join(tmp.path, 'a.raf')],
        gpx: [onTime],
        options: const TagOptions(overwrite: true),
      ),
    );
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.error);
    expect(item.row.note, contains('no write strategy'));
  });

  test('writeGps throwing surfaces as an error row', () async {
    final backend = _ThrowingBackend(PhotoMeta(captureNaive: naive));
    final service = TagService(registry: _FakeRegistry(backend));
    final events = await _collect(
      service.tag(
        photos: ['a.jpg'],
        gpx: [onTime],
        options: const TagOptions(overwrite: true, replace: true),
      ),
    );
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.error);
    expect(item.row.note, contains('boom'));
  });

  test('out dir copies the source and writes to the copy', () async {
    final backend = _FakeBackend(PhotoMeta(captureNaive: naive));
    final service = TagService(registry: _FakeRegistry(backend));
    final src = _freshJpeg(tmp, 'a.jpg');
    final outDir = p.join(tmp.path, 'tagged');

    final events = await _collect(
      service.tag(
        photos: [src],
        gpx: [onTime],
        options: TagOptions(outDir: outDir),
      ),
    );

    final target = p.join(outDir, 'a.jpg');
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.path, target);
    expect(File(target).existsSync(), isTrue, reason: 'source copied to out');
    expect(backend.writes, [target], reason: 'wrote to the copy, not source');
  });

  test('offset EXIF drives the UTC subtraction path', () async {
    // captureNaive 12:00 with a +02:00 offset -> 10:00 UTC.
    final meta = PhotoMeta(
      captureNaive: DateTime(2026, 6, 22, 12),
      offset: const Duration(hours: 2),
    );
    final backend = _FakeBackend(meta);
    final service = TagService(registry: _FakeRegistry(backend));
    // GPX point exactly at the offset-corrected instant.
    final pt = TimedPoint(
      latitude: 10,
      longitude: 20,
      time: DateTime.utc(2026, 6, 22, 10),
    );
    final events = await _collect(
      service.tag(
        photos: ['a.jpg'],
        gpx: [pt],
        options: const TagOptions(overwrite: true, replace: true),
      ),
    );
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.timestamp, DateTime.utc(2026, 6, 22, 10));
    expect(item.row.location!.method, GpsMethod.exact);
  });

  test('dry run reports a would-be fix but writes nothing', () async {
    const backend = JpegExifBackend();
    final path = _freshJpeg(tmp, 'a.jpg');
    await backend.writeGps(
      path,
      latitude: 0,
      longitude: 0,
      dateTimeOriginal: naive,
    );
    final before = File(path).readAsBytesSync();

    final events = await _collect(
      _service().tag(
        photos: [path],
        gpx: [onTime],
        options: const TagOptions(dryRun: true, replace: true),
      ),
    );
    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.dryRun);
    expect(item.row.location, isNotNull);
    // The file is byte-for-byte unchanged: dry run wrote nothing.
    expect(File(path).readAsBytesSync(), before);
  });
}
