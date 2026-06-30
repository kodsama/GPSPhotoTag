/// Shared JSON / numeric coercion helpers used when parsing exiftool output.
library;

import 'dart:convert';

/// Decodes a JSON string that is expected to contain a [List].
///
/// Returns an empty list when [text] is blank, when the JSON is malformed, or
/// when the decoded value is not a [List]. Never throws.
List<dynamic> tryDecodeJsonList(String text) {
  if (text.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    return decoded is List ? decoded : const [];
  } on FormatException {
    return const [];
  }
}

/// Coerces an exiftool `-n` numeric value to [int].
///
/// Accepts integers, other [num] subtypes (truncates), or strings that
/// [int.tryParse] can handle. Returns null for all other inputs.
int? exifAsInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Coerces an exiftool `-n` numeric value to [double].
///
/// Accepts [num] values or non-empty strings that [double.tryParse] can
/// handle. Returns null for null, empty strings, or unparseable values.
double? exifAsDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final s = v.trim();
    return s.isEmpty ? null : double.tryParse(s);
  }
  return null;
}
