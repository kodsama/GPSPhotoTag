import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/state/library_roots.dart';

void main() {
  group('addRoots', () {
    test('appends new roots, preserving order', () {
      expect(addRoots(['/a'], ['/b', '/c']), ['/a', '/b', '/c']);
    });

    test('drops paths already present', () {
      expect(addRoots(['/a', '/b'], ['/b', '/c']), ['/a', '/b', '/c']);
    });

    test('dedupes repeats within the additions', () {
      expect(addRoots([], ['/a', '/a', '/b']), ['/a', '/b']);
    });

    test('returns an equal-length list when nothing is new', () {
      final out = addRoots(['/a'], ['/a']);
      expect(out, ['/a']);
    });
  });

  group('removeRoot', () {
    test('removes the matching root, order preserved', () {
      expect(removeRoot(['/a', '/b', '/c'], '/b'), ['/a', '/c']);
    });

    test('is a no-op when absent', () {
      expect(removeRoot(['/a'], '/x'), ['/a']);
    });
  });

  group('rootLabel', () {
    test('uses the basename', () {
      expect(rootLabel('/Users/me/Pictures'), 'Pictures');
      expect(rootLabel('/Users/me/a.jpg'), 'a.jpg');
    });

    test('falls back to the full path when basename is empty', () {
      expect(rootLabel('/'), '/');
    });
  });

  group('isAddableRoot', () {
    test('directories are always addable', () {
      expect(isAddableRoot('/anything', isDirectory: true), isTrue);
    });

    test('supported files are addable, others are not', () {
      expect(isAddableRoot('/a.jpg'), isTrue);
      expect(isAddableRoot('/a.gpx'), isTrue);
      expect(isAddableRoot('/a.mp4'), isFalse);
    });
  });

  group('classifyDropped', () {
    bool isDir(String path) => path.endsWith('/');

    test('splits dirs, supported files, and ignored', () {
      final r = classifyDropped([
        '/photos/',
        '/a.jpg',
        '/track.gpx',
        '/clip.mp4',
        '/notes.txt',
      ], isDirectory: isDir);
      expect(r.directories, ['/photos/']);
      expect(r.files, ['/a.jpg', '/track.gpx']);
      expect(r.ignored, ['/clip.mp4', '/notes.txt']);
      expect(r.accepted, ['/photos/', '/a.jpg', '/track.gpx']);
      expect(r.isEmpty, isFalse);
    });

    test('isEmpty is true when only ignored items dropped', () {
      final r = classifyDropped(['/clip.mp4'], isDirectory: isDir);
      expect(r.isEmpty, isTrue);
      expect(r.accepted, isEmpty);
    });

    test('defaults to a real filesystem probe for directories', () {
      // No injected probe: a nonexistent path is not a dir and (as .txt) is
      // ignored — exercising the default branch without touching content.
      final r = classifyDropped(['/no/such/path.txt']);
      expect(r.ignored, ['/no/such/path.txt']);
    });
  });
}
