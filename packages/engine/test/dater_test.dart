import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/src/data/exif/exif_backend.dart';
import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/domain/engine_event.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:stunda_engine/src/domain/status.dart';
import 'package:stunda_engine/src/services/dater.dart';
import 'package:test/test.dart';

/// Returns a fixed [PhotoMeta]; never reads from disk.
class FakeExifBackend implements ExifBackend {
  FakeExifBackend({this.captureNaive});

  final DateTime? captureNaive;

  @override
  bool supports(String path) => true;

  @override
  Future<PhotoMeta> read(String path) async =>
      PhotoMeta(captureNaive: captureNaive);

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async => throw UnimplementedError();
}

/// Records every invocation and returns a canned result (or throws).
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({
    this.result = const ProcResult(0, '', ''),
    this.throws = false,
  });

  final ProcResult result;
  final bool throws;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add([executable, ...args]);
    if (throws) throw const ProcessException('exiftool', []);
    return result;
  }
}

void main() {
  late Directory dir;
  late String photo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dater_test_');
    photo = p.join(dir.path, 'photo.jpg');
    File(photo).writeAsStringSync('x');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('exif direction sets file mtime from EXIF capture time', () async {
    final capture = DateTime(2021, 7, 4, 13, 37, 5);
    final dater = Dater(
      exif: FakeExifBackend(captureNaive: capture),
      runner: FakeProcessRunner(),
    );

    final events = await dater.fixDates([photo], FixDatesMode.exif).toList();

    final mtime = await File(photo).lastModified();
    expect(mtime.year, capture.year);
    expect(mtime.month, capture.month);
    expect(mtime.day, capture.day);
    expect(mtime.hour, capture.hour);
    expect(mtime.minute, capture.minute);

    final items = events.whereType<ItemEvent>().toList();
    expect(items, hasLength(1));
    expect(items.single.row.status, PhotoStatus.datesFixed);

    final done = events.whereType<DoneEvent>().single;
    expect(done.summary[PhotoStatus.datesFixed.wire], 1);
  });

  test(
    'exif direction with no capture time emits noTimestamp and leaves mtime',
    () async {
      final before = await File(photo).lastModified();
      final dater = Dater(exif: FakeExifBackend(), runner: FakeProcessRunner());

      final events = await dater.fixDates([photo], FixDatesMode.exif).toList();

      final item = events.whereType<ItemEvent>().single;
      expect(item.row.status, PhotoStatus.noTimestamp);
      expect(await File(photo).lastModified(), before);
    },
  );

  test('file direction writes EXIF via exiftool with the file mtime', () async {
    final mtime = DateTime(2019, 1, 2, 3, 4, 5);
    await File(photo).setLastModified(mtime);
    final runner = FakeProcessRunner();
    final dater = Dater(exif: FakeExifBackend(), runner: runner);

    final events = await dater.fixDates([photo], FixDatesMode.file).toList();

    expect(runner.calls, hasLength(1));
    final call = runner.calls.single;
    expect(call.first, 'exiftool');
    expect(call, contains('-DateTimeOriginal=2019:01:02 03:04:05'));

    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.datesFixed);
  });

  test('file direction surfaces a non-zero exiftool exit as error', () async {
    final runner = FakeProcessRunner(result: const ProcResult(1, '', 'boom'));
    final dater = Dater(exif: FakeExifBackend(), runner: runner);

    final events = await dater.fixDates([photo], FixDatesMode.file).toList();

    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.error);
    expect(item.row.note, contains('boom'));
  });

  test('file direction surfaces a missing exiftool as error', () async {
    final runner = FakeProcessRunner(throws: true);
    final dater = Dater(exif: FakeExifBackend(), runner: runner);

    final events = await dater.fixDates([photo], FixDatesMode.file).toList();

    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.error);
  });

  test(
    'dry run changes no mtime and runs no destructive exiftool call',
    () async {
      final before = await File(photo).lastModified();
      final runner = FakeProcessRunner();
      final dater = Dater(
        exif: FakeExifBackend(captureNaive: DateTime(2000, 1, 1, 0, 0, 0)),
        runner: runner,
      );

      final exifEvents = await dater
          .fixDates([photo], FixDatesMode.exif, dryRun: true)
          .toList();
      expect(await File(photo).lastModified(), before);
      expect(
        exifEvents.whereType<ItemEvent>().single.row.status,
        PhotoStatus.dryRun,
      );

      final fileEvents = await dater
          .fixDates([photo], FixDatesMode.file, dryRun: true)
          .toList();
      expect(runner.calls, isEmpty);
      expect(
        fileEvents.whereType<ItemEvent>().single.row.status,
        PhotoStatus.dryRun,
      );
    },
  );

  test('exif direction warns when SetFile fails on macOS', () async {
    final runner = FakeProcessRunner(result: const ProcResult(1, '', 'nope'));
    final dater = Dater(
      exif: FakeExifBackend(captureNaive: DateTime(2021, 7, 4, 13, 37, 5)),
      runner: runner,
      operatingSystem: 'macos',
    );

    final events = await dater.fixDates([photo], FixDatesMode.exif).toList();

    // SetFile was invoked and its non-zero exit surfaced as a warning log.
    expect(runner.calls.any((c) => c.first == 'SetFile'), isTrue);
    final warn = events.whereType<LogEvent>().single;
    expect(warn.level, LogLevel.warning);
    expect(warn.message, contains('SetFile could not set birthtime'));
    // The mtime fix still succeeded.
    expect(
      events.whereType<ItemEvent>().single.row.status,
      PhotoStatus.datesFixed,
    );
  });

  test('exif direction warns when SetFile is unavailable on macOS', () async {
    final runner = FakeProcessRunner(throws: true);
    final dater = Dater(
      exif: FakeExifBackend(captureNaive: DateTime(2021, 7, 4, 13, 37, 5)),
      runner: runner,
      operatingSystem: 'macos',
    );

    final events = await dater.fixDates([photo], FixDatesMode.exif).toList();

    final warn = events.whereType<LogEvent>().single;
    expect(warn.level, LogLevel.warning);
    expect(warn.message, contains('SetFile unavailable'));
    expect(
      events.whereType<ItemEvent>().single.row.status,
      PhotoStatus.datesFixed,
    );
  });

  test('exif direction skips the birthtime fix on non-macOS', () async {
    final runner = FakeProcessRunner();
    final dater = Dater(
      exif: FakeExifBackend(captureNaive: DateTime(2021, 7, 4, 13, 37, 5)),
      runner: runner,
      operatingSystem: 'linux',
    );

    final events = await dater.fixDates([photo], FixDatesMode.exif).toList();

    // No SetFile call on Linux; the mtime fix still succeeds.
    expect(runner.calls.any((c) => c.first == 'SetFile'), isFalse);
    expect(
      events.whereType<ItemEvent>().single.row.status,
      PhotoStatus.datesFixed,
    );
  });

  test('none mode yields a single empty DoneEvent', () async {
    final dater = Dater(exif: FakeExifBackend(), runner: FakeProcessRunner());
    final events = await dater.fixDates([photo], FixDatesMode.none).toList();

    expect(events.whereType<ItemEvent>(), isEmpty);
    final done = events.whereType<DoneEvent>().single;
    expect(done.summary, isEmpty);
  });
}
