@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// Integration test for the native ONNX Runtime path: it runs the REAL
/// [OrtPeopleDetector] against the bundled library + model on real photos, so
/// the dart:ffi code in ort_session.dart is genuinely exercised.
///
/// The bundle dir is taken from `$STUNDA_ONNX_BUNDLE_DIR`, or the repo's
/// `app/assets/onnx/<platform>/` populated by tool/fetch-onnx.sh. When no bundle
/// is present (a dev who hasn't fetched the assets) the test group is skipped so
/// the suite stays green on Tier-1 alone; CI runs the fetch step so this runs.
void main() {
  final bundleDir = _resolveBundleDir();
  final available =
      bundleDir != null && (resolveOnnxBundle(bundleDir)?.isComplete ?? false);

  group(
    'OrtPeopleDetector (native ORT inference)',
    () {
      late OrtPeopleDetector detector;

      setUpAll(() {
        detector = OrtPeopleDetector.fromBundleDir(bundleDir);
      });
      tearDownAll(() => detector.close());

      test('loads the bundled lib + model and reports available', () {
        expect(detector.isAvailable, isTrue);
      });

      test('scores a photo of a person high', () async {
        final bytes = File(_fixture('person.jpg')).readAsBytesSync();
        final score = await detector.scoreImage(bytes);
        expect(score, isNotNull);
        expect(score, greaterThan(0.5));
      });

      test('scores a photo of a dog (animal) high via scoreDecoded', () async {
        final decoded = img.decodeImage(
          File(_fixture('dog.jpg')).readAsBytesSync(),
        )!;
        final score = await detector.scoreDecoded(decoded);
        expect(score, isNotNull);
        expect(score, greaterThan(0.5));
      });

      test('scores a blank image ~0', () async {
        final blank = img.Image(width: 300, height: 300);
        img.fill(blank, color: img.ColorRgb8(128, 128, 128));
        final score = await detector.scoreDecoded(blank);
        expect(score, 0);
      });

      test('undecodable bytes → null (total, never throws)', () async {
        final score = await detector.scoreImage(
          Uint8List.fromList([0, 1, 2, 3, 4]), // not an image
        );
        expect(score, isNull);
      });

      test(
        'a real lib but a corrupt model → OrtException is caught, unavailable',
        () {
          // Build a bundle with the REAL ORT library but a bogus model file, so
          // CreateSession returns a non-null OrtStatus: check() reads the error
          // message and throws OrtException, which fromBundleDir catches.
          final tmp = Directory.systemTemp.createTempSync('ort_badmodel');
          addTearDown(() => tmp.deleteSync(recursive: true));
          final realBundle = resolveOnnxBundle(bundleDir)!;
          final libName = p.basename(realBundle.libraryPath);
          File(realBundle.libraryPath).copySync(p.join(tmp.path, libName));
          File(
            p.join(tmp.path, kOnnxModelFileName),
          ).writeAsStringSync('not a real onnx model');

          final bad = OrtPeopleDetector.fromBundleDir(tmp.path);
          expect(bad.isAvailable, isFalse);
          bad.close();
        },
      );
    },
    skip: available ? false : 'no ONNX bundle (run tool/fetch-onnx.sh)',
  );
}

/// The test's image fixtures. Tries the package-root cwd first (how CI runs),
/// then the repo-root cwd, so it resolves either way.
String _fixture(String name) {
  for (final base in const [
    ['test', 'fixtures'],
    ['packages', 'engine', 'test', 'fixtures'],
  ]) {
    final path = p.joinAll([Directory.current.path, ...base, name]);
    if (File(path).existsSync()) return path;
  }
  return p.join('test', 'fixtures', name);
}

/// Resolves the ONNX bundle dir: the env override, else the repo's
/// `app/assets/onnx/<platform>/` created by tool/fetch-onnx.sh. The repo root is
/// found by walking up from the working directory until app/assets/onnx exists,
/// so the test works whether cwd is the repo root or the engine package.
String? _resolveBundleDir() {
  final env = Platform.environment['STUNDA_ONNX_BUNDLE_DIR'];
  if (env != null && env.isNotEmpty) return env;
  final platform = _platformDir();
  if (platform == null) return null;
  var dir = Directory.current.absolute.path;
  for (var i = 0; i < 6; i++) {
    final candidate = p.join(dir, 'app', 'assets', 'onnx', platform);
    if (Directory(candidate).existsSync()) return candidate;
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}

/// The platform asset subdir name used by tool/fetch-onnx.sh, or null.
String? _platformDir() {
  if (Platform.isMacOS) {
    return Platform.version.contains('arm64') ? 'osx-arm64' : 'osx-x64';
  }
  if (Platform.isLinux) return 'linux-x64';
  if (Platform.isWindows) return 'win-x64';
  return null;
}
