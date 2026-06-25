import 'dart:io';

import '../data/exif/exif_backend.dart';
import '../data/ports/process_runner.dart';
import '../domain/engine_event.dart';
import '../domain/options.dart';
import '../domain/photo_row.dart';
import '../domain/status.dart';

/// Fixes capture/file dates in either direction, mirroring the original tool.
///
/// In the [FixDatesMode.exif] direction the file's modified time (and, on macOS,
/// its birthtime via `SetFile -d`) is set from the photo's EXIF
/// `DateTimeOriginal`. In the [FixDatesMode.file] direction EXIF
/// `DateTimeOriginal`/`CreateDate` are written from the file's modified time via
/// exiftool, which works for every supported format.
class Dater {
  /// Creates a dater backed by [exif] (for reading capture time) and [runner]
  /// (for invoking `SetFile` and `exiftool`).
  ///
  /// [operatingSystem] defaults to [Platform.operatingSystem] and only gates the
  /// macOS-only birthtime fix; overriding it lets that branch be tested on any
  /// host.
  Dater({
    required ExifBackend exif,
    required ProcessRunner runner,
    String? operatingSystem,
  }) : _os = operatingSystem,
       // ignore: prefer_initializing_formals
       _exif = exif,
       // ignore: prefer_initializing_formals
       _runner = runner;

  final ExifBackend _exif;
  final ProcessRunner _runner;
  final String? _os;

  /// Fixes dates for [files] in the given [mode].
  ///
  /// Emits a [ProgressEvent] after each file, one [ItemEvent] per file (status
  /// [PhotoStatus.datesFixed], [PhotoStatus.noTimestamp], [PhotoStatus.dryRun],
  /// or [PhotoStatus.error]), and a final [DoneEvent] keyed by
  /// [PhotoStatus.wire]. Per-file failures surface as an error [ItemEvent] and
  /// do not abort the run. [FixDatesMode.none] yields only an empty
  /// [DoneEvent].
  Stream<EngineEvent> fixDates(
    List<String> files,
    FixDatesMode mode, {
    bool dryRun = false,
  }) async* {
    final summary = <String, int>{};
    if (mode == FixDatesMode.none) {
      yield DoneEvent(summary);
      return;
    }

    var done = 0;
    for (final path in files) {
      try {
        yield* switch (mode) {
          FixDatesMode.exif => _fromExif(
            path,
            dryRun: dryRun,
            summary: summary,
          ),
          FixDatesMode.file => _fromFile(
            path,
            dryRun: dryRun,
            summary: summary,
          ),
          FixDatesMode.none => const Stream<EngineEvent>.empty(),
        };
      } on Object catch (e) {
        yield _item(path, PhotoStatus.error, summary, note: '$e');
      }
      done++;
      yield ProgressEvent(done: done, total: files.length);
    }

    yield DoneEvent(summary);
  }

  /// exif direction: set the file's modified time (and macOS birthtime) from
  /// the photo's EXIF capture time.
  Stream<EngineEvent> _fromExif(
    String path, {
    required bool dryRun,
    required Map<String, int> summary,
  }) async* {
    final meta = await _exif.read(path);
    final naive = meta.captureNaive;
    if (naive == null) {
      yield _item(
        path,
        PhotoStatus.noTimestamp,
        summary,
        note: 'no EXIF DateTimeOriginal',
      );
      return;
    }

    // captureNaive is wall-clock; treat it as a local DateTime for the mtime.
    final target = DateTime(
      naive.year,
      naive.month,
      naive.day,
      naive.hour,
      naive.minute,
      naive.second,
    );

    if (dryRun) {
      yield _item(path, PhotoStatus.dryRun, summary);
      return;
    }

    await File(path).setLastModified(target);

    if ((_os ?? Platform.operatingSystem) == 'macos') {
      yield* _setBirthtime(path, target);
    }

    yield _item(path, PhotoStatus.datesFixed, summary);
  }

  /// Attempts to set the macOS birthtime via `SetFile -d`; a missing or failing
  /// `SetFile` is reported as a warning [LogEvent] but is otherwise non-fatal.
  Stream<EngineEvent> _setBirthtime(String path, DateTime target) async* {
    final stamp = _setFileStamp(target);
    try {
      final result = await _runner.run('SetFile', ['-d', stamp, path]);
      if (!result.ok) {
        yield LogEvent(
          'SetFile could not set birthtime for $path: ${result.stderr.trim()}',
          level: LogLevel.warning,
        );
      }
    } on Object catch (e) {
      yield LogEvent(
        'SetFile unavailable; left birthtime unchanged ($e)',
        level: LogLevel.warning,
      );
    }
  }

  /// file direction: write EXIF `DateTimeOriginal`/`CreateDate` from the file's
  /// modified time via exiftool.
  Stream<EngineEvent> _fromFile(
    String path, {
    required bool dryRun,
    required Map<String, int> summary,
  }) async* {
    final modified = await File(path).lastModified();
    final stamp = _exifStamp(modified);

    if (dryRun) {
      yield _item(path, PhotoStatus.dryRun, summary);
      return;
    }

    final ProcResult result;
    try {
      result = await _runner.run('exiftool', [
        '-overwrite_original',
        '-DateTimeOriginal=$stamp',
        '-CreateDate=$stamp',
        path,
      ]);
    } on Object catch (e) {
      yield _item(
        path,
        PhotoStatus.error,
        summary,
        note: 'exiftool unavailable: $e',
      );
      return;
    }

    if (!result.ok) {
      yield _item(
        path,
        PhotoStatus.error,
        summary,
        note: 'exiftool exited ${result.exitCode}: ${result.stderr.trim()}',
      );
      return;
    }

    yield _item(path, PhotoStatus.datesFixed, summary);
  }

  /// Builds an [ItemEvent], incrementing the [summary] count for [status].
  ItemEvent _item(
    String path,
    PhotoStatus status,
    Map<String, int> summary, {
    String? note,
  }) {
    summary[status.wire] = (summary[status.wire] ?? 0) + 1;
    return ItemEvent(PhotoRow(path: path, status: status, note: note));
  }

  /// Formats [t] as exiftool's `YYYY:MM:DD HH:MM:SS`.
  String _exifStamp(DateTime t) =>
      '${_pad(t.year, 4)}:${_pad(t.month)}:${_pad(t.day)} '
      '${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}';

  /// Formats [t] as `SetFile`'s `MM/DD/YYYY HH:MM:SS`.
  String _setFileStamp(DateTime t) =>
      '${_pad(t.month)}/${_pad(t.day)}/${_pad(t.year, 4)} '
      '${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}';

  String _pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
}
