import 'dart:io';
import 'dart:typed_data';

import 'exif_backend.dart';
import 'exif_utils.dart';

/// Pure-Dart, lossless JPEG EXIF GPS backend.
///
/// Reads capture metadata from, and writes WGS-84 GPS coordinates into,
/// baseline/progressive JPEG files without re-encoding image pixels. Only the
/// `APP1`/`Exif` segment is rewritten and spliced back into the byte stream;
/// all compressed image data is preserved verbatim.
///
/// On write, existing IFD0 and Exif sub-IFD tags (camera make/model,
/// `DateTimeOriginal`, etc.) are preserved. **The IFD1 thumbnail and any
/// Interoperability IFD are intentionally dropped** to keep the serializer
/// correct and simple; the primary image is untouched.
class JpegExifBackend implements ExifBackend {
  /// Creates a JPEG EXIF backend.
  const JpegExifBackend();

  // --- TIFF type identifiers. ---
  static const int _typeByte = 1;
  static const int _typeAscii = 2;
  static const int _typeShort = 3;
  static const int _typeLong = 4;
  static const int _typeRational = 5;

  // --- Tag identifiers. ---
  static const int _tagExifIfd = 0x8769;
  static const int _tagGpsIfd = 0x8825;
  static const int _tagDateTimeOriginal = 0x9003;
  static const int _tagOffsetTimeOriginal = 0x9011;
  static const int _tagGpsLatitudeRef = 0x01;
  static const int _tagGpsLatitude = 0x02;

  @override
  bool supports(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg');
  }

