import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../data/ports/process_runner.dart';
import '../domain/engine_event.dart';
import '../domain/options.dart';
import '../internal/json_utils.dart';

/// Side length in pixels of one CARTO `@2x` basemap tile.
const int _tileSize = 512;

/// A single GPS coordinate read from a photo, plus a display [name].
class GeoPoint {
  /// Creates a point at [lat]/[lon] taken from a file called [name].
  const GeoPoint(this.lat, this.lon, this.name);

  /// Latitude in degrees, north positive.
  final double lat;

  /// Longitude in degrees, east positive.
  final double lon;

  /// Source filename (basename without extension).
  final String name;
}

/// Fractional Web-Mercator pixel X for [lon] at zoom [z] (tile size [_tileSize]).
double lonToPixelX(double lon, int z) {
  final n = math.pow(2, z).toDouble();
  return (lon + 180.0) / 360.0 * n * _tileSize;
}

/// Fractional Web-Mercator pixel Y for [lat] at zoom [z] (tile size [_tileSize]).
double latToPixelY(double lat, int z) {
  final n = math.pow(2, z).toDouble();
  final latRad = lat * math.pi / 180.0;
  final y =
      (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) / 2;
  return y * n * _tileSize;
}

/// Picks the largest zoom in [2..18] whose bounding box (with [padding] fraction
/// of headroom) still fits inside a [canvas]×[canvas] pixel square.
///
/// Falls back to [singlePointZoom] when the box has no extent (a lone point or
/// many coincident points).
int chooseZoom(
  List<GeoPoint> points,
  int canvas, {
  double padding = 0.12,
  int singlePointZoom = 15,
}) {
  if (points.length < 2) return singlePointZoom;
  final usable = canvas * (1 - padding);
  for (var z = 18; z >= 2; z--) {
    final xs = points.map((g) => lonToPixelX(g.lon, z));
    final ys = points.map((g) => latToPixelY(g.lat, z));
    final w = xs.reduce(math.max) - xs.reduce(math.min);
    final h = ys.reduce(math.max) - ys.reduce(math.min);
    if (w <= usable && h <= usable) {
      return z == 18 && w == 0 && h == 0 ? singlePointZoom : z;
    }
  }
  return 2;
}

/// Reads GPS from already-tagged photos and renders a Google-Photos-style
/// density heatmap PNG over a light CARTO Positron basemap.
///
/// Skipped for this milestone (documented intentionally): cluster splitting into
/// `-zoom1.png` siblings, honouring [MapOptions.clusters], and filename-range
/// labels for [MapOptions.labelNames]. A single overview PNG is always produced.
class MapService {
  /// Creates a map service.
  ///
  /// [runner] invokes `exiftool`; [client] fetches basemap tiles (defaults to a
  /// real [http.Client]); set [exiftoolAvailable] false to fail fast with a
  /// `missing_toolkit` error before any work.
  // ignore_for_file: prefer_initializing_formals
  MapService({
    required ProcessRunner runner,
    http.Client? client,
    bool exiftoolAvailable = true,
  }) : _runner = runner,
       _exiftoolAvailable = exiftoolAvailable,
       _client = client ?? http.Client();

  final ProcessRunner _runner;
  final http.Client _client;
  final bool _exiftoolAvailable;

