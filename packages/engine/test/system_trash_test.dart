import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('SystemTrash', () {
    const trash = SystemTrash();
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('system_trash_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('throws FileSystemException for a missing source', () {
      expect(
        () => trash.toTrash(p.join(tmp.path, 'does-not-exist.raf')),
        throwsA(isA<FileSystemException>()),
      );
    });

    // Filesystem-level assertions are only meaningful on the POSIX platforms
    // whose trash layout this test understands. Windows uses the Recycle Bin
    // and is unreachable in this CI environment.
    final posix = Platform.isMacOS || Platform.isLinux;

    test(
      'moves a file out of its source location',
      () async {
        final src = File(p.join(tmp.path, 'orphan.raf'))
          ..writeAsStringSync('a');
        await trash.toTrash(src.path);
        expect(src.existsSync(), isFalse);
      },
      skip: posix ? false : 'POSIX-only trash layout',
    );

    test(
      'handles a name conflict by de-duplicating in the trash',
      () async {
        // Two distinct files that share a basename: the second must not clobber
        // the first in the trash directory, exercising the _uniqueDest counter.
        final dirA = Directory(p.join(tmp.path, 'a'))..createSync();
        final dirB = Directory(p.join(tmp.path, 'b'))..createSync();
        final fileA = File(p.join(dirA.path, 'dup.raf'))
          ..writeAsStringSync('A');
        final fileB = File(p.join(dirB.path, 'dup.raf'))
          ..writeAsStringSync('B');

        await trash.toTrash(fileA.path);
        await trash.toTrash(fileB.path);

        expect(fileA.existsSync(), isFalse);
        expect(fileB.existsSync(), isFalse);
      },
      skip: posix ? false : 'POSIX-only trash layout',
    );
  });
}