  @override
  Future<PhotoMeta> read(String path) async {
    final bytes = await File(path).readAsBytes();
    final exif = _findExifPayload(bytes);
    if (exif == null) return const PhotoMeta();
    return _parseTiff(exif);
  }

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final newJpeg = _writeGpsBytes(
      bytes,
      latitude: latitude,
      longitude: longitude,
      dateTimeOriginal: dateTimeOriginal,
    );
    await file.writeAsBytes(newJpeg, flush: true);
  }

  // ---------------------------------------------------------------------------
  // JPEG segment scanning.
  // ---------------------------------------------------------------------------

  /// Returns the TIFF payload (bytes after `Exif\0\0`) of the first Exif APP1
  /// segment, or null when none is present.
  static Uint8List? _findExifPayload(Uint8List bytes) {
    final loc = _locateExif(bytes);
    if (loc == null) return null;
    return Uint8List.sublistView(bytes, loc.tiffStart, loc.tiffEnd);
  }

  /// Scans JPEG markers for an Exif APP1 segment, returning its byte ranges.
  static _ExifLocation? _locateExif(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    var i = 2;
    while (i + 4 <= bytes.length) {
      if (bytes[i] != 0xFF) break;
      final marker = bytes[i + 1];
      if (marker == 0xDA || marker == 0xD9) break; // SOS / EOI: stop.
      final segLen = (bytes[i + 2] << 8) | bytes[i + 3];
      final payloadStart = i + 4;
      final payloadEnd = i + 2 + segLen;
      if (payloadEnd > bytes.length) break;
      if (marker == 0xE1 && _hasExifHeader(bytes, payloadStart)) {
        return _ExifLocation(
          segStart: i,
          segEnd: payloadEnd,
          tiffStart: payloadStart + 6,
          tiffEnd: payloadEnd,
        );
      }
      i = payloadEnd;
    }
    return null;
  }

  /// Whether the six bytes at [offset] are the `Exif\0\0` APP1 header.
  static bool _hasExifHeader(Uint8List bytes, int offset) {
    if (offset + 6 > bytes.length) return false;
    return bytes[offset] == 0x45 && // E
        bytes[offset + 1] == 0x78 && // x
        bytes[offset + 2] == 0x69 && // i
        bytes[offset + 3] == 0x66 && // f
        bytes[offset + 4] == 0x00 &&
        bytes[offset + 5] == 0x00;
  }

  // ---------------------------------------------------------------------------
  // TIFF reading.
  // ---------------------------------------------------------------------------

  static PhotoMeta _parseTiff(Uint8List tiff) {
    final bd = ByteData.sublistView(tiff);
    final little = _byteOrder(bd);
    if (little == null) return const PhotoMeta();
    final ifd0Offset = bd.getUint32(4, _endian(little));
    final ifd0 = _readIfd(bd, ifd0Offset, little);

    DateTime? captureNaive;
    Duration? offset;
    final exifPtr = ifd0[_tagExifIfd];
    if (exifPtr != null) {
      final exifOffset = exifPtr.valueAsLong(bd, little);
      final exifIfd = _readIfd(bd, exifOffset, little);
      final dto = exifIfd[_tagDateTimeOriginal];
      if (dto != null) {
        captureNaive = parseExifDateTimeNaive(dto.readAscii(tiff, bd, little));
      }
      final oto = exifIfd[_tagOffsetTimeOriginal];
      if (oto != null) {
        offset = _parseOffset(oto.readAscii(tiff, bd, little));
      }
    }

    var hasGps = false;
    final gpsPtr = ifd0[_tagGpsIfd];
    if (gpsPtr != null) {
      final gpsOffset = gpsPtr.valueAsLong(bd, little);
      final gpsIfd = _readIfd(bd, gpsOffset, little);
      hasGps =
          gpsIfd.containsKey(_tagGpsLatitude) &&
          gpsIfd.containsKey(_tagGpsLatitudeRef);
    }

    return PhotoMeta(
      captureNaive: captureNaive,
      offset: offset,
      hasGps: hasGps,
    );
  }

  /// Returns true for little-endian (`II`), false for big-endian (`MM`), or
  /// null when the TIFF header is malformed.
  static bool? _byteOrder(ByteData bd) {
    if (bd.lengthInBytes < 8) return null;
    final b0 = bd.getUint8(0);
    final b1 = bd.getUint8(1);
    if (b0 == 0x49 && b1 == 0x49) return true;
    if (b0 == 0x4D && b1 == 0x4D) return false;
    return null;
  }

  static Endian _endian(bool little) => little ? Endian.little : Endian.big;

  /// Reads one IFD at [offset] into a tag-keyed map (last entry wins).
  static Map<int, _IfdEntry> _readIfd(ByteData bd, int offset, bool little) {
    final out = <int, _IfdEntry>{};
    if (offset <= 0 || offset + 2 > bd.lengthInBytes) return out;
    final e = _endian(little);
    final count = bd.getUint16(offset, e);
    var p = offset + 2;
    for (var n = 0; n < count; n++) {
      if (p + 12 > bd.lengthInBytes) break;
      final tag = bd.getUint16(p, e);
      final type = bd.getUint16(p + 2, e);
      final valueCount = bd.getUint32(p + 4, e);
      out[tag] = _IfdEntry(
        tag: tag,
        type: type,
        count: valueCount,
        valueFieldOffset: p + 8,
      );
      p += 12;
    }
    return out;
  }

  /// Parses an EXIF offset string like `"+02:00"` / `"-05:30"` to a [Duration].
  static Duration? _parseOffset(String? s) {
    if (s == null) return null;
    final m = RegExp(r'^([+-])(\d{2}):(\d{2})').firstMatch(s.trim());
    if (m == null) return null;
    final sign = m.group(1) == '-' ? -1 : 1;
    final hours = int.parse(m.group(2)!);
    final minutes = int.parse(m.group(3)!);
    return Duration(minutes: sign * (hours * 60 + minutes));
  }

  // ---------------------------------------------------------------------------
  // GPS writing.
  // ---------------------------------------------------------------------------

  static Uint8List _writeGpsBytes(
    Uint8List bytes, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) {
    final loc = _locateExif(bytes);

    // Collect preserved IFD0 + Exif sub-IFD tags from the existing block.
    final ifd0Fields = <_Field>[];
    final exifFields = <_Field>[];
    var little = true; // Default LE for a freshly-created Exif block.

    if (loc != null) {
      final tiff = Uint8List.sublistView(bytes, loc.tiffStart, loc.tiffEnd);
      final bd = ByteData.sublistView(tiff);
      final order = _byteOrder(bd);
      if (order != null) {
        little = order;
        final ifd0Offset = bd.getUint32(4, _endian(little));
        final ifd0 = _readIfd(bd, ifd0Offset, little);
        for (final entry in ifd0.values) {
          // Drop the pointers (rewritten) and any stale GPS data.
          if (entry.tag == _tagExifIfd || entry.tag == _tagGpsIfd) continue;
          ifd0Fields.add(entry.toField(tiff, bd, little));
        }
        final exifPtr = ifd0[_tagExifIfd];
        if (exifPtr != null) {
          final exifOffset = exifPtr.valueAsLong(bd, little);
          final exifIfd = _readIfd(bd, exifOffset, little);
          for (final entry in exifIfd.values) {
            if (entry.tag == _tagDateTimeOriginal && dateTimeOriginal != null) {
              continue; // Replaced below.
            }
            exifFields.add(entry.toField(tiff, bd, little));
          }
        }
      }
    }

    if (dateTimeOriginal != null) {
      exifFields.add(
        _Field.ascii(
          _tagDateTimeOriginal,
          formatExifDateTime(dateTimeOriginal),
        ),
      );
    }

    final gpsFields = _buildGpsFields(latitude, longitude);

    final tiff = _serializeTiff(
      little: little,
      ifd0Fields: ifd0Fields,
      exifFields: exifFields,
      gpsFields: gpsFields,
    );

    final app1 = _wrapApp1(tiff);
    return _spliceApp1(bytes, loc, app1);
  }

  /// Builds the fresh GPS IFD fields for the given coordinates.
  static List<_Field> _buildGpsFields(double latitude, double longitude) {
    return <_Field>[
      _Field.bytes(0x00, Uint8List.fromList(<int>[2, 3, 0, 0])), // GPSVersionID
      _Field.ascii(0x01, latitude >= 0 ? 'N' : 'S'), // GPSLatitudeRef
      _Field.rationals(0x02, _dmsRationals(latitude.abs())), // GPSLatitude
      _Field.ascii(0x03, longitude >= 0 ? 'E' : 'W'), // GPSLongitudeRef
      _Field.rationals(0x04, _dmsRationals(longitude.abs())), // GPSLongitude
      _Field.ascii(0x12, 'WGS-84'), // GPSMapDatum
    ];
  }

  /// Splits a positive decimal degree value into deg/min/sec rationals.
  ///
  /// Uses deg=(D,1), min=(M,1), sec=(round(S*100),100) for ~0.01" precision.
  static List<_Rational> _dmsRationals(double value) {
    final deg = value.floor();
    final minFull = (value - deg) * 60.0;
    final min = minFull.floor();
    final sec = (minFull - min) * 60.0;
    return <_Rational>[
      _Rational(deg, 1),
      _Rational(min, 1),
      _Rational((sec * 100).round(), 100),
    ];
  }

  // ---------------------------------------------------------------------------
  // TIFF serialization (two-pass: lay out IFDs, then external data).
  // ---------------------------------------------------------------------------

  static Uint8List _serializeTiff({
    required bool little,
    required List<_Field> ifd0Fields,
    required List<_Field> exifFields,
    required List<_Field> gpsFields,
  }) {
    // IFD0 carries its own fields plus the two pointer entries.
    final ifd0EntryCount = ifd0Fields.length + 2;
    final exifEntryCount = exifFields.length;
    final gpsEntryCount = gpsFields.length;

    const headerSize = 8;
    final ifd0Size = _ifdSize(ifd0EntryCount);
    final exifSize = _ifdSize(exifEntryCount);
    final gpsSize = _ifdSize(gpsEntryCount);

    const ifd0Offset = headerSize;
    final exifOffset = ifd0Offset + ifd0Size;
    final gpsOffset = exifOffset + exifSize;
    var dataCursor = gpsOffset + gpsSize;

    // Assign external-data offsets in order: IFD0 fields, Exif, GPS.
    for (final f in <_Field>[...ifd0Fields, ...exifFields, ...gpsFields]) {
      if (f.needsExternal) {
        f.dataOffset = dataCursor;
        dataCursor += _pad2(f.byteLength);
      }
    }

    final total = dataCursor;
    final out = ByteData(total);
    final e = _endian(little);

    // TIFF header.
    final orderByte = little ? 0x49 : 0x4D;
    out.setUint8(0, orderByte);
    out.setUint8(1, orderByte);
    out.setUint16(2, 0x002A, e);
    out.setUint32(4, ifd0Offset, e);

    // IFD0: preserved fields + Exif pointer + GPS pointer.
    final ifd0All = <_Field>[
      ...ifd0Fields,
      _Field.long(_tagExifIfd, exifOffset),
      _Field.long(_tagGpsIfd, gpsOffset),
    ]..sort((a, b) => a.tag.compareTo(b.tag));
    _writeIfd(out, ifd0Offset, ifd0All, 0, e);

    // Exif sub-IFD.
    final exifSorted = <_Field>[...exifFields]
      ..sort((a, b) => a.tag.compareTo(b.tag));
    _writeIfd(out, exifOffset, exifSorted, 0, e);

    // GPS IFD.
    final gpsSorted = <_Field>[...gpsFields]
      ..sort((a, b) => a.tag.compareTo(b.tag));
    _writeIfd(out, gpsOffset, gpsSorted, 0, e);

    return out.buffer.asUint8List();
  }

  static int _ifdSize(int entryCount) => 2 + entryCount * 12 + 4;

  static int _pad2(int n) => n.isOdd ? n + 1 : n;

  /// Writes one IFD (count, entries, next-IFD offset) and any external data.
  static void _writeIfd(
    ByteData out,
    int ifdOffset,
    List<_Field> fields,
    int nextIfdOffset,
    Endian e,
  ) {
    out.setUint16(ifdOffset, fields.length, e);
    var p = ifdOffset + 2;
    for (final f in fields) {
      out.setUint16(p, f.tag, e);
      out.setUint16(p + 2, f.type, e);
      out.setUint32(p + 4, f.count, e);
      if (f.needsExternal) {
        out.setUint32(p + 8, f.dataOffset, e);
        f.writeData(out, f.dataOffset, e);
      } else {
        f.writeInline(out, p + 8, e);
      }
      p += 12;
    }
    out.setUint32(p, nextIfdOffset, e);
  }

  // ---------------------------------------------------------------------------
  // APP1 wrapping and JPEG splicing.
  // ---------------------------------------------------------------------------

  /// Wraps a TIFF block in a full `FF E1` APP1 segment with `Exif\0\0` header.
  static Uint8List _wrapApp1(Uint8List tiff) {
    final payloadLen = 6 + tiff.length; // "Exif\0\0" + TIFF.
    final segLen = payloadLen + 2; // include the 2 length bytes.
    final seg = Uint8List(4 + payloadLen);
    seg[0] = 0xFF;
    seg[1] = 0xE1;
    seg[2] = (segLen >> 8) & 0xFF;
    seg[3] = segLen & 0xFF;
    seg[4] = 0x45; // E
    seg[5] = 0x78; // x
    seg[6] = 0x69; // i
    seg[7] = 0x66; // f
    seg[8] = 0x00;
    seg[9] = 0x00;
    seg.setRange(10, 10 + tiff.length, tiff);
    return seg;
  }

  /// Splices [app1] into [bytes], replacing an existing Exif APP1 ([loc]) or
  /// inserting after SOI / after a leading JFIF APP0 when none exists.
  static Uint8List _spliceApp1(
    Uint8List bytes,
    _ExifLocation? loc,
    Uint8List app1,
  ) {
    if (loc != null) {
      final b = BytesBuilder();
      b.add(Uint8List.sublistView(bytes, 0, loc.segStart));
      b.add(app1);
      b.add(Uint8List.sublistView(bytes, loc.segEnd));
      return b.toBytes();
    }

    final insertAt = _insertionPoint(bytes);
    final b = BytesBuilder();
    b.add(Uint8List.sublistView(bytes, 0, insertAt));
    b.add(app1);
    b.add(Uint8List.sublistView(bytes, insertAt));
    return b.toBytes();
  }

  /// Returns the offset to insert a new APP1: after SOI, or after a leading
  /// APP0 (JFIF) segment if one is present.
  static int _insertionPoint(Uint8List bytes) {
    var at = 2; // After SOI (FF D8).
    if (at + 4 <= bytes.length && bytes[at] == 0xFF && bytes[at + 1] == 0xE0) {
      final segLen = (bytes[at + 2] << 8) | bytes[at + 3];
      at = at + 2 + segLen;
    }
    return at;
  }
}

