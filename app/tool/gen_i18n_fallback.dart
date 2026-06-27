/// Regenerates `lib/src/i18n/app_strings.g.dart` from `assets/i18n/en.json`.
///
/// The generated file is the compile-time English fallback for
/// `AppLocalizations.tr`. Run after editing `en.json`:
///
///   dart run tool/gen_i18n_fallback.dart
library;

import 'dart:convert';
import 'dart:io';

void main() {
  final json =
      jsonDecode(File('assets/i18n/en.json').readAsStringSync())
          as Map<String, dynamic>;
  final buf = StringBuffer()
    ..writeln('// GENERATED from assets/i18n/en.json — do not edit by hand.')
    ..writeln('// Regenerate with: dart run tool/gen_i18n_fallback.dart')
    ..writeln('//')
    ..writeln(
      '// The compile-time English fallback for AppLocalizations.tr, so a lookup is',
    )
    ..writeln(
      '// always English-correct synchronously even before the JSON asset loads or',
    )
    ..writeln(
      '// when no localizations delegate is in scope (e.g. bare-MaterialApp tests).',
    )
    ..writeln('library;')
    ..writeln()
    ..writeln(
      '/// English strings, the source of truth and fallback for every locale.',
    )
    ..writeln('const Map<String, String> kEnglishStrings = {');
  json.forEach((key, value) {
    final escaped = (value as String)
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n');
    buf.writeln("  '$key': '$escaped',");
  });
  buf.writeln('};');
  File('lib/src/i18n/app_strings.g.dart').writeAsStringSync(buf.toString());
  stdout.writeln(
    'Wrote ${json.length} keys to lib/src/i18n/app_strings.g.dart',
  );
}
