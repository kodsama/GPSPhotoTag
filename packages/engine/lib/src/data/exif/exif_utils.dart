/// Shared EXIF date/time helpers used by the JPEG, PNG, and exiftool backends.
library;

/// Formats [dt] as the EXIF `"YYYY:MM:DD HH:MM:SS"` literal.
///
/// This is the canonical format for `DateTimeOriginal` and `CreateDate` tags.
String formatExifDateTime(DateTime dt) {
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}:${p2(dt.month)}:'
      '${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}:${p2(dt.second)}';
}

/// Parses an EXIF `"YYYY:MM:DD HH:MM:SS"` string into a naive [DateTime].
///
/// Accepts an optional [raw] parameter typed as [Object?]; callers that receive
/// exiftool JSON output (where the value may not be a [String]) should pass the
/// raw JSON value directly — non-String objects are coerced via [toString].
/// Returns null when [raw] is null, too short, or the fields do not parse.
DateTime? parseExifDateTimeNaive(Object? raw) {
  if (raw == null) return null;
  final text = raw is String ? raw : raw.toString();
  if (text.length < 19) return null;
  final head = text.substring(0, 19);
  final year = int.tryParse(head.substring(0, 4));
  final month = int.tryParse(head.substring(5, 7));
  final day = int.tryParse(head.substring(8, 10));
  final hour = int.tryParse(head.substring(11, 13));
  final minute = int.tryParse(head.substring(14, 16));
  final second = int.tryParse(head.substring(17, 19));
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }
  return DateTime(year, month, day, hour, minute, second);
}
