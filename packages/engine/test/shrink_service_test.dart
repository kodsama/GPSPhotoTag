import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/src/app/shrink_service.dart';
import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/data/ports/trash.dart';
import 'package:stunda_engine/src/domain/engine_event.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:stunda_engine/src/domain/status.dart';
import 'package:stunda_engine/src/services/duplicate_finder.dart';
import 'package:test/test.dart';

/// Records paths instead of touching the real OS Trash.
class _FakeTrash implements Trash {
  final List<String> trashed = [];

  @override
  Future<void> toTrash(String path) async => trashed.add(path);
}

/// No exiftool in the test environment, so hashing decodes source bytes.
class _FailingRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async =>
      const ProcResult(1, '', 'exiftool not found');
}

/// A deterministic-noise JPEG: high-entropy, so it scores well on quality.
void _noisy(String path, int seed) {
  final image = img.Image(width: 48, height: 48);
  var x = seed * 2654435761 & 0xffffffff;
  for (final pixel in image) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    pixel.setRgb((x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
  }
  File(path).writeAsBytesSync(img.encodeJpg(image));
}

/// A flat grey JPEG: no sharpness, no contrast, no colour - bottom of the
/// composite-quality scale, so the low-quality stage must catch it.
void _flat(String path) {
  final image = img.Image(width: 48, height: 48);
  for (final pixel in image) {
    pixel.setRgb(128, 128, 128);
  }
  File(path).writeAsBytesSync(img.encodeJpg(image));
}

/// The paths a run staged, keyed by basename with its reason.
Map<String, String?> _staged(List<EngineEvent> events) => {
  for (final e in events.whereType<ItemEvent>())
    p.basename(e.row.path): e.row.note,
};

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('shrinksvc_'));
  tearDown(() => root.deleteSync(recursive: true));

  ShrinkService service(Trash trash) => ShrinkService(
    runner: _FailingRunner(),
    trash: trash,
    tmpDir: p.join(root.path, 'tmp'),
  );

  String at(String name) => p.join(root.path, name);

  test('no stages selected removes nothing and says so', () async {
    _noisy(at('a.jpg'), 1);

    final events = await service(_FakeTrash())
        .shrink([root.path], const ShrinkOptions())
        .toList();

    expect(events.whereType<ItemEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>().single.summary, isEmpty);
    expect(
      events
          .whereType<LogEvent>()
          .where((e) => e.level == LogLevel.warning)
          .map((e) => e.message),
      contains(contains('No stages selected')),
    );
  });

  test('orphans stage flags unpaired RAWs and unpaired photos', () async {
    _noisy(at('solo.jpg'), 2); // photo with no RAW
    File(at('lonely.raf')).writeAsBytesSync([0, 0, 0]); // RAW with no photo
    _noisy(at('pair.jpg'), 3);
    File(at('pair.raf')).writeAsBytesSync([0, 0, 0]); // both halves present

    final events = await service(_FakeTrash())
        .shrink([root.path], const ShrinkOptions(stages: {ShrinkStage.orphans}))
        .toList();

    expect(_staged(events), {
      'solo.jpg': 'orphan_image',
      'lonely.raf': 'orphan_raw',
    });
  });

  test('pairs stage drops the chosen half and leaves the other', () async {
    _noisy(at('pair.jpg'), 4);
    File(at('pair.raf')).writeAsBytesSync([0, 0, 0]);

    final dropRaw = await service(_FakeTrash())
        .shrink([root.path], const ShrinkOptions(stages: {ShrinkStage.pairs}))
        .toList();
    expect(_staged(dropRaw), {'pair.raf': 'redundant_raw'});

    final dropPhoto = await service(_FakeTrash()).shrink(
      [root.path],
      const ShrinkOptions(
        stages: {ShrinkStage.pairs},
        pairDropSide: PairDropSide.dropPhoto,
      ),
    ).toList();
    expect(_staged(dropPhoto), {'pair.jpg': 'redundant_photo'});
  });

  test('low-quality stage flags a flat image but spares a noisy one', () async {
    _noisy(at('sharp.jpg'), 5);
    _flat(at('flat.jpg'));

    final events = await service(_FakeTrash()).shrink([
      root.path,
    ], const ShrinkOptions(stages: {ShrinkStage.lowQuality})).toList();

    expect(_staged(events), {'flat.jpg': 'low_quality'});
  });

  test('an earlier stage owns a file a later stage would also claim', () async {
    // One JPEG duplicated: both copies are also unpaired photos, so the
    // orphans stage would claim them too. The duplicate stage runs first, so
    // the surviving copy stays orphan_image and the other stays duplicate.
    _noisy(at('a.jpg'), 6);
    File(at('copy.jpg')).writeAsBytesSync(File(at('a.jpg')).readAsBytesSync());

    final events = await service(_FakeTrash()).shrink(
      [root.path],
      const ShrinkOptions(
        stages: {ShrinkStage.duplicates, ShrinkStage.orphans},
      ),
    ).toList();

    final staged = _staged(events);
    expect(staged, hasLength(2));
    // Exactly one is claimed as the duplicate; the other falls to orphans.
    expect(staged.values.where((r) => r == 'duplicate'), hasLength(1));
    expect(staged.values.where((r) => r == 'orphan_image'), hasLength(1));
  });

  test('apply trashes the staged set and reports pruned_trashed', () async {
    File(at('lonely.raf')).writeAsBytesSync([0, 0, 0]);

    final trash = _FakeTrash();
    final events = await service(trash).shrink(
      [root.path],
      const ShrinkOptions(stages: {ShrinkStage.orphans}, dryRun: false),
    ).toList();

    expect(trash.trashed, [at('lonely.raf')]);
    expect(events.whereType<DoneEvent>().single.summary, {'pruned_trashed': 1});
    expect(_staged(events), {'lonely.raf': 'orphan_raw'});
  });

  test('apply with delete removes the file from disk', () async {
    File(at('lonely.raf')).writeAsBytesSync([0, 0, 0]);

    final trash = _FakeTrash();
    final events = await service(trash).shrink(
      [root.path],
      const ShrinkOptions(
        stages: {ShrinkStage.orphans},
        dryRun: false,
        delete: true,
      ),
    ).toList();

    expect(trash.trashed, isEmpty);
    expect(File(at('lonely.raf')).existsSync(), isFalse);
    expect(events.whereType<DoneEvent>().single.summary, {'pruned_deleted': 1});
  });

  test(
    'duplicates stage needs two photos and a single file root works',
    () async {
      final only = at('only.jpg');
      _noisy(only, 8);

      final events = await service(_FakeTrash()).shrink([
        only,
        p.join(root.path, 'missing'),
      ], const ShrinkOptions(stages: {ShrinkStage.duplicates})).toList();

      expect(events.whereType<ItemEvent>(), isEmpty);
      expect(events.whereType<DoneEvent>().single.summary, isEmpty);
    },
  );

  test('an undecodable file is skipped by the low-quality stage', () async {
    File(at('broken.jpg')).writeAsBytesSync([1, 2, 3]);

    final events = await service(_FakeTrash()).shrink([
      root.path,
    ], const ShrinkOptions(stages: {ShrinkStage.lowQuality})).toList();

    expect(events.whereType<ItemEvent>(), isEmpty);
  });

  test('the duplicates stage accepts the Smart metric and degrades', () async {
    // No ONNX model in the test environment, so every embedding is empty and
    // the stage must fall back to Fast rather than staging nothing.
    _noisy(at('a.jpg'), 9);
    File(at('copy.jpg')).writeAsBytesSync(File(at('a.jpg')).readAsBytesSync());

    final events = await service(_FakeTrash()).shrink(
      [root.path],
      const ShrinkOptions(
        stages: {ShrinkStage.duplicates},
        metric: SimilarityMetric.smart,
      ),
    ).toList();

    expect(_staged(events).values, ['duplicate']);
  });

  test('every staged row carries dry_run until apply is set', () async {
    File(at('lonely.raf')).writeAsBytesSync([0, 0, 0]);

    final events = await service(_FakeTrash())
        .shrink([root.path], const ShrinkOptions(stages: {ShrinkStage.orphans}))
        .toList();

    expect(
      events.whereType<ItemEvent>().map((e) => e.row.status),
      everyElement(PhotoStatus.dryRun),
    );
  });
}
