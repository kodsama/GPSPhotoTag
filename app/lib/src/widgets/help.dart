/// An in-app Help page: a scrollable, sectioned guide to every feature, reached
/// from the Settings overflow menu. Each section is data — a title key plus a
/// list of body keys — so the structure is unit-testable and every string is
/// localized through `context.tr`.
///
/// The page can be opened at a specific section ([showHelp] with a `section`):
/// each section carries a stable [HelpSection.key] anchor, and the page scrolls
/// it into view on open. The contextual "What's this?" help mode (see
/// `HelpTarget`) maps a tapped control's topic to a section via [sectionForTopic]
/// and opens the page there.
library;

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../state/controller_scope.dart';
import '../state/library_action.dart';

/// One Help section: a stable anchor key, a heading, and a few short body
/// paragraphs/bullet lines, all referenced by i18n key.
class HelpSection {
  /// Creates a section from its stable [key] anchor and localization keys.
  const HelpSection(this.key, this.titleKey, this.bodyKeys);

  /// Stable anchor identifier for open-at-section (independent of i18n keys).
  final String key;

  /// Localization key for the section heading.
  final String titleKey;

  /// Localization keys for the section's body lines (paragraphs).
  final List<String> bodyKeys;
}

/// The ordered Help sections. Kept as data so a unit test can assert the list is
/// non-empty and every referenced key exists in the English strings (guarding
/// against a heading or paragraph that was never translated).
const List<HelpSection> kHelpSections = [
  HelpSection('getting_started', 'help_getting_started_title', [
    'help_getting_started_b1',
    'help_getting_started_b2',
    'help_getting_started_b3',
  ]),
  HelpSection('tag', 'help_tag_title', [
    'help_tag_b1',
    'help_tag_b2',
    'help_tag_b3',
  ]),
  HelpSection('explore', 'help_explore_title', [
    'help_explore_b1',
    'help_explore_b2',
    'help_explore_b3',
  ]),
  HelpSection('match', 'help_match_title', ['help_match_b1', 'help_match_b2']),
  HelpSection('duplicates', 'help_duplicates_title', [
    'help_duplicates_b1',
    'help_duplicates_b2',
    'help_duplicates_b3',
  ]),
  HelpSection('compare', 'help_compare_title', [
    'help_compare_b1',
    'help_compare_b2',
  ]),
  HelpSection('shrink', 'help_shrink_title', [
    'help_shrink_b1',
    'help_shrink_b2',
    'help_shrink_b3',
  ]),
  HelpSection('settings', 'help_settings_title', [
    'help_settings_b1',
    'help_settings_b2',
  ]),
  HelpSection('safety', 'help_safety_title', [
    'help_safety_b1',
    'help_safety_b2',
  ]),
  HelpSection('power', 'help_power_title', ['help_power_b1']),
];

/// A contextual-help topic a tagged control carries. Each maps to exactly one
/// Help [HelpSection] via [sectionForTopic], so a "What's this?" tap on the
/// control opens the page at the relevant explanation.
enum HelpTopic {
  /// The Tag-with-GPS action (card + its controls).
  tag,

  /// The Explore-on-map action (card + map controls).
  explore,

  /// The Match-Images-to-RAW action (card + direction toggle).
  match,

  /// The Find-duplicates action (card + similarity/keep/metric controls).
  duplicates,

  /// The Shrink-library wizard (card + stages).
  shrink,

  /// The app Settings (gear menu + dialog items).
  settings,
}

/// The contextual-help [HelpTopic] for a workspace [action], so an action card
/// can be wrapped in a [HelpTarget] mapping to the right Help section. Pure so
/// the routing is unit-testable.
HelpTopic topicForAction(LibraryAction action) => switch (action) {
  LibraryAction.tag => HelpTopic.tag,
  LibraryAction.explore => HelpTopic.explore,
  LibraryAction.pruneRaw => HelpTopic.match,
  LibraryAction.duplicates => HelpTopic.duplicates,
  LibraryAction.shrink => HelpTopic.shrink,
};

/// The Help [HelpSection.key] anchor a [topic] opens to. Pure so the topic →
/// section routing is unit-testable without a widget tree.
String sectionForTopic(HelpTopic topic) => switch (topic) {
  HelpTopic.tag => 'tag',
  HelpTopic.explore => 'explore',
  HelpTopic.match => 'match',
  HelpTopic.duplicates => 'duplicates',
  HelpTopic.shrink => 'shrink',
  HelpTopic.settings => 'settings',
};

/// Wraps a control so that, while contextual help mode is active, a click on it
/// opens the Help page at the control's [topic] section INSTEAD of triggering
/// the control's own action (the tap is absorbed and help mode is exited). When
/// help mode is off it is transparent — the [child] behaves exactly as normal.
class HelpTarget extends StatelessWidget {
  /// Wraps [child], routing help-mode taps to the Help section for [topic].
  const HelpTarget({super.key, required this.topic, required this.child});

  /// Which Help section a help-mode tap on this control opens.
  final HelpTopic topic;

  /// The control being tagged.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    if (!controller.helpMode) return child;
    // Help mode on: intercept the tap, absorb the underlying control's gesture,
    // exit help mode (one-use), and open Help at this control's section.
    return Stack(
      children: [
        // The child is still painted (so the surface looks unchanged) but its
        // pointer events are swallowed by the overlay above it.
        IgnorePointer(child: child),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              controller.exitHelpMode();
              showHelp(context, section: sectionForTopic(topic));
            },
            child: MouseRegion(cursor: SystemMouseCursors.help),
          ),
        ),
      ],
    );
  }
}

/// Opens the Help page, optionally scrolled to the [section] anchor (a
/// [HelpSection.key]). An unknown or null section opens at the top.
void showHelp(BuildContext context, {String? section}) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => HelpPage(section: section)));
}

/// Scrollable, sectioned Help screen.
class HelpPage extends StatefulWidget {
  /// Creates the Help page, optionally opening at the [section] anchor.
  const HelpPage({super.key, this.section});

  /// A [HelpSection.key] to scroll into view once laid out, or null for the top.
  final String? section;

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  // A key per section so we can scroll the requested one into view on open.
  final Map<String, GlobalKey> _anchors = {
    for (final section in kHelpSections) section.key: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    final target = widget.section;
    if (target != null && _anchors.containsKey(target)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _anchors[target]!.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 300),
            alignment: 0.05,
          );
        }
      });
    }
  }

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
            Text(
              context.tr(section.titleKey),
              key: _anchors[section.key],
              style: text.titleLarge,
            ),
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
