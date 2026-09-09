import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/photo_formats.dart';
import '../data/ports/process_runner.dart';
import '../data/ports/trash.dart';
import '../domain/engine_event.dart';
import '../domain/options.dart';
import '../domain/photo_row.dart';
import '../domain/status.dart';
import '../services/duplicate_finder.dart';
import '../services/embedding/image_embedder.dart';
import '../services/people_detector.dart';
import '../services/pruner.dart';

/// Finds visually-similar photos across a library and, on request, trashes
/// every non-kept member of each group.
///
/// This is the headless counterpart to the GUI's Find-duplicates screen: the
/// app fans hashing out across worker isolates, whereas this walks the roots and
/// hashes in-process so the CLI and the MCP server get the same result without
/// Flutter. The grouping, keep-rule cascade and RAW-companion exclusion are the
/// shared pure functions in [groupDuplicates], so both surfaces agree.
class DuplicatesService {
  /// Creates a service that hashes through [runner] and trashes through
  /// [trash].
  ///
  /// [detector] and [embedder] default to the no-op implementations, which is
  /// what a plain `dart run` gets: the keep-rule people tier falls back to
  /// metadata only, and the Smart metric degrades to Fast. Callers that have
  /// resolved an ONNX bundle pass real ones.
  // ignore_for_file: prefer_initializing_formals
  DuplicatesService({
    required ProcessRunner runner,
    required Trash trash,
    String? tmpDir,
    PeopleDetector detector = const NoopPeopleDetector(),
    ImageEmbedder embedder = const NoopImageEmbedder(),
  }) : _runner = runner,
       _trash = trash,
       _detector = detector,
       _embedder = embedder,
       _tmpDir =
           tmpDir ?? p.join(Directory.systemTemp.path, 'stunda_hash_cache');

  /// How many paths go into one [hashFilesBatch] call. One set of exiftool
  /// spawns covers a whole chunk, and the chunk is capped so the argument list
  /// stays well inside OS limits. Mirrors the app worker's chunking.
  static const int chunkSize = 150;

  final ProcessRunner _runner;
  final Trash _trash;
  final PeopleDetector _detector;
  final ImageEmbedder _embedder;
  final String _tmpDir;

  /// Scans [roots] recursively, groups near-duplicates per [options], and
  /// trashes the non-kept members unless [DuplicatesOptions.dryRun].
  ///
  /// Emits one [ItemEvent] per group member: the survivor as
  /// [PhotoStatus.kept], each duplicate as
  /// [PhotoStatus.dryRun] on a preview or [PhotoStatus.prunedTrashed] /
  /// [PhotoStatus.prunedDeleted] once removed. Photos in no group are not
  /// reported. A final [DoneEvent] summarises by status wire-name.
  Stream<EngineEvent> findDuplicates(
    List<String> roots,
    DuplicatesOptions options,
  ) async* {
    final photos = await _collectPhotos(roots);
    if (photos.length < 2) {
      yield const LogEvent('Need at least two photos to compare.');
      yield const DoneEvent({});
      return;
    }
    yield LogEvent('Hashing ${photos.length} photo(s).');

    final hashed = <HashedFile>[];
    var done = 0;
    for (var i = 0; i < photos.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, photos.length);
      hashed.addAll(
        await hashFilesBatch(
          photos.sublist(i, end),
          runner: _runner,
          tmpDir: _tmpDir,
          detector: _detector,
          embedder: _embedder,
        ),
      );
      done = end;
      yield ProgressEvent(done: done, total: photos.length);
    }

    // A Smart run needs embeddings; without a model every vector is empty and
    // the Smart metric would match nothing, so fall back to Fast rather than
    // silently returning no groups.
    final smart =
        options.metric == SimilarityMetric.smart &&
        hashed.any((h) => h.embedding.isNotEmpty);
    if (options.metric == SimilarityMetric.smart && !smart) {
      yield const LogEvent(
        'No embedding model available; using the Fast metric.',
        level: LogLevel.warning,
      );
    }

    final groups = groupDuplicates(
      hashed,
      minSimilarity: options.minSimilarity,
      pipeline: options.pipeline,
      metric: smart ? SimilarityMetric.smart : SimilarityMetric.fast,
    );
    yield LogEvent('Found ${groups.length} duplicate group(s).');

    yield* _report(groups, options);
  }

  /// Emits the per-member rows for [groups] and removes the duplicates.
  Stream<EngineEvent> _report(
    List<DuplicateGroup> groups,
    DuplicatesOptions options,
  ) async* {
    final summary = <String, int>{};
    final pruner = Pruner(trash: _trash);
    for (final group in groups) {
      yield ItemEvent(
        PhotoRow(
          path: group.best.path,
          status: PhotoStatus.kept,
          note: 'best of ${group.size}',
        ),
      );
      _bump(summary, PhotoStatus.kept);

      if (options.dryRun) {
        for (final dup in group.duplicates) {
          yield ItemEvent(
            PhotoRow(
              path: dup.path,
              status: PhotoStatus.dryRun,
              note: 'duplicate of ${group.best.path}',
            ),
          );
          _bump(summary, PhotoStatus.dryRun);
        }
        continue;
      }

      await for (final e in pruner.trashPaths([
        for (final d in group.duplicates) d.path,
      ], delete: options.delete)) {
        switch (e) {
          // trashPaths closes every call with its own DoneEvent and counts
          // progress per group; this method emits one DoneEvent and one
          // progress series for the whole run, so drop both and fold the counts.
          case DoneEvent() || ProgressEvent():
            break;
          case ItemEvent(:final row):
            yield ItemEvent(
              row.copyWith(note: 'duplicate of ${group.best.path}'),
            );
            _bump(summary, row.status);
          case _:
            yield e;
        }
      }
    }
    yield DoneEvent(summary);
  }

  /// Every taggable photo under [roots], recursively, in walk order.
  Future<List<String>> _collectPhotos(List<String> roots) async {
    final photos = <String>[];
    for (final root in roots) {
      final file = File(root);
      if (file.existsSync() && PhotoFormats.isPhoto(root)) {
        photos.add(root);
        continue;
      }
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && PhotoFormats.isPhoto(entity.path)) {
          photos.add(entity.path);
        }
      }
    }
    return photos;
  }

  void _bump(Map<String, int> summary, PhotoStatus status) =>
      summary[status.wire] = (summary[status.wire] ?? 0) + 1;
}
