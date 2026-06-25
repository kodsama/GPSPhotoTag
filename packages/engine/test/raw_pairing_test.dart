import 'package:stunda_engine/src/services/raw_pairing.dart';
import 'package:test/test.dart';

void main() {
  group('classifyPairing', () {
    test('classifies a mixed tree', () {
      final pairing = classifyPairing(const [
        '/lib/orphan.raf', // RAW, no companion -> orphan
        '/lib/pair.raf', // RAW with companion -> paired
        '/lib/pair.jpg', // companion with RAW -> photoWithRaw
        '/lib/solo.jpg', // companion, no RAW -> photoWithoutRaw
        '/lib/pic.png', // non-raw, non-companion -> photoWithoutRaw
      ]);

      expect(pairing.orphanCount, 1);
      expect(pairing.pairedRawCount, 1);
      expect(pairing.photoWithRawCount, 1);
      expect(pairing.photoWithoutRawCount, 2);
      expect(pairing.orphanRaws, ['/lib/orphan.raf']);
      expect(pairing.files, hasLength(5));
    });

    test('pairs companions across folders (tree-wide)', () {
      final pairing = classifyPairing(const [
        '/lib/a/DSCF3.RAF',
        '/lib/b/DSCF3.JPG',
      ]);
      // The cross-folder JPG saves the RAW from being an orphan.
      expect(pairing.orphanCount, 0);
      expect(pairing.pairedRawCount, 1);
      expect(pairing.photoWithRawCount, 1);
    });

    test('matching is case-insensitive on basename and extension', () {
      final pairing = classifyPairing(const [
        '/lib/Img_001.NEF',
        '/lib/img_001.jpeg',
      ]);
      expect(pairing.orphanCount, 0);
      expect(pairing.pairedRawCount, 1);
    });

    test('heic counts as a companion', () {
      final pairing = classifyPairing(const ['/lib/x.cr3', '/lib/x.HEIC']);
      expect(pairing.orphanCount, 0);
      expect(pairing.pairedRawCount, 1);
      expect(pairing.photoWithRawCount, 1);
    });

    test('an empty input yields empty everything', () {
      final pairing = classifyPairing(const []);
      expect(pairing.files, isEmpty);
      expect(pairing.orphanRaws, isEmpty);
      expect(pairing.orphanCount, 0);
    });

    test('preserves input order in files', () {
      final pairing = classifyPairing(const ['/lib/b.raf', '/lib/a.raf']);
      expect(pairing.files.map((f) => f.path), ['/lib/b.raf', '/lib/a.raf']);
    });
  });
}
