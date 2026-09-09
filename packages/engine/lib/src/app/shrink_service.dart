import 'dart:io';

import 'package:image/image.dart' as img;
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
import '../services/image_quality.dart';
import '../services/people_detector.dart';
import '../services/pruner.dart';
import '../services/raw_pairing.dart';
import 'duplicates_service.dart';

/// Why a file was staged for removal by [ShrinkService].
enum ShrinkReason {
  /// A non-kept member of a visually-similar group.
  duplicate('duplicate'),

  /// A RAW with no JPG/HEIC companion.
  orphanRaw('orphan_raw'),

  /// A non-RAW photo with no RAW companion.
  orphanImage('orphan_image'),

  /// The RAW half of a RAW+photo pair (the photo is kept).
  redundantRaw('redundant_raw'),

  /// The photo half of a RAW+photo pair (the RAW is kept).
  redundantPhoto('redundant_photo'),

  /// Composite quality below the chosen threshold.
  lowQuality('low_quality');

  const ShrinkReason(this.wire);

  /// Stable name emitted in the `note` of each staged item.
  final String wire;
}

/// Shrinks a photo library by staging duplicate, orphan, redundant and
/// low-quality files into one cumulative removal list.
///
/// The headless counterpart to the GUI's Shrink wizard, and it keeps the two
/// rules that make the wizard safe: every stage is **opt-in**, and a file
/// flagged by an earlier stage is never counted again by a later one, so the
/// first reason wins and the totals never double-count. Nothing is removed
/// while [ShrinkOptions.dryRun] is set, which is the default.
class ShrinkService {
  /// Creates a service that hashes through [runner] and removes through
  /// [trash]. [detector] and [embedder] follow [DuplicatesService]'s defaults.
  // ignore_for_file: prefer_initializing_formals
  ShrinkService({
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

  final ProcessRunner _runner;
  final Trash _trash;
  final PeopleDetector _detector;
  final ImageEmbedder _embedder;
  final String _tmpDir;

  /// Runs the opted-in [ShrinkOptions.stages] over [roots] and reports (or
  /// removes) the cumulative candidate list.
  ///
  /// Emits one [ItemEvent] per staged file, its `note` carrying the
  /// [ShrinkReason] wire name, plus a [LogEvent] per stage with that stage's
  /// contribution. A final [DoneEvent] summarises by status wire-name.
  Stream<EngineEvent> shrink(List<String> roots, ShrinkOptions options) async* {
    if (options.stages.isEmpty) {
      yield const LogEvent(
        'No stages selected; nothing to do.',
        level: LogLevel.warning,
      );
      yield const DoneEvent({});
      return;
    }

    final photos = await _collectPhotos(roots);
    yield LogEvent('Scanned ${photos.length} photo(s).');

    // First reason wins: staged holds the cumulative set in insertion order so
    // a later stage can never re-flag a file an earlier one already claimed.
    final staged = <String, ShrinkReason>{};

    if (options.stages.contains(ShrinkStage.duplicates)) {
      yield* _stageDuplicates(photos, options, staged);
    }
    if (options.stages.contains(ShrinkStage.orphans)) {
      yield* _stageOrphans(photos, staged);
    }
    if (options.stages.contains(ShrinkStage.pairs)) {
      yield* _stagePairs(photos, options, staged);
    }
    if (options.stages.contains(ShrinkStage.lowQuality)) {
      yield* _stageLowQuality(photos, options, staged);
    }

    yield LogEvent('Staged ${staged.length} file(s) for removal.');
    yield* _apply(staged, options);
  }

  /// Groups near-duplicates and stages every non-kept member.
  Stream<EngineEvent> _stageDuplicates(
    List<String> photos,
    ShrinkOptions options,
    Map<String, ShrinkReason> staged,
  ) async* {
    if (photos.length < 2) return;
    final hashed = await _hash(photos, embed: true);
    final smart =
        options.metric == SimilarityMetric.smart &&
        hashed.any((h) => h.embedding.isNotEmpty);
    final groups = groupDuplicates(
      hashed,
      minSimilarity: options.minSimilarity,
      pipeline: options.pipeline,
      metric: smart ? SimilarityMetric.smart : SimilarityMetric.fast,
    );
    var n = 0;
    for (final group in groups) {
      for (final dup in group.duplicates) {
        if (staged.putIfAbsent(dup.path, () => ShrinkReason.duplicate) ==
            ShrinkReason.duplicate) {
          n++;
        }
      }
    }
    yield LogEvent(
      'Duplicates stage: $n file(s) from ${groups.length} group(s).',
    );
  }

  /// Stages RAWs with no photo companion and photos with no RAW.
  Stream<EngineEvent> _stageOrphans(
    List<String> photos,
    Map<String, ShrinkReason> staged,
  ) async* {
    final pairing = classifyPairing(photos);
    var n = 0;
    for (final f in pairing.files) {
      final reason = switch (f.kind) {
        PairKind.orphanRaw => ShrinkReason.orphanRaw,
        PairKind.photoWithoutRaw => ShrinkReason.orphanImage,
        _ => null,
      };
      if (reason == null) continue;
      if (staged.putIfAbsent(f.path, () => reason) == reason) n++;
    }
    yield LogEvent('Orphans stage: $n file(s).');
  }

  /// Stages one half of every RAW+photo pair, per [ShrinkOptions.pairDropSide].
  Stream<EngineEvent> _stagePairs(
    List<String> photos,
    ShrinkOptions options,
    Map<String, ShrinkReason> staged,
  ) async* {
    final drop = options.pairDropSide == PairDropSide.dropRaw
        ? PairKind.pairedRaw
        : PairKind.photoWithRaw;
    final reason = options.pairDropSide == PairDropSide.dropRaw
        ? ShrinkReason.redundantRaw
        : ShrinkReason.redundantPhoto;
    var n = 0;
    for (final f in classifyPairing(photos).files) {
      if (f.kind != drop) continue;
      if (staged.putIfAbsent(f.path, () => reason) == reason) n++;
    }
    yield LogEvent('Pairs stage: $n file(s).');
  }

  /// Stages every photo whose composite quality is below the threshold.
  ///
  /// Only files not already staged are decoded, so a big duplicate stage keeps
  /// this one cheap.
  Stream<EngineEvent> _stageLowQuality(
    List<String> photos,
    ShrinkOptions options,
    Map<String, ShrinkReason> staged,
  ) async* {
    var n = 0;
    var done = 0;
    final pending = [
      for (final path in photos)
        if (!staged.containsKey(path)) path,
    ];
    for (final path in pending) {
      final quality = await _score(path);
      if (quality != null && quality.composite < options.qualityThreshold) {
        staged[path] = ShrinkReason.lowQuality;
        n++;
      }
      done++;
      yield ProgressEvent(done: done, total: pending.length);
    }
    yield LogEvent('Low-quality stage: $n file(s).');
  }

  /// Reports or removes the cumulative [staged] set.
  Stream<EngineEvent> _apply(
    Map<String, ShrinkReason> staged,
    ShrinkOptions options,
  ) async* {
    final summary = <String, int>{};
    if (options.dryRun) {
      for (final MapEntry(key: path, value: reason) in staged.entries) {
        yield ItemEvent(
          PhotoRow(path: path, status: PhotoStatus.dryRun, note: reason.wire),
        );
        summary[PhotoStatus.dryRun.wire] =
            (summary[PhotoStatus.dryRun.wire] ?? 0) + 1;
      }
      yield DoneEvent(summary);
      return;
    }

    await for (final e in Pruner(
      trash: _trash,
    ).trashPaths(staged.keys.toList(), delete: options.delete)) {
      switch (e) {
        // trashPaths ends with its own DoneEvent; this method emits the one
        // that covers the whole run, so fold its counts instead of forwarding.
        case DoneEvent():
          break;
        case ItemEvent(:final row):
          yield ItemEvent(row.copyWith(note: staged[row.path]?.wire));
          summary[row.status.wire] = (summary[row.status.wire] ?? 0) + 1;
        case _:
          yield e;
      }
    }
    yield DoneEvent(summary);
  }

  /// Perceptually hashes [paths] in exiftool-batched chunks.
  Future<List<HashedFile>> _hash(
    List<String> paths, {
    required bool embed,
  }) async {
    final out = <HashedFile>[];
    for (var i = 0; i < paths.length; i += DuplicatesService.chunkSize) {
      final end = (i + DuplicatesService.chunkSize).clamp(0, paths.length);
      out.addAll(
        await hashFilesBatch(
          paths.sublist(i, end),
          runner: _runner,
          tmpDir: _tmpDir,
          detector: _detector,
          embedder: embed ? _embedder : const NoopImageEmbedder(),
        ),
      );
    }
    return out;
  }

  /// Composite quality for [path], or null when it cannot be decoded.
  Future<ImageQuality?> _score(String path) async {
    try {
      final decoded = img.decodeImage(await File(path).readAsBytes());
      return decoded == null ? null : qualityScore(decoded);
    } on Object {
      return null;
    }
  }

  /// Every taggable photo under [roots], recursively, in walk order.
  Future<List<String>> _collectPhotos(List<String> roots) async {
    final photos = <String>[];
    for (final root in roots) {
      if (File(root).existsSync() && PhotoFormats.isPhoto(root)) {
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
}
