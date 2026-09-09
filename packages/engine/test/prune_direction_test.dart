import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/src/data/ports/trash.dart';
import 'package:stunda_engine/src/domain/engine_event.dart';
import 'package:stunda_engine/src/domain/options.dart';
import 'package:stunda_engine/src/services/pruner.dart';
import 'package:stunda_engine/src/services/raw_pairing.dart';
import 'package:test/test.dart';

class _FakeTrash implements Trash {
  final List<String> trashed = [];

  @override
  Future<void> toTrash(String path) async => trashed.add(path);
}

void main() {
  group('PruneDirection.byWire', () {
    test('maps the CLI/MCP names to the enum', () {
      expect(
        PruneDirection.byWire('orphan-raws'),
        PruneDirection.removeOrphanRaws,
      );
      expect(
        PruneDirection.byWire('orphan-images'),
        PruneDirection.removeOrphanImages,
      );
    });

    test('an unknown name is null rather than a throw', () {
      expect(PruneDirection.byWire('sideways'), isNull);
    });
  });

  group('trashCandidates', () {
    final pairing = classifyPairing([
      '/lib/orphan.raf',
      '/lib/pair.raf',
      '/lib/pair.jpg',
      '/lib/solo.jpg',
    ]);

    test('orphan-raws targets only the unpaired RAW', () {
      expect(trashCandidates(pairing, PruneDirection.removeOrphanRaws), [
        '/lib/orphan.raf',
      ]);
    });

    test('orphan-images targets only the unpaired photo', () {
      expect(trashCandidates(pairing, PruneDirection.removeOrphanImages), [
        '/lib/solo.jpg',
      ]);
    });

    test('a paired file is never a target in either direction', () {
      for (final direction in PruneDirection.values) {
        final targets = trashCandidates(pairing, direction);
        expect(targets, isNot(contains('/lib/pair.raf')));
        expect(targets, isNot(contains('/lib/pair.jpg')));
      }
    });
  });

  group('Pruner honours the direction', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('prunedir_');
      for (final name in ['orphan.raf', 'pair.raf', 'pair.jpg', 'solo.jpg']) {
        File(p.join(root.path, name)).writeAsStringSync('x');
      }
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('the default direction still trashes only orphan RAWs', () async {
      final trash = _FakeTrash();
      await Pruner(trash: trash)
          .prune([root.path], const PruneOptions())
          .toList();

      expect(trash.trashed, [p.join(root.path, 'orphan.raf')]);
    });

    test('orphan-images trashes the photo side instead', () async {
      final trash = _FakeTrash();
      final events = await Pruner(trash: trash).prune(
        [root.path],
        const PruneOptions(direction: PruneDirection.removeOrphanImages),
      ).toList();

      expect(trash.trashed, [p.join(root.path, 'solo.jpg')]);
      expect(
        events.whereType<LogEvent>().map((e) => e.message),
        contains(contains('orphan-images')),
      );
    });
  });
}
