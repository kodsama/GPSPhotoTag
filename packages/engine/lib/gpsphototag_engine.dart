/// GPSPhotoTag engine: the Flutter-free core shared by the desktop GUI and CLI.
///
/// This library exposes the domain models and (as later milestones land) the
/// services and orchestrators for tagging photos with GPS, pruning orphan RAW
/// files, fixing dates, and rendering heatmaps. It never imports `flutter` or
/// `dart:ui`, so the exact same logic runs headless in the CLI and inside the
/// GUI's worker isolates.
library;

export 'src/domain/engine_event.dart';
export 'src/domain/location_result.dart';
export 'src/domain/options.dart';
export 'src/domain/photo_row.dart';
export 'src/domain/status.dart';
export 'src/domain/timed_point.dart';