  /// Reads GPS from [photos], then renders the heatmap PNG per [options].
  ///
  /// Emits [LogEvent]s for progress, an [ErrorEvent] (`missing_toolkit` or
  /// `bad_input`) on failure, and a final [DoneEvent] `{'mapped': n}` on success.
  Stream<EngineEvent> render(List<String> photos, MapOptions options) async* {
    if (!_exiftoolAvailable) {
      yield const ErrorEvent(
        'reading GPS needs exiftool; install it via the toolkit check',
        code: 'missing_toolkit',
      );
      return;
    }

    final List<GeoPoint> points;
    try {
      points = await _readGps(photos);
    } on Object {
      yield const ErrorEvent(
        'reading GPS needs exiftool; install it via the toolkit check',
        code: 'missing_toolkit',
      );
      return;
    }

    yield LogEvent('${points.length} of ${photos.length} photos had GPS');

    if (points.isEmpty) {
      yield const ErrorEvent(
        'no GPS found in the given photos',
        code: 'bad_input',
      );
      return;
    }

    final canvas = (options.dpi * 5).clamp(600, 2400);
    final z = chooseZoom(points, canvas);

    // Canvas centred on the bbox centre, in absolute pixel space at zoom z.
    final pxs = points.map((g) => lonToPixelX(g.lon, z)).toList();
    final pys = points.map((g) => latToPixelY(g.lat, z)).toList();
    final cx = (pxs.reduce(math.max) + pxs.reduce(math.min)) / 2;
    final cy = (pys.reduce(math.max) + pys.reduce(math.min)) / 2;
    final originX = (cx - canvas / 2).round();
    final originY = (cy - canvas / 2).round();

    final basemap = await _buildBasemap(z, originX, originY, canvas);
    if (basemap.fetchedAny) {
      yield LogEvent('Fetched ${basemap.tilesFetched} CARTO basemap tile(s)');
    } else {
      yield const LogEvent(
        'basemap tiles unavailable; rendering without basemap',
        level: LogLevel.warning,
      );
    }

    final canvasPoints = [
      for (var i = 0; i < points.length; i++)
        (x: pxs[i] - originX, y: pys[i] - originY),
    ];

    final image = _composeHeatmap(basemap.image, canvasPoints, options.dpi);

    final outFile = File(options.outputPng);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(img.encodePng(image));
    yield LogEvent('Wrote ${options.outputPng}');

    yield DoneEvent({'mapped': points.length});
  }

  /// Batch-reads numeric GPS for every path in one exiftool call.
  ///
  /// Throws if exiftool cannot be launched or returns a non-zero exit, which the
  /// caller maps to a `missing_toolkit` error.
  Future<List<GeoPoint>> _readGps(List<String> photos) async {
    final result = await _runner.run('exiftool', [
      '-json',
      '-n',
      '-GPSLatitude',
      '-GPSLongitude',
      ...photos,
    ]);
    if (!result.ok && result.stdout.trim().isEmpty) {
      throw StateError('exiftool failed: ${result.stderr}');
    }
    final decoded = jsonDecode(result.stdout) as List<dynamic>;
    final points = <GeoPoint>[];
    for (final entry in decoded) {
      final map = entry as Map<String, dynamic>;
      final lat = exifAsDouble(map['GPSLatitude']);
      final lon = exifAsDouble(map['GPSLongitude']);
      if (lat == null || lon == null) continue;
      final source = (map['SourceFile'] as String?) ?? '';
      points.add(GeoPoint(lat, lon, p.basenameWithoutExtension(source)));
    }
    return points;
  }

  /// Builds the basemap image covering the canvas, fetching every needed tile.
  ///
  /// Always returns a full-canvas image; on total tile failure it is a plain
  /// light background and [_Basemap.fetchedAny] is false.
  Future<_Basemap> _buildBasemap(
    int z,
    int originX,
    int originY,
    int canvas,
  ) async {
    final base = img.Image(width: canvas, height: canvas)
      ..clear(img.ColorRgb8(242, 242, 240));

    final tileMinX = (originX / _tileSize).floor();
    final tileMaxX = ((originX + canvas) / _tileSize).floor();
    final tileMinY = (originY / _tileSize).floor();
    final tileMaxY = ((originY + canvas) / _tileSize).floor();
    final n = 1 << z;

    var fetched = 0;
    for (var tx = tileMinX; tx <= tileMaxX; tx++) {
      for (var ty = tileMinY; ty <= tileMaxY; ty++) {
        if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
        final tile = await _fetchTile(z, tx, ty);
        if (tile == null) continue;
        fetched++;
        img.compositeImage(
          base,
          tile,
          dstX: tx * _tileSize - originX,
          dstY: ty * _tileSize - originY,
        );
      }
    }
    return _Basemap(base, fetched);
  }

