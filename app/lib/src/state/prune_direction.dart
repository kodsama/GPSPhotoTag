import 'package:stunda_engine/stunda_engine.dart';

/// Which side of the RAW/image pairing the prune review trashes.
///
/// The review classifies the whole library once ([RawPairing]); the direction
/// only chooses which category is the selectable/trashable *target* — the other
/// categories stay visible as read-only context. Paired files are never a
/// target in either direction.
enum PruneDirection {
  /// Trash RAW files that have no matching photo ([PairKind.orphanRaw]).
  removeOrphanRaws(
    target: PairKind.orphanRaw,
    label: 'Remove orphan RAWs',
    description: 'Trash RAW files that have no matching photo.',
  ),

  /// Trash non-RAW photos (JPG/HEIC/…) that have no matching RAW
  /// ([PairKind.photoWithoutRaw]).
  removeOrphanImages(
    target: PairKind.photoWithoutRaw,
    label: 'Remove orphan images',
    description: 'Trash photos (JPG/HEIC/…) that have no matching RAW.',
  );

  const PruneDirection({
    required this.target,
    required this.label,
    required this.description,
  });

  /// The [PairKind] this direction selects and trashes.
  final PairKind target;

  /// Short label for the direction toggle segment.
  final String label;

  /// One-line description of what this direction trashes.
  final String description;
}

/// The trashable paths for [pairing] under [direction], in scan order.
///
/// Pure and side-effect-free so it is unit-testable without a controller: it is
/// every path whose kind equals the direction's [PruneDirection.target]
/// (orphan RAWs for A, orphan images for B). Paired files are never returned.
List<String> trashCandidates(RawPairing pairing, PruneDirection direction) => [
  for (final f in pairing.files)
    if (f.kind == direction.target) f.path,
];
