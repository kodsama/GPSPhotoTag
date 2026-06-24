/// The ordered stages of the GPSPhotoTag walkthrough.
///
/// Each step renders as a collapsible card; exactly one is active (expanded) at
/// a time and earlier completed steps collapse to a single tappable row.
enum WizardStep {
  /// Probe the machine for optional external tools (exiftool, libheif).
  toolkit('Toolkit', 'Check the optional tools that unlock RAW & HEIC.'),

  /// Pick the folder of photos to tag.
  input('Photos', 'Choose the folder of photos to geotag.'),

  /// Review the parsed summary and include/exclude items.
  review('Review', 'Confirm what was found and what will be tagged.'),

  /// Configure all tag options.
  options('Options', 'Tune how GPS is written into your photos.'),

  /// Choose the output destination.
  output('Output', 'Write in place, or copy tagged files elsewhere.'),

  /// Run the tag operation.
  run('Run', 'Tag the selected photos and watch the progress.'),

  /// Show the result summary and follow-up actions.
  result('Done', 'Review the outcome and run follow-up tools.');

  const WizardStep(this.title, this.subtitle);

  /// Short card heading.
  final String title;

  /// One-line description shown under the heading.
  final String subtitle;

  /// 1-based position used for the numbered badge.
  int get number => index + 1;
}

/// Convenience helpers over the [WizardStep] order.
extension WizardStepOrder on WizardStep {
  /// The next step, or null when this is the last one.
  WizardStep? get next {
    final all = WizardStep.values;
    return index + 1 < all.length ? all[index + 1] : null;
  }

  /// Whether this step comes strictly before [other].
  bool isBefore(WizardStep other) => index < other.index;
}
