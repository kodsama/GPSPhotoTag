import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/state/library_roots.dart';

void main() {
  group('addRoots', () {
    // Treat any path without a file extension as a directory, so the
    // containment logic is exercised without touching disk.
    bool isDir(String path) => !path.contains('.');

    test('appends new roots, preserving order', () {
      expect(addRoots(['/a'], ['/b', '/c'], isDirectory: isDir), [
        '/a',
        '/b',
        '/c',
      ]);
    });

    test('drops paths already present', () {
      expect(addRoots(['/a', '/b'], ['/b', '/c'], isDirectory: isDir), [
        '/a',
        '/b',
        '/c',
      ]);
    });

    test('dedupes repeats within the additions', () {
      expect(addRoots([], ['/a', '/a', '/b'], isDirectory: isDir), [
        '/a',
        '/b',
      ]);
    });

    test('returns an equal list when nothing is new', () {
      expect(addRoots(['/a'], ['/a'], isDirectory: isDir), ['/a']);
    });

    test('adding a child of an existing dir root is a no-op', () {
      // /pics is a dir root; /pics/trip and /pics/a.jpg are already covered.
      expect(
        addRoots(['/pics'], ['/pics/trip', '/pics/a.jpg'], isDirectory: isDir),
        ['/pics'],
      );
    });

    test('adding a parent dir subsumes existing nested children and files', () {
      expect(
        addRoots(
          ['/pics/trip', '/pics/a.jpg', '/other'],
          ['/pics'],
          isDirectory: isDir,
        ),
        ['/other', '/pics'],
      );
    });

    test('unrelated roots are all kept', () {
      expect(addRoots(['/a'], ['/b/x.jpg', '/c'], isDirectory: isDir), [
        '/a',
        '/b/x.jpg',
        '/c',
      ]);
    });

    test('a file root then its containing folder leaves only the folder', () {
      final afterFile = addRoots([], ['/pics/a.jpg'], isDirectory: isDir);
      expect(afterFile, ['/pics/a.jpg']);
      final afterFolder = addRoots(afterFile, ['/pics'], isDirectory: isDir);
      expect(afterFolder, ['/pics']);
    });

    test('a folder added then its child in the same batch is a no-op', () {
      expect(
        addRoots([], [
          '/pics',
          '/pics/trip',
          '/pics/a.jpg',
        ], isDirectory: isDir),
        ['/pics'],
      );
    });

    test('path-form differences resolve to the same coverage', () {
      // Trailing slash, ./ and .. forms all canonicalize to /pics.
      expect(addRoots(['/pics'], ['/pics/'], isDirectory: isDir), ['/pics']);
      expect(addRoots(['/pics'], ['/x/../pics/trip'], isDirectory: isDir), [
        '/pics',
      ]);
    });

    test('a file root does not subsume a path that merely shares a prefix', () {
      // /pics/a.jpg is a file, not a dir, so /pics/a.jpgx is unrelated.
      expect(addRoots(['/pics/a.jpg'], ['/pics/a.jpgx'], isDirectory: isDir), [
        '/pics/a.jpg',
        '/pics/a.jpgx',
      ]);
    });

    test('defaults to a real filesystem probe when isDirectory is omitted', () {
      // No injected probe: a nonexistent dir-like path is not a directory, so
      // it cannot cover the file added under it — both survive.
      final out = addRoots(['/no/such/dir'], ['/no/such/dir/a.jpg']);
      expect(out, ['/no/such/dir', '/no/such/dir/a.jpg']);
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
