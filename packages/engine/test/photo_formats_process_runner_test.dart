import 'package:stunda_engine/stunda_engine.dart';
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
      expect(PhotoFormats.isPhoto('a.webp'), isTrue);
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

    test('isGpsSource is true for tracks and json only', () {
      expect(PhotoFormats.isGpsSource('a.gpx'), isTrue);
      expect(PhotoFormats.isGpsSource('a.kml'), isTrue);
      expect(PhotoFormats.isGpsSource('a.json'), isTrue);
      expect(PhotoFormats.isGpsSource('a.jpg'), isFalse);
      expect(PhotoFormats.isGpsSource('a.txt'), isFalse);
    });

    test('isSupported covers photos and GPS sources, not others', () {
      expect(PhotoFormats.isSupported('a.jpg'), isTrue);
      expect(PhotoFormats.isSupported('a.raf'), isTrue);
      expect(PhotoFormats.isSupported('a.gpx'), isTrue);
      expect(PhotoFormats.isSupported('a.json'), isTrue);
      expect(PhotoFormats.isSupported('a.txt'), isFalse);
      expect(PhotoFormats.isSupported('a.mp4'), isFalse);
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

  group('SystemProcessRunner.extraPathDirs', () {
    test('macOS prepends the Homebrew/MacPorts locations', () {
      expect(SystemProcessRunner.extraPathDirs('macos', '/Users/me'), [
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/opt/local/bin',
      ]);
    });

    test('Linux includes ~/.local/bin only when HOME is set', () {
      expect(
        SystemProcessRunner.extraPathDirs('linux', '/home/me'),
        contains('/home/me/.local/bin'),
      );
      expect(
        SystemProcessRunner.extraPathDirs('linux', ''),
        isNot(contains('/.local/bin')),
      );
    });

    test('other platforms add nothing', () {
      expect(SystemProcessRunner.extraPathDirs('windows', ''), isEmpty);
      expect(SystemProcessRunner.extraPathDirs('fuchsia', '/h'), isEmpty);
    });
  });

  group('SystemProcessRunner.augmentedPath', () {
    test('appends platform dirs to the inherited PATH, de-duplicated', () {
      final result = SystemProcessRunner.augmentedPath(
        'macos',
        '/Users/me',
        '/usr/bin:/usr/local/bin', // /usr/local/bin appears in both.
      );
      final parts = result.split(':');
      expect(parts, contains('/usr/bin'));
      expect(parts, contains('/opt/homebrew/bin'));
      // De-duplicated: /usr/local/bin appears exactly once.
      expect(parts.where((d) => d == '/usr/local/bin'), hasLength(1));
      // Order preserved: inherited entries come first.
      expect(parts.first, '/usr/bin');
    });

    test('uses a semicolon separator on Windows', () {
      final result = SystemProcessRunner.augmentedPath(
        'windows',
        '',
        r'C:\Windows;C:\Windows\System32',
      );
      // Windows adds no extra dirs; the inherited path is returned verbatim,
      // split on ';' (not ':') so the drive-letter colons are preserved.
      expect(result, r'C:\Windows;C:\Windows\System32');
      expect(result.split(';'), [r'C:\Windows', r'C:\Windows\System32']);
    });

    test('drops empty entries from the inherited PATH', () {
      final result = SystemProcessRunner.augmentedPath('linux', '', '::/bin::');
      expect(result.split(':'), isNot(contains('')));
      expect(result.split(':'), contains('/bin'));
    });
  });
}
