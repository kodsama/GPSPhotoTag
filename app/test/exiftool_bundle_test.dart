import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stunda/src/engine/exiftool_bundle.dart';

void main() {
  test('locateBundledExiftool returns null when no bundle sits next to the '
      'test runner', () {
    // During `flutter test`, Platform.resolvedExecutable is the test host, not
    // a built app bundle, so no vendored exiftool is found alongside it. This
    // exercises the path-construction + existsSync(false) -> null branch.
    expect(locateBundledExiftool(), isNull);
  });

  group('exiftoolBundleDirFor', () {
    test('macOS finds the Perl script under the App.framework layout', () {
      final tmp = Directory.systemTemp.createTempSync('et_bundle_macos');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final exeDir = p.join(tmp.path, 'Stunda.app', 'Contents', 'MacOS');
      final bundle = p.normalize(
        p.join(
          exeDir,
          '..',
          'Frameworks',
          'App.framework',
          'Resources',
          'flutter_assets',
          'assets',
          'exiftool',
        ),
      );
      Directory(bundle).createSync(recursive: true);
      File(p.join(bundle, 'exiftool')).writeAsStringSync('#!/usr/bin/perl');

      final dir = exiftoolBundleDirFor(
        operatingSystem: 'macos',
        exeDir: exeDir,
      );
      expect(dir, bundle);
    });

    test('Linux finds the Perl script under data/flutter_assets', () {
      final tmp = Directory.systemTemp.createTempSync('et_bundle_linux');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final exeDir = p.join(tmp.path, 'bin');
      final bundle = p.join(
        exeDir,
        'data',
        'flutter_assets',
        'assets',
        'exiftool',
      );
      Directory(bundle).createSync(recursive: true);
      File(p.join(bundle, 'exiftool')).writeAsStringSync('#!/usr/bin/perl');

      final dir = exiftoolBundleDirFor(
        operatingSystem: 'linux',
        exeDir: exeDir,
      );
      expect(dir, p.normalize(bundle));
    });

    test('Windows resolves the windows/ subdir holding exiftool.exe', () {
      final tmp = Directory.systemTemp.createTempSync('et_bundle_win');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final exeDir = p.join(tmp.path, 'app');
      final bundle = p.join(
        exeDir,
        'data',
        'flutter_assets',
        'assets',
        'exiftool',
        'windows',
      );
      Directory(bundle).createSync(recursive: true);
      File(p.join(bundle, 'exiftool.exe')).writeAsStringSync('MZ');

      final dir = exiftoolBundleDirFor(
        operatingSystem: 'windows',
        exeDir: exeDir,
      );
      expect(dir, p.normalize(bundle));
    });

    test('returns null when the expected executable is absent', () {
      final tmp = Directory.systemTemp.createTempSync('et_bundle_missing');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // No files created; the existsSync probe must fail and yield null.
      expect(
        exiftoolBundleDirFor(operatingSystem: 'linux', exeDir: tmp.path),
        isNull,
      );
      expect(
        exiftoolBundleDirFor(operatingSystem: 'windows', exeDir: tmp.path),
        isNull,
      );
    });
  });
}
