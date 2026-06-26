import 'dart:io';

import '../data/sources/google_source.dart';
import '../data/sources/gpx_source.dart';
import '../domain/folder_scan.dart';
import '../domain/timed_point.dart';

/// A pooled set of location sources ready for `TagService.tag`.
///
/// [track] merges every GPS track ([parseGpx] for `.gpx`, [parseGoogleKml] for
/// `.kml`); [google] holds validated Google-history JSON points
/// ([parseGoogleAuto]). Both lists are time-sorted ascending, which the locator
/// relies on for binary search.
class SourcePool {
  /// Creates a pool from already-sorted [track] and [google] points.
  const SourcePool({required this.track, required this.google});

  /// Time-ordered points from all GPX and KML track files.
  final List<TimedPoint> track;

  /// Time-ordered points from all Google-history JSON files.
  final List<TimedPoint> google;
}

/// Builds a [SourcePool] from explicit source-file path lists.
///
/// Lets the app pool every location source found anywhere in a scanned tree
/// regardless of folder layout: [gpxFiles] are parsed with [parseGpx],
/// [kmlFiles] with [parseGoogleKml] (both merged into [SourcePool.track]), and
/// [googleJsonFiles] with [parseGoogleAuto] (into [SourcePool.google]).
/// Unreadable or malformed files are skipped. Each list defaults to empty so
/// callers can pass only what they have.
SourcePool poolSources({
  List<String> gpxFiles = const [],
  List<String> kmlFiles = const [],
  List<String> googleJsonFiles = const [],
}) {
  final track = <TimedPoint>[];
  for (final path in gpxFiles) {
    track.addAll(_parse(path, parseGpx));
  }
  for (final path in kmlFiles) {
    track.addAll(_parse(path, parseGoogleKml));
  }
  track.sort();

  final google = <TimedPoint>[];
  for (final path in googleJsonFiles) {
    google.addAll(_parse(path, parseGoogleAuto));
  }
  google.sort();

  return SourcePool(track: track, google: google);
}

/// Builds a [SourcePool] directly from a [FolderScanResult]'s source lists.
SourcePool poolFromScan(FolderScanResult scan) => poolSources(
  gpxFiles: scan.gpxFiles,
  kmlFiles: scan.kmlFiles,
  googleJsonFiles: scan.googleFiles,
);

List<TimedPoint> _parse(String path, List<TimedPoint> Function(String) parse) {
  try {
    return parse(File(path).readAsStringSync());
  } on FileSystemException {
    return const [];
  } on FormatException {
    return const [];
  }
}
