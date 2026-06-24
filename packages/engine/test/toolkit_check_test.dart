import 'package:gpsphototag_engine/src/data/ports/process_runner.dart';
import 'package:gpsphototag_engine/src/services/toolkit_check.dart';
import 'package:test/test.dart';

/// A [ProcessRunner] that returns canned results keyed by executable name.
///
/// Executables absent from [responses] are treated as missing binaries: `run`
/// throws, mirroring `dart:io` `Process.run` when a command is not found.
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner(this.responses);

  final Map<String, ProcResult> responses;

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    final result = responses[executable];
    if (result == null) {
      throw ProcessException(executable, args, 'not found', 2);
    }
    return result;
  }
}

class ProcessException implements Exception {
  ProcessException(
    this.executable,
    this.arguments,
    this.message,
    this.errorCode,
  );
  final String executable;
  final List<String> arguments;
  final String message;
  final int errorCode;
}

void main() {
  group('ToolkitChecker', () {
    test('check() returns one entry per known tool', () async {
      final checker = ToolkitChecker(FakeProcessRunner(const {}));
      final statuses = await checker.check();
      expect(statuses.map((s) => s.id), [
        'exiftool',
        'libheif',
        'package_manager',
      ]);
    });

    test('exiftool present: parses version and emits installCommand', () async {
      final checker = ToolkitChecker(
        FakeProcessRunner({'exiftool': const ProcResult(0, '13.55\n', '')}),
      );
      final statuses = await checker.check();
      final exiftool = statuses.firstWhere((s) => s.id == 'exiftool');

      expect(exiftool.present, isTrue);
      expect(exiftool.version, '13.55');
      expect(exiftool.installCommand, isNotNull);
      expect(checker.canEmbedRaw(statuses), isTrue);
      expect(checker.canHeic(statuses), isTrue);
    });

    test(
      'exiftool missing: present false but status still has install hint',
      () async {
        final checker = ToolkitChecker(FakeProcessRunner(const {}));
        final statuses = await checker.check();
        final exiftool = statuses.firstWhere((s) => s.id == 'exiftool');

        expect(exiftool.present, isFalse);
        expect(exiftool.version, isNull);
        expect(exiftool.installCommand, isNotNull);
        expect(checker.canEmbedRaw(statuses), isFalse);
      },
    );

    test('exiftool non-zero exit is treated as absent', () async {
      final checker = ToolkitChecker(
        FakeProcessRunner({'exiftool': const ProcResult(1, '', 'boom')}),
      );
      final statuses = await checker.check();
      expect(statuses.firstWhere((s) => s.id == 'exiftool').present, isFalse);
    });

    test('libheif detected via heif-dec --version', () async {
      final checker = ToolkitChecker(
        FakeProcessRunner({
          'heif-dec': const ProcResult(0, 'libheif version: 1.17.6\n', ''),
        }),
      );
      final statuses = await checker.check();
      final libheif = statuses.firstWhere((s) => s.id == 'libheif');

      expect(libheif.present, isTrue);
      expect(libheif.version, '1.17.6');
      expect(checker.canHeic(statuses), isTrue);
    });

    test('libheif falls back to heif-convert even on non-zero exit', () async {
      final checker = ToolkitChecker(
        FakeProcessRunner({
          'heif-convert': const ProcResult(1, '', 'usage: heif-convert ...'),
        }),
      );
      final statuses = await checker.check();
      expect(statuses.firstWhere((s) => s.id == 'libheif').present, isTrue);
    });

    test('canHeic is true when only exiftool is present', () async {
      final checker = ToolkitChecker(
        FakeProcessRunner({'exiftool': const ProcResult(0, '13.55', '')}),
      );
      final statuses = await checker.check();
      expect(checker.canHeic(statuses), isTrue);
    });

    test('every status serialises to JSON with expected keys', () async {
      final checker = ToolkitChecker(FakeProcessRunner(const {}));
      final statuses = await checker.check();
      for (final status in statuses) {
        final json = status.toJson();
        expect(
          json.keys,
          containsAll([
            'id',
            'name',
            'present',
            'version',
            'purpose',
            'required',
            'installCommand',
          ]),
        );
        expect(status.required, isFalse);
      }
    });
  });
}