/// Byte ranges of an Exif APP1 segment within a JPEG.
class _ExifLocation {
  _ExifLocation({
    required this.segStart,
    required this.segEnd,
    required this.tiffStart,
    required this.tiffEnd,
  });

  /// Offset of the `FF E1` marker.
  final int segStart;

  /// Offset one past the end of the APP1 payload.
  final int segEnd;

  /// Offset of the TIFF byte order mark (after `Exif\0\0`).
  final int tiffStart;

  /// Offset one past the end of the TIFF block.
  final int tiffEnd;
}

/// A parsed IFD entry referencing its value within a TIFF block.
class _IfdEntry {
  _IfdEntry({
    required this.tag,
    required this.type,
    required this.count,
    required this.valueFieldOffset,
  });

  final int tag;
  final int type;
  final int count;

  /// Offset of the 4-byte value/offset field within the TIFF block.
  final int valueFieldOffset;

  int get _typeSize {
    switch (type) {
      case 1: // BYTE
      case 2: // ASCII
      case 6: // SBYTE
      case 7: // UNDEFINED
        return 1;
      case 3: // SHORT
      case 8: // SSHORT
        return 2;
      case 4: // LONG
      case 9: // SLONG
      case 11: // FLOAT
        return 4;
      case 5: // RATIONAL
      case 10: // SRATIONAL
      case 12: // DOUBLE
        return 8;
      default:
        return 1; // Unknown type: treat as bytes.
    }
  }

