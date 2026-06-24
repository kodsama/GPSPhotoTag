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
    final events = await Pruner(trash: trash)
        .prune([root.path], const PruneOptions())
        .toList();

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
    final events = await Pruner(trash: trash)
        .prune([root.path], const PruneOptions(dryRun: true))
        .toList();

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
    final events = await Pruner(trash: trash)
        .prune([root.path], const PruneOptions(delete: true))
        .toList();

    expect(trash.trashed, isEmpty);
    expect(File(p.join(root.path, 'DSCF2.RAF')).existsSync(), isFalse);
    expect(File(p.join(root.path, 'DSCF2.RAF.xmp')).existsSync(), isFalse);

    final done = events.whereType<DoneEvent>().single;
    expect(done.summary[PhotoStatus.prunedDeleted.wire], 1);
  });
}

void _touch(String dir, String name) =>
    File(p.join(dir, name)).writeAsStringSync('x');
