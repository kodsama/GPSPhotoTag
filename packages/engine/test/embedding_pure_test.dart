import 'package:image/image.dart' as img;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

void main() {
  group('resolveEmbeddingBundle', () {
    test('null bundle dir resolves to null', () {
      expect(resolveEmbeddingBundle(null), isNull);
    });

    test('unsupported platform resolves to null', () {
      expect(resolveEmbeddingBundle('/x', operatingSystem: 'fuchsia'), isNull);
    });

    test('builds the lib + embedding model paths under the bundle dir', () {
      final bundle = resolveEmbeddingBundle(
        '/bundle',
        operatingSystem: 'linux',
      )!;
      expect(bundle.libraryPath, '/bundle/libonnxruntime.so');
      expect(bundle.modelPath, '/bundle/$kEmbeddingModelFileName');
    });

    test('uses a different model file than the detector bundle', () {
      expect(kEmbeddingModelFileName, isNot(kOnnxModelFileName));
      final embed = resolveEmbeddingBundle('/b', operatingSystem: 'macos')!;
      final detect = resolveOnnxBundle('/b', operatingSystem: 'macos')!;
      expect(embed.libraryPath, detect.libraryPath); // shared ORT library
      expect(embed.modelPath, isNot(detect.modelPath));
    });

    test('isComplete is false when files are absent', () {
      final bundle = resolveEmbeddingBundle(
        '/definitely/not/here',
        operatingSystem: 'macos',
      )!;
      expect(bundle.isComplete, isFalse);
    });
  });

  group('NoopImageEmbedder', () {
    const embedder = NoopImageEmbedder();

    test('reports itself unavailable', () {
      expect(embedder.isAvailable, isFalse);
    });

    test('embeds nothing (always null)', () async {
      expect(
        await embedder.embedDecoded(img.Image(width: 4, height: 4)),
        isNull,
      );
    });
  });

  group('OrtImageEmbedder (no bundle → unavailable, total)', () {
    test('null bundle dir → unavailable, embeds null', () async {
      final e = OrtImageEmbedder.fromBundleDir(null);
      expect(e.isAvailable, isFalse);
      expect(await e.embedDecoded(img.Image(width: 4, height: 4)), isNull);
      e.close(); // idempotent / safe when unavailable
      e.close();
    });

    test('missing files → unavailable', () {
      final e = OrtImageEmbedder.fromBundleDir(
        '/no/such/bundle',
        operatingSystem: 'macos',
      );
      expect(e.isAvailable, isFalse);
    });
  });
}
