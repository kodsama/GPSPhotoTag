import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// Records every process invocation and returns a canned result.
class _RecordingRunner implements ProcessRunner {
  _RecordingRunner(this.result);

  final ProcResult result;
  final List<(String, List<String>)> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add((executable, args));
    return result;
  }
}

void main() {
  group('SystemTrash (host platform)', () {
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
    // whose trash layout this test understands.
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
  });

  // The OS decision and environment are injectable, so each platform's layout
  // is reachable regardless of the host OS. These drive the trash *into* a
  // sandbox directory (via HOME / XDG_DATA_HOME) and assert the real on-disk
  // effect, so they would fail if the layout logic regressed.
  group('SystemTrash (injected platform)', () {
    late Directory tmp;
    late Directory home;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('system_trash_inj');
      home = Directory(p.join(tmp.path, 'home'))..createSync();
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    SystemTrash macTrash() =>
        SystemTrash(operatingSystem: 'macos', environment: {'HOME': home.path});

    test('macos layout moves the file into ~/.Trash', () async {
      final src = File(p.join(tmp.path, 'photo.raf'))..writeAsStringSync('A');
      await macTrash().toTrash(src.path);

      expect(src.existsSync(), isFalse);
      final trashed = File(p.join(home.path, '.Trash', 'photo.raf'));
      expect(trashed.existsSync(), isTrue);
      expect(trashed.readAsStringSync(), 'A');
    });

    test('macos layout de-duplicates a name conflict', () async {
      final trash = macTrash();
      final a = File(p.join(tmp.path, 'a', 'dup.raf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('A');
      final b = File(p.join(tmp.path, 'b', 'dup.raf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('B');

      await trash.toTrash(a.path);
      await trash.toTrash(b.path);

      final dir = Directory(p.join(home.path, '.Trash'));
      final names = dir.listSync().map((e) => p.basename(e.path)).toSet();
      expect(names, containsAll(<String>['dup.raf', 'dup 1.raf']));
    });

    test('linux layout writes files + a .trashinfo record', () async {
      final xdg = Directory(p.join(tmp.path, 'xdg'))..createSync();
      final trash = SystemTrash(
        operatingSystem: 'linux',
        environment: {'XDG_DATA_HOME': xdg.path},
      );
      final src = File(p.join(tmp.path, 'gone.jpg'))..writeAsStringSync('x');

      await trash.toTrash(src.path);

      expect(src.existsSync(), isFalse);
      final trashedFile = File(p.join(xdg.path, 'Trash', 'files', 'gone.jpg'));
      expect(trashedFile.existsSync(), isTrue);
      final info = File(
        p.join(xdg.path, 'Trash', 'info', 'gone.jpg.trashinfo'),
      );
      expect(info.existsSync(), isTrue);
      final text = info.readAsStringSync();
      expect(text, contains('[Trash Info]'));
      expect(text, contains('Path=${p.absolute(src.path)}'));
      expect(text, contains('DeletionDate='));
    });

    test('linux layout falls back to ~/.local/share without XDG var', () async {
      final trash = SystemTrash(
        operatingSystem: 'linux',
        environment: {'HOME': home.path},
      );
      final src = File(p.join(tmp.path, 'l.jpg'))..writeAsStringSync('x');

      await trash.toTrash(src.path);

      final trashedFile = File(
        p.join(home.path, '.local', 'share', 'Trash', 'files', 'l.jpg'),
      );
      expect(trashedFile.existsSync(), isTrue);
    });

    test(
      'windows layout shells out to PowerShell and succeeds on exit 0',
      () async {
        final runner = _RecordingRunner(const ProcResult(0, '', ''));
        final trash = SystemTrash(
          operatingSystem: 'windows',
          processRunner: runner,
        );
        final src = File(p.join(tmp.path, 'win.png'))..writeAsStringSync('x');

        await trash.toTrash(src.path);

        expect(runner.calls.single.$1, 'powershell');
        expect(runner.calls.single.$2.join(' '), contains('SendToRecycleBin'));
        expect(runner.calls.single.$2.join(' '), contains(src.path));
      },
    );

    test('windows layout throws when PowerShell exits non-zero', () async {
      final runner = _RecordingRunner(const ProcResult(1, '', 'denied'));
      final trash = SystemTrash(
        operatingSystem: 'windows',
        processRunner: runner,
      );
      final src = File(p.join(tmp.path, 'fail.png'))..writeAsStringSync('x');

      await expectLater(
        trash.toTrash(src.path),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('denied'),
          ),
        ),
      );
    });

    test(
      'windows single-quotes in the path are escaped for PowerShell',
      () async {
        final runner = _RecordingRunner(const ProcResult(0, '', ''));
        final trash = SystemTrash(
          operatingSystem: 'windows',
          processRunner: runner,
        );
        final src = File(p.join(tmp.path, "o'brien.png"))
          ..writeAsStringSync('x');

        await trash.toTrash(src.path);

        expect(runner.calls.single.$2.join(' '), contains("o''brien.png"));
      },
    );

    test('an unsupported platform throws UnsupportedError', () async {
      const trash = SystemTrash(operatingSystem: 'fuchsia');
      final src = File(p.join(tmp.path, 'x.raf'))..writeAsStringSync('x');

      await expectLater(
        trash.toTrash(src.path),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('a missing HOME makes the macos layout throw StateError', () async {
      const trash = SystemTrash(operatingSystem: 'macos', environment: {});
      final src = File(p.join(tmp.path, 'h.raf'))..writeAsStringSync('x');

      await expectLater(trash.toTrash(src.path), throwsA(isA<StateError>()));
    });
  });
}
