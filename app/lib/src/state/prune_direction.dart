import 'package:stunda_engine/stunda_engine.dart';

/// The localization keys for each [PruneDirection].
///
/// The enum itself lives in the engine, so the GUI, the CLI (`prune-raw
/// --direction`) and the MCP server (`prune_raw`) all target the same two
/// sides. Only the display strings are the app's concern.
extension PruneDirectionLabels on PruneDirection {
  /// Localization key for the direction toggle segment label.
  String get labelKey => switch (this) {
    PruneDirection.removeOrphanRaws => 'prune_dir_orphan_raws',
    PruneDirection.removeOrphanImages => 'prune_dir_orphan_images',
  };

  /// Localization key for what this direction trashes.
  String get descriptionKey => switch (this) {
    PruneDirection.removeOrphanRaws => 'prune_dir_orphan_raws_desc',
    PruneDirection.removeOrphanImages => 'prune_dir_orphan_images_desc',
  };
}
