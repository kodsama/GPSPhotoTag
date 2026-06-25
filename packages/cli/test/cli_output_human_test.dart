import 'package:stunda_cli/src/cli_output.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

import '_capture.dart';

void main() {
  late BufferSink out;
  late BufferSink err;

  setUp(() {
    out = BufferSink();
    err = BufferSink();
  });

  CliOutput human() => CliOutput(json: false, sink: out, errorSink: err);

  test('info/debug log lines go to the normal sink', () {
    human()
      ..add(const LogEvent('hello', level: LogLevel.info))
      ..add(const LogEvent('trace', level: LogLevel.debug));
    expect(out.text, contains('info: hello'));
    expect(out.text, contains('debug: trace'));
    expect(err.text, isEmpty);
  });

  test('warning/error log lines go to the error sink', () {
    human()
      ..add(const LogEvent('careful', level: LogLevel.warning))
      ..add(const LogEvent('boom', level: LogLevel.error));
    expect(err.text, contains('warning: careful'));
    expect(err.text, contains('error: boom'));
    expect(out.text, isEmpty);
  });

  test('item with a location renders coordinates and provenance', () {
    human().add(
      const ItemEvent(
        PhotoRow(
          path: '/photos/img.jpg',
          status: PhotoStatus.tagged,
          location: LocationResult(
            latitude: 42.70771,
            longitude: 18.34412,
            source: GpsSource.gpx,
            method: GpsMethod.exact,
          ),
        ),
      ),
    );
    expect(out.text, contains('img.jpg'));
    expect(out.text, contains('42.70771'));
    expect(out.text, contains('18.34412'));
    expect(out.text, contains('gpx/exact'));
  });

  test('item without a location renders status and note only', () {
    human().add(
      const ItemEvent(
        PhotoRow(
          path: '/photos/skip.jpg',
          status: PhotoStatus.alreadyTagged,
          note: 'use replace to overwrite',
        ),
      ),
    );
    expect(out.text, contains('skip.jpg'));
    expect(out.text, contains('already_tagged'));
    expect(out.text, contains('use replace to overwrite'));
  });

  test('done renders the sorted summary plus a total line', () {
    human().add(const DoneEvent({'tagged': 2, 'no_gps': 1}));
    final text = out.text;
    expect(text, contains('no_gps'));
    expect(text, contains('tagged'));
    expect(text, contains('total'));
    // Total across statuses is 3.
    expect(text, contains('3'));
  });

  test('progress events render nothing in human mode', () {
    human().add(const ProgressEvent(done: 1, total: 2));
    expect(out.text, isEmpty);
    expect(err.text, isEmpty);
  });

  test('error events render to the error sink', () {
    human().add(const ErrorEvent('kaboom', code: 'bad_input'));
    expect(err.text, contains('error: kaboom'));
  });
}
