import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// A [ProcessRunner] that records every call and, on each invocation, writes the
/// embedded-image files a real exiftool would write under `-W`.
///
/// [outputs] maps a tag name (e.g. `PreviewImage`) to the byte payload to write
/// for it; absent tags simulate "this file has no such embedded image". The
/// runner parses the `-W <dir>/%f_%t.%s` pattern and the source path out of the
/// args exactly the way exiftool would, so the test exercises the real
/// arg-building + file-selection contract.
class _WritingRunner implements ProcessRunner {
  _WritingRunner(this.outputs);

  /// tag → bytes to write, for tags this fake "finds" in the source.
  final Map<String, List<int>> outputs;
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);

    // Parse the -W template and the requested tags out of the args.
    final wIndex = args.indexOf('-W');
    final template = args[wIndex + 1]; // <dir>/%f_%t.%s
    final dir = p.dirname(template);
    final source = args.last;
    final stem = p.basenameWithoutExtension(source);
    final tags = [
      for (final a in args)
        if (a.startsWith('-') &&
            a.length > 1 &&
            outputs.containsKey(a.substring(1)))
          a.substring(1),
    ];

    for (final tag in tags) {
      final bytes = outputs[tag];
      if (bytes == null) continue;
      File(p.join(dir, '${stem}_$tag.jpg')).writeAsBytesSync(bytes);
    }
    return const ProcResult(0, '', '');
  }
}

/// A runner that writes nothing (the source carries no embedded preview).
class _EmptyRunner implements ProcessRunner {
  final List<List<String>> calls = [];

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    calls.add(args);
    return const ProcResult(0, '', '');
  }
}

/// A runner that records calls; used to prove the cache short-circuits it.
class _CountingRunner implements ProcessRunner {
  int runs = 0;

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    runs++;
    return const ProcResult(0, '', '');
  }
}

