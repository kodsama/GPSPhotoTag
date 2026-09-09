import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/src/app/duplicates_service.dart';
import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/data/ports/trash.dart';
import 'package:stunda_engine/src/domain/engine_event.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:stunda_engine/src/domain/status.dart';
import 'package:stunda_engine/src/services/duplicate_finder.dart';
import 'package:stunda_engine/src/services/embedding/image_embedder.dart';
import 'package:test/test.dart';

/// Records paths instead of touching the real OS Trash.
class _FakeTrash implements Trash {
  final List<String> trashed = [];

  @override
  Future<void> toTrash(String path) async => trashed.add(path);
}

/// exiftool is never present in the test environment, so every invocation
/// fails and `hashFilesBatch` falls back to decoding the source bytes — which
/// is exactly the no-exiftool path a plain `dart run` takes.
class _FailingRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async =>
      const ProcResult(1, '', 'exiftool not found');
}

/// An embedder that returns a fixed vector, so the Smart metric has something
/// to work with without an ONNX model on disk.
class _ConstantEmbedder implements ImageEmbedder {
  @override
  bool get isAvailable => true;

  @override
  Future<List<double>?> embedDecoded(img.Image image) async => const [1, 0, 0];
}

/// Writes a deterministic-noise PNG so two files can be byte-identical (a
/// duplicate) or clearly different.
void _png(String path, int seed) {
  final image = img.Image(width: 48, height: 48);
  var x = seed * 2654435761 & 0xffffffff;
  for (final pixel in image) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    pixel.setRgb((x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
  }
  File(path).writeAsBytesSync(img.encodePng(image));
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dupsvc_'));
  tearDown(() => root.deleteSync(recursive: true));

  DuplicatesService service(
    Trash trash, {
    ImageEmbedder embedder = const NoopImageEmbedder(),
  }) => DuplicatesService(
    runner: _FailingRunner(),
    trash: trash,
    tmpDir: p.join(root.path, 'tmp'),
    embedder: embedder,
  );

  test(
    'reports a duplicate pair without removing anything by default',
    () async {
      _png(p.join(root.path, 'a.png'), 1);
      File(p.join(root.path, 'copy.png'))
          .writeAsBytesSync(File(p.join(root.path, 'a.png')).readAsBytesSync());
      _png(p.join(root.path, 'other.png'), 99);

      final trash = _FakeTrash();
      final events = await service(trash)
          .findDuplicates([root.path], const DuplicatesOptions())
          .toList();

      final rows = events.whereType<ItemEvent>().map((e) => e.row).toList();
      expect(rows.where((r) => r.status == PhotoStatus.kept), hasLength(1));
      expect(rows.where((r) => r.status == PhotoStatus.dryRun), hasLength(1));
      // The distinct photo is in no group, so it is never reported.
      expect(rows.map((r) => p.basename(r.path)), isNot(contains('other.png')));
      expect(trash.trashed, isEmpty, reason: 'dry run must not remove files');

      final done = events.whereType<DoneEvent>().single;
      expect(done.summary, {'kept': 1, 'dry_run': 1});
    },
  );

  test('trashes the non-kept copy once the dry run is turned off', () async {
    _png(p.join(root.path, 'a.png'), 5);
    File(p.join(root.path, 'copy.png'))
        .writeAsBytesSync(File(p.join(root.path, 'a.png')).readAsBytesSync());

    final trash = _FakeTrash();
    final events = await service(trash)
        .findDuplicates([root.path], const DuplicatesOptions(dryRun: false))
        .toList();

    expect(trash.trashed, hasLength(1));
    final kept = events
        .whereType<ItemEvent>()
        .map((e) => e.row)
        .firstWhere((r) => r.status == PhotoStatus.kept);
    // The survivor is never the file that was trashed.
    expect(trash.trashed, isNot(contains(kept.path)));
    expect(events.whereType<DoneEvent>().single.summary, {
      'kept': 1,
      'pruned_trashed': 1,
    });
  });

  test('deletes instead of trashing when asked', () async {
    _png(p.join(root.path, 'a.png'), 7);
    final copy = p.join(root.path, 'copy.png');
    File(copy)
        .writeAsBytesSync(File(p.join(root.path, 'a.png')).readAsBytesSync());

    final trash = _FakeTrash();
    final events = await service(trash).findDuplicates([
      root.path,
    ], const DuplicatesOptions(dryRun: false, delete: true)).toList();

    expect(trash.trashed, isEmpty, reason: 'delete bypasses the Trash');
    expect(events.whereType<DoneEvent>().single.summary, {
      'kept': 1,
      'pruned_deleted': 1,
    });
    // Exactly one of the pair survives on disk.
    expect(Directory(root.path).listSync().whereType<File>(), hasLength(1));
  });

  test('a library with fewer than two photos does no work', () async {
    _png(p.join(root.path, 'only.png'), 3);

    final events = await service(_FakeTrash())
        .findDuplicates([root.path], const DuplicatesOptions())
        .toList();

    expect(events.whereType<ItemEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>().single.summary, isEmpty);
    expect(
      events.whereType<LogEvent>().map((e) => e.message),
      contains(contains('at least two photos')),
    );
  });

  test('Smart falls back to Fast and warns when no embedder is available', () async {
    _png(p.join(root.path, 'a.png'), 11);
    File(p.join(root.path, 'copy.png'))
        .writeAsBytesSync(File(p.join(root.path, 'a.png')).readAsBytesSync());

    final events = await service(_FakeTrash()).findDuplicates([
      root.path,
    ], const DuplicatesOptions(metric: SimilarityMetric.smart)).toList();

    expect(
      events
          .whereType<LogEvent>()
          .where((e) => e.level == LogLevel.warning)
          .map((e) => e.message),
      contains(contains('No embedding model')),
    );
    // Falling back still finds the pair rather than silently returning nothing.
    expect(events.whereType<DoneEvent>().single.summary['dry_run'], 1);
  });

  test('Smart runs on the embeddings when an embedder is available', () async {
    _png(p.join(root.path, 'a.png'), 13);
    _png(p.join(root.path, 'b.png'), 21);

    final events = await service(_FakeTrash(), embedder: _ConstantEmbedder())
        .findDuplicates([
          root.path,
        ], const DuplicatesOptions(metric: SimilarityMetric.smart))
        .toList();

    // No fallback warning: the embedder supplied vectors.
    expect(
      events.whereType<LogEvent>().where((e) => e.level == LogLevel.warning),
      isEmpty,
    );
    // Identical embeddings make the two visually-distinct photos one group.
    expect(events.whereType<DoneEvent>().single.summary['dry_run'], 1);
  });

  test('accepts a single file as a root and skips a missing one', () async {
    final a = p.join(root.path, 'a.png');
    _png(a, 17);
    final copy = p.join(root.path, 'copy.png');
    File(copy).writeAsBytesSync(File(a).readAsBytesSync());

    final events = await service(_FakeTrash()).findDuplicates([
      a,
      copy,
      p.join(root.path, 'nope'),
    ], const DuplicatesOptions()).toList();

    expect(events.whereType<DoneEvent>().single.summary, {
      'kept': 1,
      'dry_run': 1,
    });
  });
}
