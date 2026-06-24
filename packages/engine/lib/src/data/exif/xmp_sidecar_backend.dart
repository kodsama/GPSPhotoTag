import 'dart:io';

import 'package:xml/xml.dart';

import 'exif_backend.dart';
import 'exiftool_backend.dart' show kRawExtensions;

/// An [ExifBackend] that records GPS in a companion `.xmp` sidecar instead of
/// modifying the (often unwritable) RAW file itself.
///
/// The sidecar path is the original path with `.xmp` appended, e.g.
/// `DSCF1.RAF` -> `DSCF1.RAF.xmp`, matching exiftool/Lightroom convention.
///
/// Sidecars written here are **GPS-only**: any [dateTimeOriginal] passed to
/// [writeGps] is ignored, and [read] never reports a capture time.
class XmpSidecarBackend implements ExifBackend {
  /// Creates a sidecar backend handling RAW formats.
  ///
  /// [extensions] overrides the default RAW set; pass it lower-cased without
  /// leading dots.
  XmpSidecarBackend({Set<String>? extensions})
      : _extensions = extensions ?? kRawExtensions;

  final Set<String> _extensions;

  @override
  bool supports(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return _extensions.contains(path.substring(dot + 1).toLowerCase());
  }

  @override
  Future<PhotoMeta> read(String path) async {
    final sidecar = File(_sidecarPath(path));
    if (!sidecar.existsSync()) return const PhotoMeta();
    final content = await sidecar.readAsString();
    return PhotoMeta(hasGps: content.contains('exif:GPSLatitude'));
  }

  @override
  Future<void> writeGps(
    String path, {
    required double latitude,
    required double longitude,
    DateTime? dateTimeOriginal,
  }) async {
    final xml = _buildXmp(latitude, longitude);
    await File(_sidecarPath(path)).writeAsString(xml);
  }

  String _sidecarPath(String path) => '$path.xmp';

  /// Builds an XMP/RDF document carrying the GPS position as EXIF properties.
  static String _buildXmp(double latitude, double longitude) {
    final builder = XmlBuilder();
    builder.processing('xpacket', 'begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"');
    builder.element('x:xmpmeta', nest: () {
      builder.attribute('xmlns:x', 'adobe:ns:meta/');
      builder.element('rdf:RDF', nest: () {
        builder.attribute(
            'xmlns:rdf', 'http://www.w3.org/1999/02/22-rdf-syntax-ns#');
        builder.element('rdf:Description', nest: () {
          builder.attribute('rdf:about', '');
          builder.attribute('xmlns:exif', 'http://ns.adobe.com/exif/1.0/');
          builder.element('exif:GPSLatitude',
              nest: _formatGpsCoord(latitude, isLatitude: true));
          builder.element('exif:GPSLongitude',
              nest: _formatGpsCoord(longitude, isLatitude: false));
          builder.element('exif:GPSMapDatum', nest: 'WGS-84');
        });
      });
    });
    builder.processing('xpacket', 'end="w"');
    return builder.buildDocument().toXmlString(pretty: true);
  }

  /// Formats [value] in the XMP GPS coordinate form `"D,M.mmmH"` (integer
  /// degrees, comma, decimal minutes, hemisphere letter).
  static String _formatGpsCoord(double value, {required bool isLatitude}) {
    final hemisphere = value < 0
        ? (isLatitude ? 'S' : 'W')
        : (isLatitude ? 'N' : 'E');
    final abs = value.abs();
    final degrees = abs.floor();
    final minutes = (abs - degrees) * 60;
    return '$degrees,${minutes.toStringAsFixed(5)}$hemisphere';
  }
}
