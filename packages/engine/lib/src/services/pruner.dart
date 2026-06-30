import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/photo_formats.dart';
import '../data/ports/trash.dart';
import '../domain/engine_event.dart';
import '../domain/options.dart';
import '../domain/photo_row.dart';
import '../domain/status.dart';

/// Finds and removes orphan RAW files — RAWs with no same-named JPG/HEIC
/// companion anywhere in the scanned tree.
///
/// A RAW is an orphan when no `.jpg/.jpeg/.heic/.heif` file shares its basename
/// (without extension), matched tree-wide rather than per-folder. Each orphan's
/// `<full-raw-name>.xmp` sidecar (e.g. `DSCF1.RAF.xmp`) is removed alongside it.
class Pruner {
  /// Creates a pruner that sends orphans to [trash] (unless deleting/dry-run).
  // ignore: prefer_initializing_formals
  Pruner({required Trash trash}) : _trash = trash;

  final Trash _trash;

  /// Scans [roots] recursively and removes orphan RAW files per [options].
  ///
  /// Emits a [LogEvent] and an [ItemEvent] per action, and a final [DoneEvent]
  /// whose summary is keyed by [PhotoStatus.wire]. Per-file failures surface as
  /// an [ItemEvent] with [PhotoStatus.error] and do not abort the run.
  Stream<EngineEvent> prune(List<String> roots, PruneOptions options) async* {
    final companions = <String>{};
    final raws = <File>[];
    await _scan(roots, companions, raws);

    final orphans = raws
        .where((f) => !companions.contains(PhotoFormats.baseKeyOf(f.path)))
        .toList(growable: false);

    yield LogEvent('Found ${orphans.length} orphan RAW file(s).');

    final summary = <String, int>{};
    var done = 0;
    for (final orphan in orphans) {
      yield* _handleOrphan(orphan, options, summary);
      done++;
      yield ProgressEvent(done: done, total: orphans.length);
    }

    yield DoneEvent(summary);
  }

  /// Walks every root, recording companion basenames and collecting RAW files.
  Future<void> _scan(
    List<String> roots,
    Set<String> companions,
    List<File> raws,
  ) async {
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final ext = _ext(entity.path);
        if (PhotoFormats.companion.contains(ext)) {
          companions.add(PhotoFormats.baseKeyOf(entity.path));
        } else if (PhotoFormats.raw.contains(ext)) {
          raws.add(entity);
        }
      }
    }
  }

  /// Removes a single [orphan] (and any sidecar), emitting its events.
  Stream<EngineEvent> _handleOrphan(
    File orphan,
    PruneOptions options,
    Map<String, int> summary,
  ) async* {
    final status = _statusFor(options);
    final sidecar = File('${orphan.path}.xmp');
    final hasSidecar = sidecar.existsSync();
    try {
      await _remove(orphan, options);
      if (hasSidecar) await _remove(sidecar, options);

      final verb = _verbFor(options);
      yield LogEvent(
        '$verb ${orphan.path}'
        '${hasSidecar ? ' (+ sidecar ${sidecar.path})' : ''}',
      );
      yield ItemEvent(PhotoRow(path: orphan.path, status: status));
      _bump(summary, status);
    } on Object catch (e) {
      yield LogEvent(
        'Failed to prune ${orphan.path}: $e',
        level: LogLevel.error,
      );
      yield ItemEvent(
        PhotoRow(path: orphan.path, status: PhotoStatus.error, note: '$e'),
      );
      _bump(summary, PhotoStatus.error);
    }
  }

  /// Moves exactly the given [paths] (plus any `<path>.xmp` sidecar) to the
  /// Trash, or permanently deletes them when [delete] is true.
  ///
  /// Unlike [prune], this trashes the explicit list the caller chose — it never
  /// re-scans or re-classifies. It backs the GUI's "preview → select → confirm"
  /// flow, where the user has already reviewed and selected the candidates, so
  /// nothing is removed blind. Emits an [ItemEvent] per file
  /// ([PhotoStatus.prunedTrashed] / [PhotoStatus.prunedDeleted]) and a final
  /// [DoneEvent]. A per-file failure surfaces as an error [ItemEvent] and does
  /// not abort the run.
  Stream<EngineEvent> trashPaths(
    List<String> paths, {
    bool delete = false,
  }) async* {
    final status = delete
        ? PhotoStatus.prunedDeleted
        : PhotoStatus.prunedTrashed;
    final verb = delete ? 'Deleted' : 'Trashed';
    final summary = <String, int>{};
    var done = 0;
    for (final path in paths) {
      final sidecar = File('$path.xmp');
      final hasSidecar = sidecar.existsSync();
      try {
        await _removePath(path, delete);
        if (hasSidecar) await _removePath(sidecar.path, delete);
        yield LogEvent(
          '$verb $path${hasSidecar ? ' (+ sidecar ${sidecar.path})' : ''}',
        );
        yield ItemEvent(PhotoRow(path: path, status: status));
        _bump(summary, status);
      } on Object catch (e) {
        yield LogEvent('Failed to remove $path: $e', level: LogLevel.error);
        yield ItemEvent(
          PhotoRow(path: path, status: PhotoStatus.error, note: '$e'),
        );
        _bump(summary, PhotoStatus.error);
      }
      done++;
      yield ProgressEvent(done: done, total: paths.length);
    }
    yield DoneEvent(summary);
  }

  /// Trashes or deletes [path] using the injected [Trash].
  Future<void> _removePath(String path, bool delete) async {
    if (delete) {
      await File(path).delete();
    } else {
      await _trash.toTrash(path);
    }
  }

  /// Performs the destructive action for [file] (or nothing on a dry run).
  Future<void> _remove(File file, PruneOptions options) async {
    if (options.dryRun) return;
    if (options.delete) {
      await file.delete();
    } else {
      await _trash.toTrash(file.path);
    }
  }

  PhotoStatus _statusFor(PruneOptions options) => options.dryRun
      ? PhotoStatus.dryRun
      : options.delete
      ? PhotoStatus.prunedDeleted
      : PhotoStatus.prunedTrashed;

  String _verbFor(PruneOptions options) => options.dryRun
      ? 'Would prune'
      : options.delete
      ? 'Deleted'
      : 'Trashed';

  void _bump(Map<String, int> summary, PhotoStatus status) =>
      summary[status.wire] = (summary[status.wire] ?? 0) + 1;

  /// Lowercased extension without the leading dot (empty if none).
  String _ext(String path) {
    final ext = p.extension(path);
    return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
  }
}