  int get _byteLength => _typeSize * count;

  /// Reads this entry's value as a LONG/SHORT (for IFD pointer tags).
  int valueAsLong(ByteData bd, bool little) {
    final e = little ? Endian.little : Endian.big;
    if (type == JpegExifBackend._typeShort) {
      return bd.getUint16(valueFieldOffset, e);
    }
    return bd.getUint32(valueFieldOffset, e);
  }

  /// Offset of the actual data bytes (inline field or external block).
  int _dataOffset(ByteData bd, bool little) {
    if (_byteLength <= 4) return valueFieldOffset;
    return bd.getUint32(valueFieldOffset, little ? Endian.little : Endian.big);
  }

  /// Reads an ASCII value, trimming the trailing NUL.
  String? readAscii(Uint8List tiff, ByteData bd, bool little) {
    if (type != JpegExifBackend._typeAscii) return null;
    final start = _dataOffset(bd, little);
    if (start < 0 || start + count > tiff.length) return null;
    var end = start + count;
    while (end > start && tiff[end - 1] == 0) {
      end--;
    }
    return String.fromCharCodes(tiff.sublist(start, end));
  }

  /// Captures this entry's raw value bytes into a serializer [_Field].
  ///
  /// External value bytes are copied verbatim (already in the file's byte
  /// order), so the serializer must keep the same byte order as the input.
  _Field toField(Uint8List tiff, ByteData bd, bool little) {
    final len = _byteLength;
    final start = _dataOffset(bd, little);
    final raw = Uint8List.fromList(tiff.sublist(start, start + len));
    return _Field.raw(tag: tag, type: type, count: count, rawValue: raw);
  }
}

