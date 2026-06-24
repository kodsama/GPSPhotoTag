import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A runner that never gets invoked here (JPEG dispatch is pure-Dart); it just
/// satisfies the registry constructor.
class _UnusedRunner implements ProcessRunner {
  @override
  Future<ProcResult> run(String executable, List<String> args) async =>
      const ProcResult(0, '', '');
}

void main() {
  group('DispatchingExifBackend', () {
    late Directory tmp;
    late DispatchingExifBackend backend;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dispatch_test');
      final registry = BackendRegistry(
        runner: _UnusedRunner(),
        exiftoolAvailable: false,
      );
      backend = DispatchingExifBackend(registry);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('supports is true for jpg and false for txt', () {
      expect(backend.supports('a.jpg'), isTrue);
      expect(backend.supports('a.txt'), isFalse);
    });

    test('read returns a default PhotoMeta for an unsupported file', () async {
      final meta = await backend.read(p.join(tmp.path, 'note.txt'));
      expect(meta.captureNaive, isNull);
      expect(meta.offset, isNull);
      expect(meta.hasGps, isFalse);
    });

    test('writeGps throws StateError when no writer backend exists', () {
      expect(
        () => backend.writeGps(
          p.join(tmp.path, 'note.txt'),
          latitude: 1,
          longitude: 2,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('writeGps dispatches to the JPEG backend and round-trips', () async {
      final path = p.join(tmp.path, 'photo.jpg');
      File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 4, height: 4)));

      await backend.writeGps(path, latitude: 42.7077, longitude: 18.3441);

      final meta = await backend.read(path);
      expect(meta.hasGps, isTrue);
    });
  });
}
