/// GPSPhotoTag engine: the Flutter-free core shared by the desktop GUI and CLI.
///
/// Exposes the domain models, data backends/sources, services, and high-level
/// orchestrators for tagging photos with GPS, pruning orphan RAW files, fixing
/// dates, and (M4) rendering heatmaps. It never imports `flutter` or `dart:ui`,
/// so the exact same logic runs headless in the CLI and inside the GUI's worker
/// isolates.
library;

export 'src/app/tag_service.dart';
export 'src/data/collectors.dart';
export 'src/data/exif/backend_registry.dart';
export 'src/data/exif/dispatching_backend.dart';
export 'src/data/exif/exif_backend.dart';
export 'src/data/exif/exiftool_backend.dart';
export 'src/data/exif/jpeg_exif_backend.dart';
export 'src/data/exif/png_exif_backend.dart';
export 'src/data/exif/xmp_sidecar_backend.dart';
export 'src/data/filename_date.dart';
export 'src/data/photo_formats.dart';
export 'src/data/ports/exiftool_runner.dart';
export 'src/data/ports/process_runner.dart';
export 'src/data/ports/system_trash.dart';
export 'src/data/ports/trash.dart';
export 'src/data/sources/google_source.dart';
export 'src/data/sources/gpx_source.dart';
export 'src/domain/engine_event.dart';
export 'src/domain/folder_scan.dart';
export 'src/domain/location_result.dart';
export 'src/domain/options.dart';
export 'src/domain/photo_row.dart';
export 'src/domain/status.dart';
export 'src/domain/timed_point.dart';
export 'src/services/dater.dart';
export 'src/services/locator.dart';
export 'src/services/map_service.dart';
export 'src/services/pruner.dart';
export 'src/services/scanner.dart';
export 'src/services/source_pool.dart';
export 'src/services/toolkit_check.dart';
