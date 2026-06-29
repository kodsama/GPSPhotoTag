@TestOn('vm')
library;

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// Integration test for the native ONNX Runtime embedding path: it runs the REAL
/// [OrtImageEmbedder] against the bundled library + MobileNetV2 model on real
/// photos, so the float32-NCHW dart:ffi code in ort_session.dart is genuinely
/// exercised.
///
/// The bundle dir is taken from `$STUNDA_ONNX_BUNDLE_DIR`, or the repo's
/// `app/assets/onnx/<platform>/` populated by tool/fetch-onnx.sh. When no bundle
/// is present the group is skipped so the suite stays green without the assets;
/// CI runs the fetch step so this runs.
void main() {
  final bundleDir = _resolveBundleDir();
  final available =
      bundleDir != null &&
      (resolveEmbeddingBundle(bundleDir)?.isComplete ?? false);

  group(
    'OrtImageEmbedder (native ORT inference)',
    () {
      late OrtImageEmbedder embedder;

      setUpAll(() {
        embedder = OrtImageEmbedder.fromBundleDir(bundleDir);
      });
      tearDownAll(() => embedder.close());

      test('loads the bundled lib + model and reports available', () {
        expect(embedder.isAvailable, isTrue);
      });

      test('produces an L2-normalized 1000-d vector for a photo', () async {
        final decoded = img.decodeImage(
          File(_fixture('person.jpg')).readAsBytesSync(),
        )!;
        final vec = await embedder.embedDecoded(decoded);
        expect(vec, isNotNull);
        expect(vec!.length, 1000);
        var sumSq = 0.0;
        for (final v in vec) {
          sumSq += v * v;
        }
        expect(sumSq, closeTo(1.0, 1e-4)); // unit length
      });

      test('the same image embeds to itself with cosine ~1', () async {
        final decoded = img.decodeImage(
          File(_fixture('dog.jpg')).readAsBytesSync(),
        )!;
        final a = (await embedder.embedDecoded(decoded))!;
        final b = (await embedder.embedDecoded(decoded))!;
        expect(cosineSimilarity(a, b), closeTo(1.0, 1e-4));
      });

      test('two different photos are less similar than a self-match', () async {
        final person = img.decodeImage(
          File(_fixture('person.jpg')).readAsBytesSync(),
        )!;
        final dog = img.decodeImage(
          File(_fixture('dog.jpg')).readAsBytesSync(),
        )!;
        final pv = (await embedder.embedDecoded(person))!;
        final dv = (await embedder.embedDecoded(dog))!;
        // Distinct subjects: the cross-cosine is well below a perfect self-match.
        expect(cosineSimilarity(pv, dv), lessThan(0.999));
      });

      test('a real lib but a corrupt model → caught, embedder unavailable', () {
        final tmp = Directory.systemTemp.createTempSync('embed_badmodel');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final realBundle = resolveEmbeddingBundle(bundleDir)!;
        final libName = p.basename(realBundle.libraryPath);
        File(realBundle.libraryPath).copySync(p.join(tmp.path, libName));
        File(
          p.join(tmp.path, kEmbeddingModelFileName),
        ).writeAsStringSync('not a real onnx model');

        final bad = OrtImageEmbedder.fromBundleDir(tmp.path);
        expect(bad.isAvailable, isFalse);
        bad.close();
      });

      test('an undecodable (1x1) image still embeds without throwing', () async {
        // The model resizes any input to 224×224, so even a tiny image embeds.
        final tiny = img.Image(width: 1, height: 1);
        final vec = await embedder.embedDecoded(tiny);
        expect(vec, isNotNull);
        expect(vec!.length, 1000);
      });
    },
    skip: available ? false : 'no ONNX bundle (run tool/fetch-onnx.sh)',
  );

  // Exercise the float runEmbedding tensor path is covered above; also keep a
  // tiny guard that an unavailable embedder is total when the model is absent.
  test('an unavailable embedder is total (null bundle)', () async {
    final e = OrtImageEmbedder.fromBundleDir(null);
    expect(e.isAvailable, isFalse);
    expect(await e.embedDecoded(img.Image(width: 8, height: 8)), isNull);
    e.close();
  });
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
/// `app/assets/onnx/<platform>/` created by tool/fetch-onnx.sh.
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
