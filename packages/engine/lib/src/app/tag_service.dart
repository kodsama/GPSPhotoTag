import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/exif/backend_registry.dart';
import '../data/exif/exif_backend.dart';
import '../data/filename_date.dart';
import '../domain/engine_event.dart';
import '../domain/location_result.dart';
import '../domain/options.dart';
import '../domain/photo_row.dart';
import '../domain/status.dart';
import '../domain/timed_point.dart';
import '../services/locator.dart';

/// Orchestrates the `tag` operation: for each photo, read its time, resolve a
/// coordinate from the sources, and write GPS via the appropriate backend.
///
/// Emits a [Stream] of [EngineEvent]s — one [ItemEvent] per photo, periodic
/// [ProgressEvent]s, and a final [DoneEvent] with the status tally. The CLI
/// serialises these to JSON lines; the GUI routes them to controllers. The same
/// method runs unchanged inside a worker isolate.
class TagService {
  /// Builds a tag service over [registry].
  // ignore: prefer_initializing_formals
  TagService({required BackendRegistry registry}) : _registry = registry;

  final BackendRegistry _registry;

  /// Tags [photos] using [gpx] (preferred) then [google] points.
  Stream<EngineEvent> tag({
    required List<String> photos,
    List<TimedPoint> gpx = const [],
    List<TimedPoint> google = const [],
    TagOptions options = const TagOptions(),
  }) async* {
    final guard = _validateDestination(options);
    if (guard != null) {
      yield guard;
      return;
    }

    final locator = Locator(gpx: gpx, google: google);
    final summary = <String, int>{};
    final total = photos.length;
    var done = 0;

    for (final path in photos) {
      final row = await _tagOne(path, locator, options);
      summary.update(row.status.wire, (n) => n + 1, ifAbsent: () => 1);
      yield ItemEvent(row);
      done++;
      yield ProgressEvent(done: done, total: total);
    }

    yield DoneEvent(summary);
  }

  Future<PhotoRow> _tagOne(
    String path,
    Locator locator,
    TagOptions options,
  ) async {
    try {
      final reader = _registry.readerFor(path);
      if (reader == null) {
        return PhotoRow(
          path: path,
          status: PhotoStatus.error,
          note: 'unsupported format (install exiftool to read this file)',
        );
      }

      final meta = await reader.read(path);
      final captureUtc = _toUtc(meta, options.timezone, path);
      if (captureUtc == null) {
        return PhotoRow(path: path, status: PhotoStatus.noTimestamp);
      }

      if (meta.hasGps && !options.replace) {
        return PhotoRow(
          path: path,
          status: PhotoStatus.alreadyTagged,
          timestamp: captureUtc,
          note: 'use replace to overwrite',
        );
      }

      final fix = locator.locate(captureUtc, options.maxTimeDiff);
      if (fix == null) {
        return PhotoRow(
          path: path,
          status: PhotoStatus.noGps,
          timestamp: captureUtc,
        );
      }

      final writer = _registry.writerFor(path);
      if (writer == null) {
        return PhotoRow(
          path: path,
          status: PhotoStatus.error,
          timestamp: captureUtc,
          note: 'no write strategy (install exiftool, or use sidecar raw mode)',
        );
      }

      final status = fix.method == GpsMethod.exact
          ? PhotoStatus.tagged
          : PhotoStatus.interpolated;

      if (options.dryRun) {
        return PhotoRow(
          path: path,
          status: PhotoStatus.dryRun,
          timestamp: captureUtc,
          location: fix,
        );
      }

      final target = await _resolveTarget(path, options);
      await writer.writeGps(
        target,
        latitude: fix.latitude,
        longitude: fix.longitude,
      );

      return PhotoRow(
        path: target,
        status: status,
        timestamp: captureUtc,
        location: fix,
      );
    } on Object catch (e) {
      return PhotoRow(path: path, status: PhotoStatus.error, note: '$e');
    }
  }

  /// Copies [path] into the output directory when one is set and returns the
  /// path the backend should write to; otherwise returns [path] for in-place.
  Future<String> _resolveTarget(String path, TagOptions options) async {
    final outDir = options.outDir;
    if (outDir == null) return path;
    await Directory(outDir).create(recursive: true);
    final target = p.join(outDir, p.basename(path));
    await File(path).copy(target);
    return target;
  }

  /// Converts a photo's naive capture time to UTC using its EXIF offset, or the
  /// host's local timezone as a fallback. (Full IANA [tz] support is a later
  /// enhancement; when [tz] is set but no offset is present we still fall back
  /// to local, which matches the original tool's default behaviour.)
  ///
  /// When EXIF carries no capture time, falls back to parsing a naive timestamp
  /// from the filename ([timestampFromFilename]) so phone shots without EXIF
  /// (e.g. `PXL_20260622_104338000.jpg`) still match a track.
  DateTime? _toUtc(PhotoMeta meta, String? tz, String path) {
    final n = meta.captureNaive ?? timestampFromFilename(path);
    if (n == null) return null;
    final offset = meta.offset;
    if (offset != null) {
      return DateTime.utc(
        n.year,
        n.month,
        n.day,
        n.hour,
        n.minute,
        n.second,
      ).subtract(offset);
    }
    return DateTime(n.year, n.month, n.day, n.hour, n.minute, n.second).toUtc();
  }

  /// Enforces the `--out` / `--overwrite` / `--replace` matrix; returns an
  /// [ErrorEvent] to emit when the combination is invalid, else null.
  ErrorEvent? _validateDestination(TagOptions o) {
    if (o.dryRun) return null;
    if (o.outDir != null && o.overwrite) {
      return const ErrorEvent(
        'pick one destination: pass either out or overwrite, not both',
        code: 'bad_input',
      );
    }
    if (o.outDir == null && !o.overwrite) {
      return const ErrorEvent(
        'refusing to write: pass out <dir> or overwrite',
        code: 'bad_input',
      );
    }
    return null;
  }
}
