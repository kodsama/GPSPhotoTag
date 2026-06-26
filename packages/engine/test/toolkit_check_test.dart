import 'package:stunda_engine/src/data/ports/process_runner.dart';
import 'package:stunda_engine/src/services/toolkit_check.dart';
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
    test('check() returns only the exiftool entry', () async {
      final checker = ToolkitChecker(FakeProcessRunner(const {}));
      final statuses = await checker.check();
      expect(statuses.map((s) => s.id), ['exiftool']);
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
        expect(checker.canHeic(statuses), isFalse);
      },
    );

    test('exiftool non-zero exit is treated as absent', () async {
      final checker = ToolkitChecker(
        FakeProcessRunner({'exiftool': const ProcResult(1, '', 'boom')}),
      );
      final statuses = await checker.check();
      expect(statuses.firstWhere((s) => s.id == 'exiftool').present, isFalse);
    });

    test(
      'install command is OS-specific for each supported platform',
      () async {
        Future<String?> hintFor(String os) async {
          final checker = ToolkitChecker(
            FakeProcessRunner(const {}),
            operatingSystem: os,
          );
          final statuses = await checker.check();
          return statuses.firstWhere((s) => s.id == 'exiftool').installCommand;
        }

        expect(await hintFor('macos'), 'brew install exiftool');
        expect(
          await hintFor('linux'),
          'sudo apt install libimage-exiftool-perl',
        );
        expect(
          await hintFor('windows'),
          'winget install -e --id OliverBetz.ExifTool',
        );
        expect(await hintFor('fuchsia'), isNull);
      },
    );

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