  /// Fetches one CARTO Positron `@2x` tile, retrying up to 3 times on failure.
  ///
  /// Returns null when every attempt fails (offline / 404), so the caller can
  /// fall back to a basemap-less render.
  Future<img.Image?> _fetchTile(int z, int x, int y) async {
    final url = Uri.parse(
      'https://basemaps.cartocdn.com/light_all/$z/$x/$y@2x.png',
    );
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        // Bound each request so a stalled connection can't hang the whole
        // render — a timeout falls through to backoff/retry, then to a
        // basemap-less render.
        final res = await _client.get(url).timeout(const Duration(seconds: 12));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          final decoded = img.decodePng(res.bodyBytes);
          if (decoded != null) return decoded;
        }
      } on Object {
        // Network error — fall through to backoff/retry.
      }
      await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
    }
    return null;
  }

  /// Accumulates the intensity field, paints the warm gradient over [basemap],
  /// then stamps a crisp dot per point.
  img.Image _composeHeatmap(
    img.Image basemap,
    List<({double x, double y})> points,
    int dpi,
  ) {
    final w = basemap.width;
    final h = basemap.height;
    final radius = (dpi / 8).clamp(8, 60).toDouble();
    final field = _accumulate(points, w, h, radius);
    _paintGradient(basemap, field, w, h);
    _stampDots(basemap, points, dpi);
    return basemap;
  }

  /// Builds a normalised (0..1) intensity buffer with a Gaussian falloff per
  /// point. The kernel is clamped to a box of side ~3σ for speed.
  Float32List _accumulate(
    List<({double x, double y})> points,
    int w,
    int h,
    double radius,
  ) {
    final field = Float32List(w * h);
    final sigma = radius;
    final twoSigmaSq = 2 * sigma * sigma;
    final reach = (sigma * 3).ceil();
    for (final pt in points) {
      final px = pt.x.round();
      final py = pt.y.round();
      final x0 = math.max(0, px - reach);
      final x1 = math.min(w - 1, px + reach);
      final y0 = math.max(0, py - reach);
      final y1 = math.min(h - 1, py + reach);
      for (var y = y0; y <= y1; y++) {
        final dy = y - pt.y;
        for (var x = x0; x <= x1; x++) {
          final dx = x - pt.x;
          final d2 = dx * dx + dy * dy;
          field[y * w + x] += math.exp(-d2 / twoSigmaSq);
        }
      }
    }
    var maxV = 0.0;
    for (final v in field) {
      if (v > maxV) maxV = v;
    }
    if (maxV > 0) {
      for (var i = 0; i < field.length; i++) {
        field[i] = field[i] / maxV;
      }
    }
    return field;
  }

  /// Alpha-composites the warm gradient (transparent → yellow → orange → red)
  /// derived from the normalised [field] over [base].
  void _paintGradient(img.Image base, Float32List field, int w, int h) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final t = field[y * w + x];
        if (t <= 0.02) continue;
        final (r, g, b, a) = _gradient(t);
        if (a == 0) continue;
        base.setPixel(x, y, _blend(base.getPixel(x, y), r, g, b, a));
      }
    }
  }

  /// Maps intensity [t] (0..1) to an RGBA colour on the warm density ramp.
  (int, int, int, int) _gradient(double t) {
    // Alpha eases in so faint areas stay translucent over the basemap.
    final a = (math.min(1.0, t * 1.4) * 200).round();
    if (t < 0.33) {
      // transparent yellow
      return (255, 235, 59, (a * 0.85).round());
    } else if (t < 0.66) {
      // yellow → orange
      final k = (t - 0.33) / 0.33;
      return (255, (235 - 83 * k).round(), (59 - 59 * k).round(), a);
    } else {
      // orange → red
      final k = (t - 0.66) / 0.34;
      return (255, (152 - 152 * k).round(), 0, a);
    }
  }

  /// Source-over alpha blend of (r,g,b,a) onto [dst].
  img.Color _blend(img.Color dst, int r, int g, int b, int a) {
    final af = a / 255.0;
    return img.ColorRgb8(
      (r * af + dst.r * (1 - af)).round(),
      (g * af + dst.g * (1 - af)).round(),
      (b * af + dst.b * (1 - af)).round(),
    );
  }

  /// Draws a small filled red dot with a thin white outline per point so single
  /// or sparse points stay visible above the heat field.
  void _stampDots(
    img.Image base,
    List<({double x, double y})> points,
    int dpi,
  ) {
    final dot = (dpi / 50).clamp(3, 7).toInt();
    final white = img.ColorRgb8(255, 255, 255);
    final red = img.ColorRgb8(214, 40, 40);
    for (final pt in points) {
      final x = pt.x.round();
      final y = pt.y.round();
      if (x < 0 || y < 0 || x >= base.width || y >= base.height) continue;
      img.fillCircle(
        base,
        x: x,
        y: y,
        radius: dot + 1,
        color: white,
        antialias: true,
      );
      img.fillCircle(
        base,
        x: x,
        y: y,
        radius: dot,
        color: red,
        antialias: true,
      );
    }
  }
}

/// A composited basemap plus how many tiles were actually fetched.
class _Basemap {
  const _Basemap(this.image, this.tilesFetched);

  final img.Image image;
  final int tilesFetched;

  bool get fetchedAny => tilesFetched > 0;
}
