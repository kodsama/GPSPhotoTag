import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

/// Whether an action can run against the current library, plus a short reason.
///
/// [label] is shown in the action card's readiness chip ("Ready — 3 sources",
/// "No GPS sources found"). When [enabled] is false the card is disabled.
@immutable
class ActionReadiness {
  /// Creates a readiness verdict.
  const ActionReadiness({required this.enabled, required this.label});

  /// A ready verdict with [label].
  const ActionReadiness.ready(String label) : this(enabled: true, label: label);

  /// A blocked verdict with [label] explaining why.
  const ActionReadiness.blocked(String label)
    : this(enabled: false, label: label);

  /// Whether the action may run.
  final bool enabled;

  /// One-line readiness text for the card chip.
  final String label;
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
    title: 'Tag with GPS',
    description:
        'Write location into your photos from the tracks & history '
        'found.',
  ),

  /// Open a live, pannable/zoomable world map of the geotagged photos.
  explore(
    id: 'explore',
    icon: Icons.travel_explore,
    title: 'Explore on map',
    description: 'Browse your geotagged photos on a live, zoomable map.',
  ),

  /// Match images to RAW: trash orphan RAWs or orphan images (the review's
  /// direction toggle picks which side).
  pruneRaw(
    id: 'prune_raw',
    icon: Icons.cleaning_services_outlined,
    title: 'Match Images to RAW',
    description: 'Trash RAW files or photos that have no matching partner.',
  ),

  /// Find visually-similar photos (perceptual hashing) and trash duplicates.
  duplicates(
    id: 'duplicates',
    icon: Icons.filter_none,
    title: 'Find duplicates',
    description: 'Spot visually-similar photos and trash the extras.',
  );

  const LibraryAction({
    required this.id,
    required this.icon,
    required this.title,
    required this.description,
  });

  /// Stable identifier (also used for analytics / routing).
  final String id;

  /// Card icon.
  final IconData icon;

  /// Card title.
  final String title;

  /// One-line neutral description (says photos are *used*, never "tagged").
  final String description;

  /// Every action, in display order. Add a new action here and it appears.
  static const List<LibraryAction> all = values;

  /// Computes whether this action can run against [scan].
  ActionReadiness readiness(FolderScanResult scan) => switch (this) {
    LibraryAction.tag => _tagReadiness(scan),
    LibraryAction.explore =>
      scan.photoCount > 0
          ? ActionReadiness.ready('${scan.photoCount} photos')
          : const ActionReadiness.blocked('No photos found'),
    LibraryAction.pruneRaw =>
      _rawCount(scan) > 0
          ? ActionReadiness.ready('${_rawCount(scan)} RAW files')
          : const ActionReadiness.blocked('No RAW files found'),
    LibraryAction.duplicates =>
      scan.photoCount > 1
          ? ActionReadiness.ready('${scan.photoCount} photos')
          : const ActionReadiness.blocked('Need at least 2 photos'),
  };

  static ActionReadiness _tagReadiness(FolderScanResult scan) {
    final sources = scan.trackCount + scan.googleCount;
    return sources > 0
        ? ActionReadiness.ready(
            'Ready — $sources ${sources == 1 ? 'source' : 'sources'}',
          )
        : const ActionReadiness.blocked('No GPS sources found');
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
