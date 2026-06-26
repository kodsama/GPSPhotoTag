import 'package:meta/meta.dart';

import 'location_result.dart';
import 'status.dart';

/// The per-item record surfaced to the UI and serialised to `--json`.
///
/// One [PhotoRow] is emitted for every photo touched by an operation, carrying
/// its resolved [status], the optional [location] written, and a human note.
@immutable
class PhotoRow {
  /// Creates a row for [path].
  const PhotoRow({
    required this.path,
    required this.status,
    this.timestamp,
    this.location,
    this.note,
  });

  /// Absolute path of the file this row describes.
  final String path;

  /// The capture instant read from the file, if any (UTC).
  final DateTime? timestamp;

  /// The outcome for this file.
  final PhotoStatus status;

  /// The coordinate written, when [status] is [PhotoStatus.tagged] or
  /// [PhotoStatus.interpolated].
  final LocationResult? location;

  /// Free-form detail (e.g. `use --replace to overwrite`, or an error message).
  final String? note;

  /// JSON form for the CLI `item` event and logging.
  Map<String, Object?> toJson() => {
    'path': path,
    'status': status.wire,
    if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
    if (location != null) ...{
      'lat': location!.latitude,
      'lon': location!.longitude,
      'source': location!.provenance,
    },
    if (note != null) 'note': note,
  };

  /// Returns a copy with selected fields replaced.
  PhotoRow copyWith({
    PhotoStatus? status,
    DateTime? timestamp,
    LocationResult? location,
    String? note,
  }) => PhotoRow(
    path: path,
    status: status ?? this.status,
    timestamp: timestamp ?? this.timestamp,
    location: location ?? this.location,
    note: note ?? this.note,
  );
}
