import 'package:gpsphototag_cli/src/cli_output.dart';
import 'package:gpsphototag_cli/src/exit_codes.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:test/test.dart';

/// Feeds [events] through a CliOutput and returns the derived exit code.
int exitFor(List<EngineEvent> events, {bool json = true}) {
  final out = CliOutput(json: json);
  for (final e in events) {
    out.add(e);
  }
  return out.exitCode;
}

void main() {
  test('all-success summary -> ok', () {
    expect(
      exitFor([
        const ItemEvent(PhotoRow(path: 'a', status: PhotoStatus.tagged)),
        const DoneEvent({'tagged': 1}),
      ]),
      ExitCodes.ok,
    );
  });

  test('no_gps in summary -> partial', () {
    expect(
      exitFor([
        const DoneEvent({'tagged': 2, 'no_gps': 1}),
      ]),
      ExitCodes.partial,
    );
  });

  test('per-item error in summary -> partial', () {
    expect(exitFor([const DoneEvent({'error': 1})]), ExitCodes.partial);
  });

  test('error events map to their codes', () {
    expect(exitFor([const ErrorEvent('x', code: 'bad_input')]),
        ExitCodes.badInput);
    expect(exitFor([const ErrorEvent('x', code: 'missing_toolkit')]),
        ExitCodes.missingToolkit);
    expect(exitFor([const ErrorEvent('x', code: 'internal')]),
        ExitCodes.internal);
  });

  test('a fatal error outranks a later done summary', () {
    expect(
      exitFor([
        const ErrorEvent('x', code: 'bad_input'),
        const DoneEvent({'tagged': 1}),
      ]),
      ExitCodes.badInput,
    );
  });
}
