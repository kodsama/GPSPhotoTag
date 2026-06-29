import 'package:flutter_test/flutter_test.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:stunda/src/state/prune_direction.dart';

void main() {
  group('trashCandidates', () {
    final mixed = classifyPairing(const [
      '/lib/a.raf', // orphan RAW
      '/lib/b.raf', // paired RAW
      '/lib/b.jpg', // photo with RAW
      '/lib/c.jpg', // orphan image
      '/lib/d.heic', // orphan image
    ]);

    test('direction A trashes only orphan RAWs', () {
      expect(trashCandidates(mixed, PruneDirection.removeOrphanRaws), [
        '/lib/a.raf',
      ]);
    });

    test('direction B trashes only orphan images', () {
      expect(trashCandidates(mixed, PruneDirection.removeOrphanImages), [
        '/lib/c.jpg',
        '/lib/d.heic',
      ]);
    });

    test('paired files are never trashed in either direction', () {
      for (final dir in PruneDirection.values) {
        final out = trashCandidates(mixed, dir);
        expect(out, isNot(contains('/lib/b.raf')));
        expect(out, isNot(contains('/lib/b.jpg')));
      }
    });

    test('empty pairing yields no candidates', () {
      final empty = classifyPairing(const []);
      for (final dir in PruneDirection.values) {
        expect(trashCandidates(empty, dir), isEmpty);
      }
    });

    test('a library with no targets for a direction yields empty', () {
      // Only orphan RAWs present: direction B (images) finds nothing.
      final onlyRaws = classifyPairing(const ['/lib/a.raf', '/lib/b.raf']);
      expect(
        trashCandidates(onlyRaws, PruneDirection.removeOrphanImages),
        isEmpty,
      );
      expect(trashCandidates(onlyRaws, PruneDirection.removeOrphanRaws), [
        '/lib/a.raf',
        '/lib/b.raf',
      ]);
    });

    test('each direction maps to its target kind, label, and description', () {
      expect(PruneDirection.removeOrphanRaws.target, PairKind.orphanRaw);
      expect(
        PruneDirection.removeOrphanImages.target,
        PairKind.photoWithoutRaw,
      );
      expect(PruneDirection.removeOrphanRaws.labelKey, 'prune_dir_orphan_raws');
      expect(
        PruneDirection.removeOrphanImages.labelKey,
        'prune_dir_orphan_images',
      );
      expect(PruneDirection.removeOrphanRaws.descriptionKey, isNotEmpty);
      expect(PruneDirection.removeOrphanImages.descriptionKey, isNotEmpty);
    });
  });
}
