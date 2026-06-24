import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:test/test.dart';

void main() {
  group('PhotoFormats', () {
    test('extOf lower-cases and strips the dot, empty for no extension', () {
      expect(PhotoFormats.extOf('/a/b/PHOTO.RAF'), 'raf');
      expect(PhotoFormats.extOf('photo.JpEg'), 'jpeg');
      expect(PhotoFormats.extOf('noext'), '');
    });

    test('isPhoto recognises taggable formats only', () {
      expect(PhotoFormats.isPhoto('a.jpg'), isTrue);
      expect(PhotoFormats.isPhoto('a.png'), isTrue);
      expect(PhotoFormats.isPhoto('a.heic'), isTrue);
      expect(PhotoFormats.isPhoto('a.raf'), isTrue);
      expect(PhotoFormats.isPhoto('a.txt'), isFalse);
      expect(PhotoFormats.isPhoto('a.gpx'), isFalse);
    });

    test('isRaw is true for raw containers only', () {
      expect(PhotoFormats.isRaw('a.raf'), isTrue);
      expect(PhotoFormats.isRaw('a.cr3'), isTrue);
      expect(PhotoFormats.isRaw('a.jpg'), isFalse);
      expect(PhotoFormats.isRaw('a.png'), isFalse);
    });
  });

  group('SystemProcessRunner', () {
    const runner = SystemProcessRunner();

    test(
      'captures exit code, stdout, and ok for a successful command',
      () async {
        final result = await runner.run('echo', ['hi']);
        expect(result.exitCode, 0);
        expect(result.ok, isTrue);
        expect(result.stdout.trim(), 'hi');
      },
    );
  });
}
