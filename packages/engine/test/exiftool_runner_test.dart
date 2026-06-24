import 'dart:io';

import 'package:gpsphototag_engine/src/data/ports/exiftool_runner.dart';
import 'package:gpsphototag_engine/src/data/ports/process_runner.dart';
import 'package:test/test.dart';

/// Records the (executable, args) of every call and returns a canned result.
class RecordingRunner implements ProcessRunner {
  final List<(String, List<String>)> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add((executable, args));
    return const ProcResult(0, '', '');
  }
}

void main() {
  group('ExiftoolInvocation.resolve', () {
    test('null bundleDir -> bare exiftool on PATH', () {
      final inv = ExiftoolInvocation.resolve(null);
      expect(inv.executable, 'exiftool');
      expect(inv.prefixArgs, isEmpty);
    });

    test('non-null bundleDir on POSIX -> perl + script', () {
      final inv = ExiftoolInvocation.resolve('/bundle/exiftool');
      expect(inv.executable, 'perl');
      expect(inv.prefixArgs, ['/bundle/exiftool/exiftool']);
    }, testOn: '!windows');

    test(
      'non-null bundleDir on Windows without .exe -> PATH fallback',
      () {
        final tmp = Directory.systemTemp.createTempSync('et_resolve');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final inv = ExiftoolInvocation.resolve(tmp.path);
        expect(inv.executable, 'exiftool');
        expect(inv.prefixArgs, isEmpty);
      },
      testOn: 'windows',
    );

    test('non-null bundleDir on Windows with .exe -> uses it', () {
      final tmp = Directory.systemTemp.createTempSync('et_resolve');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/exiftool.exe').writeAsStringSync('');
      final inv = ExiftoolInvocation.resolve(tmp.path);
      expect(inv.executable, '${tmp.path}/exiftool.exe');
      expect(inv.prefixArgs, isEmpty);
    }, testOn: 'windows');
  });

  group('ExiftoolRunner', () {
    test('rewrites exiftool -> perl + script for a bundle dir', () async {
      final base = RecordingRunner();
      final runner = ExiftoolRunner(
        base,
        const ExiftoolInvocation('perl', ['/bundle/exiftool']),
      );
      await runner.run('exiftool', const ['-ver']);
      expect(base.calls.single.$1, 'perl');
      expect(base.calls.single.$2, ['/bundle/exiftool', '-ver']);
    });

    test('passes other executables through unchanged', () async {
      final base = RecordingRunner();
      final runner = ExiftoolRunner(
        base,
        const ExiftoolInvocation('perl', ['/bundle/exiftool']),
      );
      await runner.run('SetFile', const ['-d', 'date', 'file']);
      expect(base.calls.single.$1, 'SetFile');
      expect(base.calls.single.$2, ['-d', 'date', 'file']);
    });

    test('with a PATH invocation, exiftool stays exiftool', () async {
      final base = RecordingRunner();
      final runner = ExiftoolRunner(base, ExiftoolInvocation.resolve(null));
      await runner.run('exiftool', const ['-G', '-j']);
      expect(base.calls.single.$1, 'exiftool');
      expect(base.calls.single.$2, ['-G', '-j']);
    });
  });
}
