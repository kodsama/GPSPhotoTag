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

  /// Every action, in display order (Explore first). Add a new action here and
  /// it appears.
  static const List<LibraryAction> all = [
    LibraryAction.explore,
    LibraryAction.tag,
    LibraryAction.pruneRaw,
    LibraryAction.duplicates,
    LibraryAction.shrink,
  ];

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

/// The user's home-screen action configuration: an ORDER (a permutation of the
/// [LibraryAction] values) plus a hidden flag per action. Pure and immutable so
/// the ordering/visibility logic and its (de)serialization are unit-testable
/// without Flutter; mirrors the `KeepPipeline` pattern.
///
/// The default is [LibraryAction.all]'s order (Explore first) with everything
/// visible. (De)serialization is tolerant: unknown action ids are dropped, and
/// any action missing from a saved order is appended VISIBLE in its canonical
/// order — so adding a new [LibraryAction] later still shows for existing users.
@immutable
class HomeActionsConfig {
  /// Creates a config from an explicit [order] and [hidden] set. Callers should
  /// prefer [HomeActionsConfig.normalized] (or [fromJson]) so the order is
  /// guaranteed to be a complete, deduped permutation of every action.
  const HomeActionsConfig({required this.order, required this.hidden});

  /// The default: the canonical order (Explore first), all visible.
  static const HomeActionsConfig standard = HomeActionsConfig(
    order: LibraryAction.all,
    hidden: <LibraryAction>{},
  );

  /// The actions in display order (a permutation of every [LibraryAction]).
  final List<LibraryAction> order;

  /// The actions the user has hidden from the workspace grid.
  final Set<LibraryAction> hidden;

  /// Builds a config from any [order] (possibly partial / with duplicates) and
  /// [hidden] set: duplicates are dropped, and any action absent from [order] is
  /// appended in its canonical [LibraryAction.all] order, so the result always
  /// covers every action exactly once.
  factory HomeActionsConfig.normalized({
    required Iterable<LibraryAction> order,
    required Iterable<LibraryAction> hidden,
  }) {
    final seen = <LibraryAction>{};
    final result = <LibraryAction>[];
    for (final action in order) {
      if (seen.add(action)) result.add(action);
    }
    for (final action in LibraryAction.all) {
      if (seen.add(action)) result.add(action);
    }
    return HomeActionsConfig(
      order: List.unmodifiable(result),
      hidden: Set.unmodifiable(hidden.where(LibraryAction.all.contains)),
    );
  }

  /// Whether [action] is currently visible (not hidden).
  bool isVisible(LibraryAction action) => !hidden.contains(action);

  /// The ordered, visible-only actions — what the workspace grid renders.
  List<LibraryAction> get visibleInOrder => [
    for (final action in order)
      if (!hidden.contains(action)) action,
  ];

  /// This config with the action at [oldIndex] moved to [newIndex] (drag-to-
  /// reorder), clamped to valid slots. Visibility is unchanged.
  HomeActionsConfig reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= order.length) return this;
    final target = newIndex.clamp(0, order.length - 1);
    if (target == oldIndex) return this;
    final next = List<LibraryAction>.of(order);
    next.insert(target, next.removeAt(oldIndex));
    return HomeActionsConfig(order: List.unmodifiable(next), hidden: hidden);
  }

  /// This config with [action] shown ([visible] true) or hidden. Order is
  /// unchanged.
  HomeActionsConfig withVisibility(LibraryAction action, bool visible) {
    final next = Set<LibraryAction>.of(hidden);
    if (visible) {
      next.remove(action);
    } else {
      next.add(action);
    }
    return HomeActionsConfig(order: order, hidden: Set.unmodifiable(next));
  }

  /// JSON view (`{"order": [...ids], "hidden": [...ids]}`), for persistence.
  Map<String, Object> toJson() => {
    'order': [for (final a in order) a.id],
    'hidden': [for (final a in hidden) a.id],
  };

  /// Rebuilds a config from [json] produced by [toJson]. Unknown ids are
  /// dropped; any action missing from the saved order is appended VISIBLE in its
  /// canonical order. Null/garbage input yields [standard].
  static HomeActionsConfig fromJson(Object? json) {
    if (json is! Map) return standard;
    final byId = {for (final a in LibraryAction.all) a.id: a};
    List<LibraryAction> parse(Object? raw) => [
      if (raw is List)
        for (final entry in raw)
          if (entry is String && byId.containsKey(entry)) byId[entry]!,
    ];
    return HomeActionsConfig.normalized(
      order: parse(json['order']),
      hidden: parse(json['hidden']),
    );
  }
}