/// A rational number (numerator/denominator).
class _Rational {
  const _Rational(this.num, this.den);
  final int num;
  final int den;
}

/// A field staged for TIFF serialization, holding its value as raw bytes.
class _Field {
  _Field._({
    required this.tag,
    required this.type,
    required this.count,
    required this.rawValue,
  });

  /// A field built from verbatim raw value bytes (preserved tags).
  factory _Field.raw({
    required int tag,
    required int type,
    required int count,
    required Uint8List rawValue,
  }) => _Field._(tag: tag, type: type, count: count, rawValue: rawValue);

  /// A single LONG value (used for IFD pointer entries).
  factory _Field.long(int tag, int value) {
    return _Field._(
        tag: tag,
        type: JpegExifBackend._typeLong,
        count: 1,
        rawValue: Uint8List(0),
      )
      ..isPointer = true
      ..pointerValue = value;
  }

  /// A BYTE array field.
  factory _Field.bytes(int tag, Uint8List value) => _Field._(
    tag: tag,
    type: JpegExifBackend._typeByte,
    count: value.length,
    rawValue: value,
  );

  /// An ASCII field; a trailing NUL terminator is appended.
  factory _Field.ascii(int tag, String value) {
    final codes = <int>[...value.codeUnits, 0];
    return _Field._(
      tag: tag,
      type: JpegExifBackend._typeAscii,
      count: codes.length,
      rawValue: Uint8List.fromList(codes),
    );
  }

