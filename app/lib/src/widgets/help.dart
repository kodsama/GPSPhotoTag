/// An in-app Help page: a scrollable, sectioned guide to every feature, reached
/// from the Settings overflow menu. Each section is data — a title key plus a
/// list of body keys — so the structure is unit-testable and every string is
/// localized through `context.tr`.
library;

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';

/// One Help section: a heading and a few short body paragraphs/bullet lines,
/// all referenced by i18n key.
class HelpSection {
  /// Creates a section from its localization keys.
  const HelpSection(this.titleKey, this.bodyKeys);

  /// Localization key for the section heading.
  final String titleKey;

  /// Localization keys for the section's body lines (paragraphs).
  final List<String> bodyKeys;
}

/// The ordered Help sections. Kept as data so a unit test can assert the list is
/// non-empty and every referenced key exists in the English strings (guarding
/// against a heading or paragraph that was never translated).
const List<HelpSection> kHelpSections = [
  HelpSection('help_getting_started_title', [
    'help_getting_started_b1',
    'help_getting_started_b2',
    'help_getting_started_b3',
  ]),
  HelpSection('help_tag_title', ['help_tag_b1', 'help_tag_b2', 'help_tag_b3']),
  HelpSection('help_explore_title', [
    'help_explore_b1',
    'help_explore_b2',
    'help_explore_b3',
  ]),
  HelpSection('help_match_title', ['help_match_b1', 'help_match_b2']),
  HelpSection('help_duplicates_title', [
    'help_duplicates_b1',
    'help_duplicates_b2',
    'help_duplicates_b3',
  ]),
  HelpSection('help_compare_title', ['help_compare_b1', 'help_compare_b2']),
  HelpSection('help_shrink_title', [
    'help_shrink_b1',
    'help_shrink_b2',
    'help_shrink_b3',
  ]),
  HelpSection('help_settings_title', ['help_settings_b1', 'help_settings_b2']),
  HelpSection('help_safety_title', ['help_safety_b1', 'help_safety_b2']),
  HelpSection('help_power_title', ['help_power_b1']),
];

/// Opens the Help page.
void showHelp(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const HelpPage()));
}

/// Scrollable, sectioned Help screen.
class HelpPage extends StatelessWidget {
  /// Creates the Help page.
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('help_title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(context.tr('help_intro'), style: text.bodyMedium),
          const SizedBox(height: 24),
          for (final section in kHelpSections) ...[
            Text(context.tr(section.titleKey), style: text.titleLarge),
            const SizedBox(height: 8),
            for (final bodyKey in section.bodyKeys)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  context.tr(bodyKey),
                  style: text.bodyMedium?.copyWith(
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}
