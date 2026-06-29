import 'package:stunda_engine/stunda_engine.dart';

import '../state/library_action.dart' show Translator;
import '../actions/duplicates_action.dart' show formatBytes;

/// How two images are laid out in the [ImageCompareViewer]'s compare mode.
///
/// The order also defines the cycle the mode button steps through.
enum CompareMode {
  /// Both images stacked, revealed by a draggable vertical divider (default).
  verticalCurtain,

  /// Both images stacked, revealed by a draggable horizontal divider.
  horizontalCurtain,

  /// Two images side by side with a shared zoom/pan transform.
  sideBySide,
}

/// The next compare mode in the cycle (wraps around). Pure so the mode button's
/// behaviour is unit-testable.
CompareMode nextCompareMode(CompareMode mode) {
  const order = CompareMode.values;
  return order[(mode.index + 1) % order.length];
}

/// Clamps a curtain divider [fraction] to the inclusive 0..1 range.
///
/// 0 reveals one image fully; 1 reveals the other. Pure so the drag math can be
/// asserted without a gesture.
double clampFraction(double fraction) =>
    fraction.isNaN ? 0.5 : fraction.clamp(0.0, 1.0);

/// The divider fraction after a drag from [start] to [current] along an axis of
/// [extent] logical pixels, starting from [from].
///
/// The delta is normalised by [extent] and added to the starting fraction, then
/// clamped. A zero/negative [extent] is treated as no movement. Pure so the
/// before/after swipe is testable without a render box.
double dragFraction({
  required double from,
  required double start,
  required double current,
  required double extent,
}) {
  if (extent <= 0) return clampFraction(from);
  return clampFraction(from + (current - start) / extent);
}

/// One segment of an image's one-line info strip, kept structured (rather than a
/// joined string) so the widget can render the GPS pin as an icon while the rest
/// is plain text. Pure data so the formatting is unit-testable.
class InfoSegment {
  /// Creates a [text] segment; set [isGps] for the coordinate (pin) segment.
  const InfoSegment(this.text, {this.isGps = false});

  /// The visible text (a coordinate string for the GPS segment).
  final String text;

  /// Whether this segment is the GPS pin (rendered as an icon + tooltip).
  final bool isGps;
}

/// Formats the coordinate string carried by the GPS segment's tooltip.
String formatGps(double lat, double lon) =>
    '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';

/// The capture-time string `YYYY-MM-DD HH:MM` for [date].
String formatCaptureTime(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

/// Builds the one-line info segments for an image: filename · W×H · size ·
/// capture time · GPS pin (only when coords are present) · curated EXIF.
///
/// [name] is the basename; [fileSize] is the on-disk byte count (null = omit);
/// [meta] supplies dimensions/date/GPS; [exif] supplies camera/exposure tags.
/// The GPS segment is included only when [FileMeta.hasGps] AND both coordinates
/// are present — the present-gating the viewer relies on. Pure so the info line
/// (incl. GPS gating) is unit-testable.
List<InfoSegment> compareInfoSegments({
  required String name,
  int? fileSize,
  FileMeta? meta,
  CuratedExif? exif,
  required Translator tr,
}) {
  final segments = <InfoSegment>[InfoSegment(name)];

  final w = meta?.width, h = meta?.height;
  if (w != null && h != null) {
    segments.add(
      InfoSegment(tr('preview_dimensions', {'width': w, 'height': h})),
    );
  }
  if (fileSize != null) segments.add(InfoSegment(formatBytes(fileSize, tr)));
  final date = meta?.date;
  if (date != null) segments.add(InfoSegment(formatCaptureTime(date)));

  final lat = meta?.latitude, lon = meta?.longitude;
  if (meta?.hasGps == true && lat != null && lon != null) {
    segments.add(InfoSegment(formatGps(lat, lon), isGps: true));
  }

  for (final part in exifSegments(exif)) {
    segments.add(InfoSegment(part));
  }
  return segments;
}

/// The plain camera/exposure parts of [exif] in display order, dropping any that
/// are absent. Pure so the EXIF formatting is unit-testable.
List<String> exifSegments(CuratedExif? exif) {
  if (exif == null) return const [];
  final parts = <String>[];
  final camera = [
    exif.make,
    exif.model,
  ].where((s) => s != null && s.isNotEmpty).join(' ');
  if (camera.isNotEmpty) parts.add(camera);
  if (exif.lens != null) parts.add(exif.lens!);
  if (exif.iso != null) parts.add('ISO ${exif.iso}');
  if (exif.exposure != null) parts.add(exif.exposure!);
  if (exif.fNumber != null) parts.add('f/${exif.fNumber}');
  if (exif.focalLength != null) parts.add(exif.focalLength!);
  return parts;
}
