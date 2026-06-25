import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:test/test.dart';

class _NoopRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async =>
      const ProcResult(0, '', '');
}

void main() {
  final runner = _NoopRunner();

  BackendRegistry registry({
    RawMode rawMode = RawMode.auto,
    bool exiftool = true,
  }) => BackendRegistry(
    runner: runner,
    rawMode: rawMode,
    exiftoolAvailable: exiftool,
  );

  group('readerFor', () {
    test('jpeg and png have dedicated readers regardless of exiftool', () {
      final r = registry(exiftool: false);
      expect(r.readerFor('a.jpg'), isA<JpegExifBackend>());
      expect(r.readerFor('a.jpeg'), isA<JpegExifBackend>());
      expect(r.readerFor('a.png'), isA<PngExifBackend>());
    });

    test('heic reads via exiftool when present, null when absent', () {
      expect(registry().readerFor('a.heic'), isA<ExiftoolBackend>());
      expect(registry(exiftool: false).readerFor('a.heic'), isNull);
    });

    test('webp reads via exiftool when present, null when absent', () {
      expect(registry().readerFor('a.webp'), isA<ExiftoolBackend>());
      expect(registry(exiftool: false).readerFor('a.webp'), isNull);
    });

    test('raw reads via exiftool when present, sidecar when absent', () {
      expect(registry().readerFor('a.raf'), isA<ExiftoolBackend>());
      expect(
        registry(exiftool: false).readerFor('a.raf'),
        isA<XmpSidecarBackend>(),
      );
    });

    test('unknown extension has no reader', () {
      expect(registry().readerFor('a.txt'), isNull);
    });
  });

  group('writerFor', () {
    test('jpeg and png have dedicated writers', () {
      final r = registry();
      expect(r.writerFor('a.jpg'), isA<JpegExifBackend>());
      expect(r.writerFor('a.png'), isA<PngExifBackend>());
    });

    test('heic writes via exiftool when present, null when absent', () {
      expect(registry().writerFor('a.heic'), isA<ExiftoolBackend>());
      expect(registry(exiftool: false).writerFor('a.heic'), isNull);
    });

    test('webp writes via exiftool when present, null when absent', () {
      expect(registry().writerFor('a.webp'), isA<ExiftoolBackend>());
      expect(registry(exiftool: false).writerFor('a.webp'), isNull);
    });

    test('raw embed mode requires exiftool', () {
      expect(
        registry(rawMode: RawMode.embed).writerFor('a.raf'),
        isA<ExiftoolBackend>(),
      );
      expect(
        registry(rawMode: RawMode.embed, exiftool: false).writerFor('a.raf'),
        isNull,
      );
    });

    test('raw sidecar mode always writes a sidecar', () {
      expect(
        registry(rawMode: RawMode.sidecar).writerFor('a.raf'),
        isA<XmpSidecarBackend>(),
      );
      expect(
        registry(rawMode: RawMode.sidecar, exiftool: false).writerFor('a.raf'),
        isA<XmpSidecarBackend>(),
      );
    });

    test('raw auto mode prefers exiftool, falls back to sidecar', () {
      expect(
        registry(rawMode: RawMode.auto).writerFor('a.raf'),
        isA<ExiftoolBackend>(),
      );
      expect(
        registry(rawMode: RawMode.auto, exiftool: false).writerFor('a.raf'),
        isA<XmpSidecarBackend>(),
      );
    });

    test('unknown extension has no writer', () {
      expect(registry().writerFor('a.txt'), isNull);
    });
  });

  group('writesSidecar', () {
    test('true only for raw routed to a sidecar', () {
      expect(registry(rawMode: RawMode.sidecar).writesSidecar('a.raf'), isTrue);
      expect(
        registry(rawMode: RawMode.auto, exiftool: false).writesSidecar('a.raf'),
        isTrue,
      );
    });

    test('false for raw embedded via exiftool and for non-raw', () {
      expect(registry(rawMode: RawMode.embed).writesSidecar('a.raf'), isFalse);
      expect(registry().writesSidecar('a.jpg'), isFalse);
    });
  });
}