  /// A RATIONAL[n] field; bytes are written at serialization time per-endian.
  factory _Field.rationals(int tag, List<_Rational> values) => _Field._(
    tag: tag,
    type: JpegExifBackend._typeRational,
    count: values.length,
    rawValue: Uint8List(0),
  )..rationals = values;

  final int tag;
  final int type;
  final int count;

  /// Raw value bytes for preserved/byte/ascii fields (verbatim, input order).
  final Uint8List rawValue;

  /// Rational values, when this is a freshly-built RATIONAL field.
  List<_Rational>? rationals;

  /// Whether this field is an IFD pointer whose value is patched at write time.
  bool isPointer = false;

  /// The pointer target offset (when [isPointer]).
  int pointerValue = 0;

  /// Assigned offset of external data (when [needsExternal]).
  int dataOffset = 0;

  /// Total byte length of this field's value.
  int get byteLength {
    final rs = rationals;
    if (rs != null) return rs.length * 8;
    return rawValue.length;
  }

  /// Whether the value exceeds 4 bytes and must live in an external block.
  bool get needsExternal => byteLength > 4;

  /// Writes the inline value (≤4 bytes), left-justified in the 4-byte field.
  void writeInline(ByteData out, int fieldOffset, Endian e) {
    if (isPointer) {
      out.setUint32(fieldOffset, pointerValue, e);
      return;
    }
    // Left-justified raw bytes (RATIONALs are always external, never inline).
    for (var n = 0; n < 4; n++) {
      out.setUint8(fieldOffset + n, n < rawValue.length ? rawValue[n] : 0);
    }
  }

  /// Writes the external value bytes at [offset].
  void writeData(ByteData out, int offset, Endian e) {
    final rs = rationals;
    if (rs != null) {
      var p = offset;
      for (final r in rs) {
        out.setUint32(p, r.num, e);
        out.setUint32(p + 4, r.den, e);
        p += 8;
      }
      return;
    }
    // Verbatim raw bytes (preserved fields are already in the file's order).
    for (var n = 0; n < rawValue.length; n++) {
      out.setUint8(offset + n, rawValue[n]);
    }
  }
}
