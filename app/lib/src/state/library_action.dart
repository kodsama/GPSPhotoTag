import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

/// A translator: a localization key (+ optional params) → the resolved string.
/// The widget layer supplies `context.tr`, keeping these models Flutter-free of
/// any `BuildContext`.
typedef Translator =
    String Function(String key, [Map<String, Object?>? params]);

/// Whether an action can run against the current library, plus a short reason.
///
/// [labelKey]/[labelParams] resolve (via a [Translator]) to the action card's
/// readiness chip text ("Ready — 3 sources", "No GPS sources found"). When
/// [enabled] is false the card is disabled.
@immutable
class ActionReadiness {
  /// Creates a readiness verdict from a localization [labelKey] + [labelParams].
  const ActionReadiness({
    required this.enabled,
    required this.labelKey,
    this.labelParams,
  });

  /// A ready verdict with [labelKey].
  const ActionReadiness.ready(String labelKey, {Map<String, Object?>? params})
    : this(enabled: true, labelKey: labelKey, labelParams: params);

  /// A blocked verdict with [labelKey] explaining why.
  const ActionReadiness.blocked(String labelKey, {Map<String, Object?>? params})
    : this(enabled: false, labelKey: labelKey, labelParams: params);

  /// Whether the action may run.
  final bool enabled;

  /// The localization key for the readiness chip text.
  final String labelKey;

  /// Interpolation params for [labelKey], or null.
  final Map<String, Object?>? labelParams;

  /// Resolves the chip text via [tr].
  String label(Translator tr) => tr(labelKey, labelParams);
}

/// A single thing the user can do with a scanned library.
///
/// Adding a future action is one entry in [LibraryAction.all]: give it an [id],
/// an [icon], a [title], a one-line [description], and a [readiness] function
/// over the [FolderScanResult]. The workspace grid, the action screen header,
/// and routing all read from this list — no other code changes.
enum LibraryAction {
  /// Write GPS coordinates into photos from the scanned tracks & history.
  tag(
    id: 'tag',
    icon: Icons.place_outlined,
    titleKey: 'action_tag_title',
    descKey: 'action_tag_desc',
  ),

  /// Open a live, pannable/zoomable world map of the geotagged photos.
  explore(
    id: 'explore',
    icon: Icons.travel_explore,
    titleKey: 'action_explore_title',
    descKey: 'action_explore_desc',
  ),

  /// Match images to RAW: trash orphan RAWs or orphan images (the review's
  /// direction toggle picks which side).
  pruneRaw(
    id: 'prune_raw',
    icon: Icons.cleaning_services_outlined,
    titleKey: 'action_prune_title',
    descKey: 'action_prune_desc',
  ),

  /// Find visually-similar photos (perceptual hashing) and trash duplicates.
  duplicates(
    id: 'duplicates',
    icon: Icons.filter_none,
    titleKey: 'action_duplicates_title',
    descKey: 'action_duplicates_desc',
  ),

  /// A guided wizard that shrinks the library by trashing duplicate, orphan,
  /// redundant, and low-quality photos in opt-in stages.
  shrink(
    id: 'shrink',
    icon: Icons.compress,
    titleKey: 'action_shrink_title',
    descKey: 'action_shrink_desc',
  );

  const LibraryAction({
    required this.id,
    required this.icon,
    required this.titleKey,
    required this.descKey,
  });

  /// Stable identifier (also used for analytics / routing).
  final String id;

  /// Card icon.
  final IconData icon;

  /// Localization key for the card title.
  final String titleKey;

  /// Localization key for the one-line neutral description (says photos are
  /// *used*, never "tagged").
  final String descKey;

  /// The localized card title via [tr].
  String title(Translator tr) => tr(titleKey);

  /// The localized card description via [tr].
  String description(Translator tr) => tr(descKey);

  /// Every action, in display order. Add a new action here and it appears.
  static const List<LibraryAction> all = values;

  /// Computes whether this action can run against [scan].
  ActionReadiness readiness(FolderScanResult scan) => switch (this) {
    LibraryAction.tag => _tagReadiness(scan),
    LibraryAction.explore =>
      scan.photoCount > 0
          ? ActionReadiness.ready(
              'readiness_photos',
              params: {'count': scan.photoCount},
            )
          : const ActionReadiness.blocked('readiness_explore_none'),
    LibraryAction.pruneRaw =>
      _rawCount(scan) > 0
          ? ActionReadiness.ready(
              'readiness_raw_files',
              params: {'count': _rawCount(scan)},
            )
          : const ActionReadiness.blocked('readiness_raw_none'),
    LibraryAction.duplicates =>
      scan.photoCount > 1
          ? ActionReadiness.ready(
              'readiness_photos',
              params: {'count': scan.photoCount},
            )
          : const ActionReadiness.blocked('readiness_need_two'),
    LibraryAction.shrink =>
      scan.photoCount > 0
          ? ActionReadiness.ready(
              'readiness_photos',
              params: {'count': scan.photoCount},
            )
          : const ActionReadiness.blocked('readiness_explore_none'),
  };

  static ActionReadiness _tagReadiness(FolderScanResult scan) {
    final sources = scan.trackCount + scan.googleCount;
    if (sources == 0) {
      return const ActionReadiness.blocked('readiness_tag_none');
    }
    return ActionReadiness.ready(
      sources == 1 ? 'readiness_tag_ready_one' : 'readiness_tag_ready_many',
      params: {'count': sources},
    );
  }

  /// Number of scanned photos whose extension is a RAW format.
  static int _rawCount(FolderScanResult scan) {
    var n = 0;
    scan.photosByFormat.forEach((ext, count) {
      if (PhotoFormats.raw.contains(ext)) n += count;
    });
    return n;
  }
}
