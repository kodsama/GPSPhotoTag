import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/engine/exiftool_bundle.dart';

void main() {
  test('locateBundledExiftool returns null when no bundle sits next to the '
      'test runner', () {
    // During `flutter test`, Platform.resolvedExecutable is the test host, not
    // a built app bundle, so no vendored exiftool is found alongside it. This
    // exercises the path-construction + existsSync(false) -> null branch.
    expect(locateBundledExiftool(), isNull);
  });
}
