import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/engine/onnx_bundle.dart';

void main() {
  test('locateBundledOnnx returns null when no bundle sits next to the '
      'test runner', () {
    // During `flutter test`, Platform.resolvedExecutable is the test host, not a
    // built app bundle, so no vendored ONNX bundle is found alongside it. This
    // exercises the path construction + isComplete(false) -> null branch.
    expect(locateBundledOnnx(), isNull);
  });

  group('onnxBundleDirFor', () {
    test('macOS app-bundle layout', () {
      final dir = onnxBundleDirFor(
        operatingSystem: 'macos',
        exeDir: '/App/Contents/MacOS',
        platformSubdir: 'osx-arm64',
      );
      expect(
        dir,
        '/App/Contents/Frameworks/App.framework/Resources/flutter_assets/'
        'assets/onnx/osx-arm64',
      );
    });

    test('Linux/Windows data/flutter_assets layout', () {
      final dir = onnxBundleDirFor(
        operatingSystem: 'linux',
        exeDir: '/opt/stunda',
        platformSubdir: 'linux-x64',
      );
      expect(dir, '/opt/stunda/data/flutter_assets/assets/onnx/linux-x64');
    });
  });

  group('onnxPlatformSubdir', () {
    test('maps each desktop OS to its assets subdir', () {
      // macOS resolves to an arch-specific dir; assert it is one of the two.
      expect(onnxPlatformSubdir('macos'), anyOf('osx-arm64', 'osx-x64'));
      expect(onnxPlatformSubdir('linux'), 'linux-x64');
      expect(onnxPlatformSubdir('windows'), 'win-x64');
    });

    test('unsupported platforms map to null', () {
      expect(onnxPlatformSubdir('android'), isNull);
      expect(onnxPlatformSubdir('ios'), isNull);
      expect(onnxPlatformSubdir('fuchsia'), isNull);
    });
  });

  group('prepareMobileOnnxBundle', () {
    test('returns null on desktop (the test host is not mobile)', () async {
      // On Android/iOS this copies the models from assets to real files; the
      // test host is desktop, so the early-return path applies.
      expect(await prepareMobileOnnxBundle('/tmp/whatever'), isNull);
    });
  });
}
