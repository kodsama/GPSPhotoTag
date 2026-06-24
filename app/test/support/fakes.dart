import 'dart:async';
import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:gpsphototag_gui/src/engine/engine_runner.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// A scripted [EngineRunner] that returns a canned [EngineEvent] stream for
/// every operation without spawning a single isolate. Each method records that
/// it was called so tests can assert the wiring, and yields whatever events the
/// constructor was handed (defaulting to a one-item success run).
class FakeEngineRunner implements EngineRunner {
  FakeEngineRunner({List<EngineEvent>? events, this.keepOpen = false})
      : _events = events ?? _success();

  final List<EngineEvent> _events;

  /// When true the returned stream stays open after the scripted events, so the
  /// controller's `running` state (and the live progress UI) persists for
  /// assertions. Tests gate completion via [release].
  final bool keepOpen;
  final _gate = Completer<void>();

  /// Lets a [keepOpen] stream finish (fires onDone in the controller).
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  /// Names of the operations invoked, in order (`tag`, `map`, `prune`, ...).
  final List<String> calls = [];

  /// The [TagOptions] passed to the last [tag] call, for assertions.
  TagOptions? lastTagOptions;

  static List<EngineEvent> _success() => [
        const LogEvent('working'),
        const ProgressEvent(done: 1, total: 1),
        const ItemEvent(PhotoRow(
          path: '/photos/a.jpg',
          status: PhotoStatus.tagged,
          location: LocationResult(
            latitude: 42.5,
            longitude: 18.1,
            source: GpsSource.gpx,
            method: GpsMethod.exact,
          ),
        )),
        const DoneEvent({'tagged': 1}),
      ];

  Stream<EngineEvent> _emit() async* {
    for (final event in _events) {
      yield event;
    }
    if (keepOpen) await _gate.future;
  }

  @override
  Stream<EngineEvent> tag({
    required List<String> photos,
    required List<String> gpxFiles,
    required List<String> googleFiles,
    required TagOptions options,
  }) {
    calls.add('tag');
    lastTagOptions = options;
    return _emit();
  }

  @override
  Stream<EngineEvent> map({
    required List<String> photos,
    required MapOptions options,
  }) {
    calls.add('map');
    // Write a tiny real PNG so result_step's Image.file has a file to point at.
    File(options.outputPng)
        .writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)));
    return _emit();
  }

  @override
  Stream<EngineEvent> prune({
    required List<String> roots,
    required PruneOptions options,
  }) {
    calls.add('prune');
    return _emit();
  }

  @override
  Stream<EngineEvent> fixDates({
    required List<String> files,
    required FixDatesMode mode,
    bool dryRun = false,
  }) {
    calls.add('fixDates');
    return _emit();
  }
}

/// Writes a tiny synthetic JPEG carrying [dateTimeOriginal] and returns its
/// path. Used so [AppController.pickInput] / parseInput find a real photo.
Future<String> writeJpegWithDate(
  Directory dir,
  String name, {
  DateTime? dateTimeOriginal,
}) async {
  final path = p.join(dir.path, name);
  File(path).writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
  if (dateTimeOriginal != null) {
    await const JpegExifBackend().writeGps(
      path,
      latitude: 0,
      longitude: 0,
      dateTimeOriginal: dateTimeOriginal,
    );
  }
  return path;
}

/// Writes a minimal one-point GPX file and returns its path.
String writeGpx(Directory dir, String name, DateTime time,
    {double lat = 42.5, double lon = 18.1}) {
  final path = p.join(dir.path, name);
  final iso = time.toUtc().toIso8601String();
  File(path).writeAsStringSync('''
<?xml version="1.0"?>
<gpx version="1.1" creator="test">
  <trk><trkseg>
    <trkpt lat="$lat" lon="$lon"><time>$iso</time></trkpt>
  </trkseg></trk>
</gpx>
''');
  return path;
}
