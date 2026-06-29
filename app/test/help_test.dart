import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/i18n/app_localizations.dart';
import 'package:stunda/src/widgets/help.dart';

void main() {
  group('help sections data', () {
    test('there is at least one section', () {
      expect(kHelpSections, isNotEmpty);
    });

    test('every section has a heading and at least one body line', () {
      for (final section in kHelpSections) {
        expect(section.titleKey, isNotEmpty);
        expect(
          section.bodyKeys,
          isNotEmpty,
          reason: '${section.titleKey} has no body lines',
        );
      }
    });

    test('every referenced key exists in the English strings', () {
      for (final section in kHelpSections) {
        expect(
          kEnglishStrings.containsKey(section.titleKey),
          isTrue,
          reason: 'missing English string for ${section.titleKey}',
        );
        for (final bodyKey in section.bodyKeys) {
          expect(
            kEnglishStrings.containsKey(bodyKey),
            isTrue,
            reason: 'missing English string for $bodyKey',
          );
        }
      }
    });

    test('the page-level title and intro keys exist', () {
      expect(kEnglishStrings.containsKey('help_title'), isTrue);
      expect(kEnglishStrings.containsKey('help_intro'), isTrue);
      expect(kEnglishStrings.containsKey('menu_help'), isTrue);
    });
  });
}
