import 'dart:convert';
import 'dart:io';

import 'package:gpsphototag_engine/src/data/exif/exiftool_backend.dart';
import 'package:gpsphototag_engine/src/data/exif/png_exif_backend.dart';
import 'package:gpsphototag_engine/src/data/exif/xmp_sidecar_backend.dart';
import 'package:gpsphototag_engine/src/data/ports/process_runner.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// A [ProcessRunner] that returns a canned result and records the call.
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner(this._result);

  final ProcResult _result;
  String? executable;
  List<String>? args;

  @override
  Future<ProcResult> run(String executable, List<String> args) async {
    this.executable = executable;
    this.args = args;
    return _result;
  }
}

void main() {
  group('ExiftoolBackend', () {
    test('supports RAW and HEIC extensions, rejects others', () {
      final backend = ExiftoolBackend(FakeProcessRunner(const ProcResult(0, '', '')));
      expect(backend.supports('/x/DSCF1.RAF'), isTrue);
      expect(backend.supports('/x/DSCF1.raf'), isTrue);
      expect(backend.supports('/x/IMG.HEIC'), isTrue);
      expect(backend.supports('/x/IMG.heif'), isTrue);
      expect(backend.supports('/x/IMG.jpg'), isFalse);
      expect(backend.supports('/x/noext'), isFalse);
    });

    test('read parses capture time, offset, and GPS presence', () async {
      const json = '''
[{
  "DateTimeOriginal": "2023:07:15 14:30:05",
  "CreateDate": "2023:07:15 14:30:05",
  "OffsetTimeOriginal": "+02:00",
  "GPSLatitude": "48.8584",
  "GPSLongitude": "2.2945"
}]''';
      final backend = ExiftoolBackend(FakeProcessRunner(const ProcResult(0, json, '')));
      final meta = await backend.read('/x/photo.raf');

      expect(meta.captureNaive, DateTime(2023, 7, 15, 14, 30, 5));
      expect(meta.offset, const Duration(hours: 2));
      expect(meta.hasGps, isTrue);
    });

    test('read falls back to CreateDate and reports no GPS', () async {
      const json = '''
[{"CreateDate": "2020:01:02 03:04:05.123-05:00"}]''';
      final backend = ExiftoolBackend(FakeProcessRunner(const ProcResult(0, json, '')));
      final meta = await backend.read('/x/photo.nef');

      expect(meta.captureNaive, DateTime(2020, 1, 2, 3, 4, 5));
      expect(meta.offset, isNull);
      expect(meta.hasGps, isFalse);
    });

    test('read returns empty PhotoMeta on non-zero exit', () async {
      final backend =
          ExiftoolBackend(FakeProcessRunner(const ProcResult(1, '', 'boom')));
      final meta = await backend.read('/x/photo.raf');

      expect(meta.captureNaive, isNull);
      expect(meta.offset, isNull);
      expect(meta.hasGps, isFalse);
    });

    test('writeGps emits exact GPS args with N/E refs', () async {
      final runner = FakeProcessRunner(const ProcResult(0, '', ''));
      final backend = ExiftoolBackend(runner);
      await backend.writeGps('/x/photo.raf', latitude: 48.8584, longitude: 2.2945);

      expect(runner.executable, 'exiftool');
      final args = runner.args!;
      expect(args, contains('-overwrite_original'));
      expect(args, contains('-GPSLatitude=48.8584'));
      expect(args, contains('-GPSLatitudeRef=N'));
      expect(args, contains('-GPSLongitude=2.2945'));
      expect(args, contains('-GPSLongitudeRef=E'));
      expect(args, contains('-GPSMapDatum=WGS-84'));
      expect(args.last, '/x/photo.raf');
    });

    test('writeGps uses S/W refs for negative coordinates', () async {
      final runner = FakeProcessRunner(const ProcResult(0, '', ''));
      final backend = ExiftoolBackend(runner);
      await backend.writeGps('/x/p.raf', latitude: -33.8688, longitude: -70.6693);

      final args = runner.args!;
      expect(args, contains('-GPSLatitude=33.8688'));
      expect(args, contains('-GPSLatitudeRef=S'));
      expect(args, contains('-GPSLongitude=70.6693'));
      expect(args, contains('-GPSLongitudeRef=W'));
    });

    test('writeGps includes date args when dateTimeOriginal given', () async {
      final runner = FakeProcessRunner(const ProcResult(0, '', ''));
      final backend = ExiftoolBackend(runner);
      await backend.writeGps(
        '/x/p.raf',
        latitude: 1,
        longitude: 1,
        dateTimeOriginal: DateTime(2021, 3, 4, 5, 6, 7),
      );

      final args = runner.args!;
      expect(args, contains('-DateTimeOriginal=2021:03:04 05:06:07'));
      expect(args, contains('-CreateDate=2021:03:04 05:06:07'));
    });

    test('writeGps throws StateError on non-zero exit', () async {
      final backend =
          ExiftoolBackend(FakeProcessRunner(const ProcResult(2, '', 'nope')));
      expect(
        () => backend.writeGps('/x/p.raf', latitude: 0, longitude: 0),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('XmpSidecarBackend', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('xmp_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('supports RAW only', () {
      final backend = XmpSidecarBackend();
      expect(backend.supports('/x/a.raf'), isTrue);
      expect(backend.supports('/x/a.png'), isFalse);
    });

    test('writeGps creates parseable XMP sidecar with GPS tags', () async {
      final rawPath = '${dir.path}/DSCF1.RAF';
      final backend = XmpSidecarBackend();
      await backend.writeGps(rawPath, latitude: -33.8688, longitude: 151.2093);

      final sidecar = File('$rawPath.xmp');
      expect(sidecar.existsSync(), isTrue);

      final doc = XmlDocument.parse(sidecar.readAsStringSync());
      final lat = doc.findAllElements('exif:GPSLatitude').single.innerText;
      final lon = doc.findAllElements('exif:GPSLongitude').single.innerText;
      expect(doc.findAllElements('exif:GPSMapDatum').single.innerText, 'WGS-84');
      expect(lat, endsWith('S'));
      expect(lon, endsWith('E'));
      expect(lat, startsWith('33,'));
      expect(lon, startsWith('151,'));
    });

    test('read reports hasGps true when sidecar present', () async {
      final rawPath = '${dir.path}/b.NEF';
      final backend = XmpSidecarBackend();
      await backend.writeGps(rawPath, latitude: 10, longitude: 20);

      final meta = await backend.read(rawPath);
      expect(meta.hasGps, isTrue);
      expect(meta.captureNaive, isNull);
    });

    test('read reports hasGps false with no sidecar', () async {
      final meta = await XmpSidecarBackend().read('${dir.path}/missing.RAF');
      expect(meta.hasGps, isFalse);
    });
  });

  group('PngExifBackend', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('png_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('supports .png only', () {
      const backend = PngExifBackend();
      expect(backend.supports('/x/a.png'), isTrue);
      expect(backend.supports('/x/a.PNG'), isTrue);
      expect(backend.supports('/x/a.jpg'), isFalse);
    });

    test('writeGps then read round-trips GPS within tolerance', () async {
      final path = '${dir.path}/tiny.png';
      File(path).writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));

      const backend = PngExifBackend();
      const lat = -33.8688;
      const lon = 151.2093;
      await backend.writeGps(path, latitude: lat, longitude: lon);

      final meta = await backend.read(path);
      expect(meta.hasGps, isTrue);

      // Verify reconstructed signed coordinates are within 1e-3.
      final image = img.decodePng(File(path).readAsBytesSync())!;
      final exif = _reloadExif(image);
      final g = exif.gpsIfd;
      final signedLat = g.gpsLatitude! * (g.gpsLatitudeRef == 'S' ? -1 : 1);
      final signedLon = g.gpsLongitude! * (g.gpsLongitudeRef == 'W' ? -1 : 1);
      expect(signedLat, closeTo(lat, 1e-3));
      expect(signedLon, closeTo(lon, 1e-3));
    });

    test('read reports hasGps false for PNG without GPS', () async {
      final path = '${dir.path}/plain.png';
      File(path).writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));

      final meta = await const PngExifBackend().read(path);
      expect(meta.hasGps, isFalse);
    });
  });
}

/// Mirrors the backend's tEXt-stored EXIF reload, for assertion in tests.
img.ExifData _reloadExif(img.Image image) {
  final stored = image.textData?['gpsphototag:exif'];
  return img.ExifData.fromInputBuffer(
    img.InputBuffer(base64Decode(stored!)),
  );
}
