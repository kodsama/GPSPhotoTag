import 'dart:convert';

import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// A [ProcessRunner] that returns canned exiftool JSON and records every call's
/// args so tests can assert chunking and the tag list.
class _FakeRunner implements ProcessRunner {
  _FakeRunner(this._responses);

  final List<String> _responses;
  final List<List<String>> calls = [];
  int _i = 0;

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);
    final out = _i < _responses.length ? _responses[_i++] : '[]';
    return ProcResult(0, out, '');
  }
}

void main() {
  group('readCuratedExif', () {
    test('parses the curated tag set from exiftool JSON', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {
            'SourceFile': '/lib/a.jpg',
            'Make': 'FUJIFILM',
            'Model': 'X-T4',
            'LensModel': 'XF35mmF1.4 R',
            'ISO': 200,
            'ExposureTime': '1/250',
            'FNumber': 2.8,
            'FocalLength': '35.0 mm',
          },
          {'SourceFile': '/lib/b.jpg'},
        ]),
      ]);

      final out = await readCuratedExif([
        '/lib/a.jpg',
        '/lib/b.jpg',
      ], runner: runner).toList();

      expect(out, hasLength(2));
      final a = out[0];
      expect(a.path, '/lib/a.jpg');
      expect(a.make, 'FUJIFILM');
      expect(a.model, 'X-T4');
      expect(a.lens, 'XF35mmF1.4 R');
      expect(a.iso, '200');
      expect(a.exposure, '1/250');
      expect(a.fNumber, '2.8');
      expect(a.focalLength, '35.0 mm');
      expect(a.isEmpty, isFalse);

      final b = out[1];
      expect(b.path, '/lib/b.jpg');
      expect(b.isEmpty, isTrue);
      expect(b.make, isNull);
    });

    test('falls back to ShutterSpeed when ExposureTime is absent', () async {
      final runner = _FakeRunner([
        jsonEncode([
          {'SourceFile': '/lib/a.jpg', 'ShutterSpeed': '1/60'},
        ]),
      ]);
      final out = await readCuratedExif([
        '/lib/a.jpg',
      ], runner: runner).toList();
      expect(out.single.exposure, '1/60');
    });

    test('requests the curated tags with -json and -fast2', () async {
      final runner = _FakeRunner([jsonEncode([])]);
      await readCuratedExif(['/lib/a.jpg'], runner: runner).toList();
      final args = runner.calls.single;
      expect(args, contains('-json'));
      expect(args, contains('-fast2'));
      expect(args, contains('-Make'));
      expect(args, contains('-LensModel'));
      expect(args, contains('-FNumber'));
      expect(args, contains('/lib/a.jpg'));
    });

    test('chunks large path lists into multiple exiftool calls', () async {
      final paths = [for (var i = 0; i < 5; i++) '/lib/p$i.jpg'];
      final runner = _FakeRunner([jsonEncode([]), jsonEncode([])]);
      final out = await readCuratedExif(
        paths,
        runner: runner,
        chunk: 2,
      ).toList();
      expect(out, hasLength(5));
      expect(runner.calls, hasLength(3)); // 2 + 2 + 1
    });

    test('tolerates empty/garbage stdout, yielding bare records', () async {
      final runner = _FakeRunner(['not json']);
      final out = await readCuratedExif([
        '/lib/a.jpg',
      ], runner: runner).toList();
      expect(out.single.isEmpty, isTrue);
    });

    test('CuratedExif.toJson round-trips the curated fields', () {
      const exif = CuratedExif(path: '/lib/a.jpg', make: 'Canon', iso: '400');
      final json = exif.toJson();
      expect(json['path'], '/lib/a.jpg');
      expect(json['make'], 'Canon');
      expect(json['iso'], '400');
      expect(json['model'], isNull);
    });

    test('blank string fields are treated as absent', () {
      final exif = CuratedExif.fromFields('/lib/a.jpg', const {
        'Make': '   ',
        'Model': '',
      });
      expect(exif.make, isNull);
      expect(exif.model, isNull);
      expect(exif.isEmpty, isTrue);
    });
  });
}
