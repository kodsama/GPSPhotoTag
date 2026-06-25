import 'dart:io';

import 'package:gpsphototag_engine/src/data/ports/trash.dart';
import 'package:gpsphototag_engine/src/domain/engine_event.dart';
import 'package:gpsphototag_engine/src/domain/options.dart';
import 'package:gpsphototag_engine/src/domain/status.dart';
import 'package:gpsphototag_engine/src/services/pruner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Records paths instead of touching the real OS Trash.
class FakeTrash implements Trash {
  final List<String> trashed = [];

  @override
  Future<void> toTrash(String path) async => trashed.add(path);
}

/// A trash that always fails, to drive the per-orphan error branch.
class ThrowingTrash implements Trash {
  @override
  Future<void> toTrash(String path) async => throw StateError('trash full');
}

void main() {
  late Directory root;
  late String sub;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pruner_test_');
    sub = p.join(root.path, 'sub');
    Directory(sub).createSync();

    // Paired RAW + JPG in the same folder — must survive.
    _touch(root.path, 'DSCF1.RAF');
    _touch(root.path, 'DSCF1.JPG');

    // Orphan RAW with a sidecar — both must be removed.
    _touch(root.path, 'DSCF2.RAF');
    _touch(root.path, 'DSCF2.RAF.xmp');

    // Companion lives in a different folder — RAW must survive (tree-wide).
    _touch(root.path, 'DSCF3.RAF');
    _touch(sub, 'DSCF3.JPG');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('trashes only orphan RAWs and their sidecars', () async {
    final trash = FakeTrash();
    final events = await Pruner(
      trash: trash,
    ).prune([root.path], const PruneOptions()).toList();

    final orphan = p.join(root.path, 'DSCF2.RAF');
    final sidecar = p.join(root.path, 'DSCF2.RAF.xmp');

    expect(trash.trashed, unorderedEquals([orphan, sidecar]));

    // Survivors are never handed to trash; only orphans + sidecar are.
    expect(trash.trashed, isNot(contains(p.join(root.path, 'DSCF1.RAF'))));
    expect(trash.trashed, isNot(contains(p.join(root.path, 'DSCF3.RAF'))));
    // FakeTrash only records paths, so files remain on disk in trash mode.
    expect(File(p.join(root.path, 'DSCF1.RAF')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'DSCF3.RAF')).existsSync(), isTrue);

    final done = events.whereType<DoneEvent>().single;
    expect(done.summary[PhotoStatus.prunedTrashed.wire], 1);

    final items = events.whereType<ItemEvent>().toList();
    expect(items, hasLength(1));
    expect(items.single.row.path, orphan);
    expect(items.single.row.status, PhotoStatus.prunedTrashed);
  });

  test('dry run removes and trashes nothing', () async {
    final trash = FakeTrash();
    final events = await Pruner(
      trash: trash,
    ).prune([root.path], const PruneOptions(dryRun: true)).toList();

    expect(trash.trashed, isEmpty);
    expect(File(p.join(root.path, 'DSCF2.RAF')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'DSCF2.RAF.xmp')).existsSync(), isTrue);

    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.dryRun);

    final done = events.whereType<DoneEvent>().single;
    expect(done.summary[PhotoStatus.dryRun.wire], 1);
  });

  test('delete mode unlinks orphans without using trash', () async {
    final trash = FakeTrash();
    final events = await Pruner(
      trash: trash,
    ).prune([root.path], const PruneOptions(delete: true)).toList();

    expect(trash.trashed, isEmpty);
    expect(File(p.join(root.path, 'DSCF2.RAF')).existsSync(), isFalse);
    expect(File(p.join(root.path, 'DSCF2.RAF.xmp')).existsSync(), isFalse);

    final done = events.whereType<DoneEvent>().single;
    expect(done.summary[PhotoStatus.prunedDeleted.wire], 1);
  });

  test('a failing removal surfaces an error item and log', () async {
    final events = await Pruner(
      trash: ThrowingTrash(),
    ).prune([root.path], const PruneOptions()).toList();

    final item = events.whereType<ItemEvent>().single;
    expect(item.row.status, PhotoStatus.error);
    expect(item.row.note, contains('trash full'));

    final errLog = events.whereType<LogEvent>().firstWhere(
      (e) => e.level == LogLevel.error,
    );
    expect(errLog.message, contains('Failed to prune'));

    final done = events.whereType<DoneEvent>().single;
    expect(done.summary[PhotoStatus.error.wire], 1);
  });

  group('trashPaths', () {
    test('trashes exactly the given paths plus their sidecars', () async {
      final trash = FakeTrash();
      final orphan = p.join(root.path, 'DSCF2.RAF');
      final sidecar = '$orphan.xmp';

      final events = await Pruner(trash: trash).trashPaths([orphan]).toList();

      // Only the chosen path and its sidecar are acted on — the paired RAW the
      // user did not select is never touched.
      expect(trash.trashed, unorderedEquals([orphan, sidecar]));
      expect(trash.trashed, isNot(contains(p.join(root.path, 'DSCF1.RAF'))));

      final item = events.whereType<ItemEvent>().single;
      expect(item.row.path, orphan);
      expect(item.row.status, PhotoStatus.prunedTrashed);

      final done = events.whereType<DoneEvent>().single;
      expect(done.summary[PhotoStatus.prunedTrashed.wire], 1);
    });

    test('a path with no sidecar trashes just the file', () async {
      final trash = FakeTrash();
      final raw = p.join(root.path, 'DSCF1.RAF'); // no .xmp sidecar
      await Pruner(trash: trash).trashPaths([raw]).toList();
      expect(trash.trashed, [raw]);
    });

    test('delete mode unlinks without using trash', () async {
      final trash = FakeTrash();
      final orphan = p.join(root.path, 'DSCF2.RAF');
      final events = await Pruner(
        trash: trash,
      ).trashPaths([orphan], delete: true).toList();

      expect(trash.trashed, isEmpty);
      expect(File(orphan).existsSync(), isFalse);
      expect(File('$orphan.xmp').existsSync(), isFalse);

      final done = events.whereType<DoneEvent>().single;
      expect(done.summary[PhotoStatus.prunedDeleted.wire], 1);
    });

    test('a failing removal surfaces an error item and continues', () async {
      final orphan = p.join(root.path, 'DSCF1.RAF');
      final events = await Pruner(
        trash: ThrowingTrash(),
      ).trashPaths([orphan]).toList();

      final item = events.whereType<ItemEvent>().single;
      expect(item.row.status, PhotoStatus.error);
      expect(item.row.note, contains('trash full'));

      final done = events.whereType<DoneEvent>().single;
      expect(done.summary[PhotoStatus.error.wire], 1);
    });
  });
}

void _touch(String dir, String name) =>
    File(p.join(dir, name)).writeAsStringSync('x');
