import 'package:path/path.dart' as p;

// Patterns are tried in order; the first that matches the basename wins.
// Each exposes named groups y/mo/d/h/mi/s so extraction is uniform.
final List<RegExp> _patterns = [
  // PXL_20260622_104338000  (Pixel; trailing ms ignored)
  RegExp(
    r'PXL_(?<y>\d{4})(?<mo>\d{2})(?<d>\d{2})_'
    r'(?<h>\d{2})(?<mi>\d{2})(?<s>\d{2})',
  ),
  // IMG_20260622_104338 / VID_20260622_104338
  RegExp(
    r'(?:IMG|VID)_(?<y>\d{4})(?<mo>\d{2})(?<d>\d{2})_'
    r'(?<h>\d{2})(?<mi>\d{2})(?<s>\d{2})',
  ),
  // Screenshot_20260622-104338
  RegExp(
    r'Screenshot_(?<y>\d{4})(?<mo>\d{2})(?<d>\d{2})-'
    r'(?<h>\d{2})(?<mi>\d{2})(?<s>\d{2})',
  ),
  // ISO-ish: 2026-06-22 10.43.38  or  2026-06-22T10-43-38
  RegExp(
    r'(?<y>\d{4})-(?<mo>\d{2})-(?<d>\d{2})[ T]'
    r'(?<h>\d{2})[.\-:](?<mi>\d{2})[.\-:](?<s>\d{2})',
  ),
  // Bare: 20260622_104338  (kept last so prefixed forms win first)
  RegExp(
    r'(?<y>\d{4})(?<mo>\d{2})(?<d>\d{2})_'
    r'(?<h>\d{2})(?<mi>\d{2})(?<s>\d{2})',
  ),
];

/// Parses a naive local capture time from the basename of [path], or null.
///
/// Recognises the common phone/camera naming schemes: `PXL_YYYYMMDD_HHMMSS…`,
/// `IMG_`/`VID_YYYYMMDD_HHMMSS`, `Screenshot_YYYYMMDD-HHMMSS`, bare
/// `YYYYMMDD_HHMMSS`, and ISO-ish `YYYY-MM-DD HH.MM.SS` / `YYYY-MM-DDTHH-MM-SS`.
///
/// Returns a timezone-less local [DateTime] (the caller converts to UTC) or
/// null when no pattern matches or the fields are out of range (e.g. month 13,
/// day 32, hour 24). Used as a fallback when a photo carries no EXIF capture
/// time, so phone shots still match a GPS track.
DateTime? timestampFromFilename(String path) {
  final base = p.basename(path);
  for (final pat in _patterns) {
    final m = pat.firstMatch(base);
    if (m == null) continue;
    final dt = _build(m);
    if (dt != null) return dt;
  }
  return null;
}

DateTime? _build(RegExpMatch m) {
  final year = int.parse(m.namedGroup('y')!);
  final month = int.parse(m.namedGroup('mo')!);
  final day = int.parse(m.namedGroup('d')!);
  final hour = int.parse(m.namedGroup('h')!);
  final minute = int.parse(m.namedGroup('mi')!);
  final second = int.parse(m.namedGroup('s')!);

  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  final dt = DateTime(year, month, day, hour, minute, second);
  // Reject overflow (e.g. Feb 31 normalises to March) by round-tripping.
  if (dt.month != month || dt.day != day) return null;
  return dt;
}