void main() {
  late Directory tmp;

  setUp(
    () => tmp = Directory.systemTemp.createTempSync('preview_extract_test_'),
  );
  tearDown(() => tmp.deleteSync(recursive: true));

  String writeSource(String name) {
    final path = p.join(tmp.path, name);
    File(path).writeAsBytesSync([0xff, 0xd8, 0xff]); // tiny RAF stand-in
    return path;
  }

  List<int> bytesOfLen(int n) => List<int>.filled(n, 0x41);

  group('buildExtractArgs', () {
    test('full prefers PreviewImage, then JpgFromRaw, then ThumbnailImage', () {
      final args = buildExtractArgs(
        '/x/DSCF1.RAF',
        '/tmp/out',
        PreviewSize.full,
      );
      expect(args, containsAll(['-b', '-m', '-W', '/tmp/out/%f_%t.%s']));
      // Tag order is the selection priority for "full".
      const tagFlags = {'-PreviewImage', '-JpgFromRaw', '-ThumbnailImage'};
      final tagArgs = args.where(tagFlags.contains);
      expect(tagArgs.toList(), [
        '-PreviewImage',
        '-JpgFromRaw',
        '-ThumbnailImage',
      ]);
      expect(args.last, '/x/DSCF1.RAF');
    });

    test('thumb prefers ThumbnailImage, then PreviewImage', () {
      final args = buildExtractArgs(
        '/x/DSCF1.RAF',
        '/tmp/out',
        PreviewSize.thumb,
      );
      final tags = args.where((a) => a.endsWith('Image')).toList();
      expect(tags, ['-ThumbnailImage', '-PreviewImage']);
    });
  });

  group('cachePathFor', () {
    test('disambiguates same basename in different folders', () {
      final a = cachePathFor('/lib/x/DSCF1.RAF', '/cache', PreviewSize.full);
      final b = cachePathFor('/lib/y/DSCF1.RAF', '/cache', PreviewSize.full);
      expect(a, isNot(b));
      expect(p.basename(a), endsWith('_full.jpg'));
    });

    test('thumb and full of the same source differ', () {
      final f = cachePathFor('/lib/DSCF1.RAF', '/cache', PreviewSize.full);
      final t = cachePathFor('/lib/DSCF1.RAF', '/cache', PreviewSize.thumb);
      expect(f, isNot(t));
    });
  });

  group('extractPreview — full', () {
    test(
      'picks the largest produced file (PreviewImage over Thumbnail)',
      () async {
        final src = writeSource('DSCF1.RAF');
        final runner = _WritingRunner({
          'PreviewImage': bytesOfLen(5000),
          'ThumbnailImage': bytesOfLen(80),
        });
        final cacheDir = p.join(tmp.path, 'cache');

        final out = await extractPreview(
          src,
          cacheDir: cacheDir,
          size: PreviewSize.full,
          runner: runner,
        );

        expect(out, isNotNull);
        expect(
          File(out!).lengthSync(),
          5000,
        ); // the large preview, not the thumb
        expect(p.isWithin(cacheDir, out), isTrue);
      },
    );

    test('falls back to JpgFromRaw when PreviewImage absent', () async {
      final src = writeSource('IMG.CR2');
      final runner = _WritingRunner({'JpgFromRaw': bytesOfLen(3000)});
      final out = await extractPreview(
        src,
        cacheDir: p.join(tmp.path, 'cache'),
        size: PreviewSize.full,
        runner: runner,
      );
      expect(out, isNotNull);
      expect(File(out!).lengthSync(), 3000);
    });

    test('falls back to ThumbnailImage when nothing larger exists', () async {
      final src = writeSource('IMG.NEF');
      final runner = _WritingRunner({'ThumbnailImage': bytesOfLen(120)});
      final out = await extractPreview(
        src,
        cacheDir: p.join(tmp.path, 'cache'),
        size: PreviewSize.full,
        runner: runner,
      );
      expect(File(out!).lengthSync(), 120);
    });
  });

  group('extractPreview — thumb', () {
    test(
      'picks the smallest produced file (the dedicated thumbnail)',
      () async {
        final src = writeSource('DSCF2.RAF');
        final runner = _WritingRunner({
          'ThumbnailImage': bytesOfLen(90),
          'PreviewImage': bytesOfLen(6000),
        });
        final out = await extractPreview(
          src,
          cacheDir: p.join(tmp.path, 'cache'),
          size: PreviewSize.thumb,
          runner: runner,
        );
        expect(File(out!).lengthSync(), 90);
      },
    );
  });

  group('extractPreview — none produced', () {
    test('returns null when exiftool writes no embedded image', () async {
      final src = writeSource('DSCF3.RAF');
      final runner = _EmptyRunner();
      final out = await extractPreview(
        src,
        cacheDir: p.join(tmp.path, 'cache'),
        size: PreviewSize.full,
        runner: runner,
      );
      expect(out, isNull);
      expect(runner.calls, hasLength(1));
    });

    test('returns null when the source does not exist', () async {
      final runner = _CountingRunner();
      final out = await extractPreview(
        p.join(tmp.path, 'missing.RAF'),
        cacheDir: p.join(tmp.path, 'cache'),
        size: PreviewSize.full,
        runner: runner,
      );
      expect(out, isNull);
      expect(runner.runs, 0); // never ran exiftool on a missing file
    });
  });

  group('extractPreview — cache', () {
    test('skips re-extraction when the cached file is fresh', () async {
      final src = writeSource('DSCF4.RAF');
      final cacheDir = p.join(tmp.path, 'cache');
      final writing = _WritingRunner({'PreviewImage': bytesOfLen(2048)});

      final first = await extractPreview(
        src,
        cacheDir: cacheDir,
        size: PreviewSize.full,
        runner: writing,
      );
      expect(first, isNotNull);
      expect(writing.calls, hasLength(1));

      // Second call with a runner that would throw if invoked: proves the cache
      // short-circuits before touching exiftool.
      final counting = _CountingRunner();
      final second = await extractPreview(
        src,
        cacheDir: cacheDir,
        size: PreviewSize.full,
        runner: counting,
      );
      expect(second, first);
      expect(counting.runs, 0);
    });

    test('re-extracts when the source is newer than the cache', () async {
      final src = writeSource('DSCF5.RAF');
      final cacheDir = p.join(tmp.path, 'cache');
      final runner = _WritingRunner({'PreviewImage': bytesOfLen(1000)});

      await extractPreview(
        src,
        cacheDir: cacheDir,
        size: PreviewSize.full,
        runner: runner,
      );
      expect(runner.calls, hasLength(1));

      // Touch the source so it is newer than the cached extract.
      final cachePath = cachePathFor(src, cacheDir, PreviewSize.full);
      File(
        cachePath,
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      File(src).setLastModifiedSync(DateTime.now());

      await extractPreview(
        src,
        cacheDir: cacheDir,
        size: PreviewSize.full,
        runner: runner,
      );
      expect(runner.calls, hasLength(2)); // ran again
    });
  });
}
