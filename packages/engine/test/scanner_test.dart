import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';
import 'package:test/test.dart';

/// A minimal but valid Google Records.json head (contains the `locations`
/// marker the scanner sniffs for).
const _googleRecords =
    '{"locations": [{"latitudeE7": 425000000, '
    '"longitudeE7": 181000000, "timestamp": "2026-06-22T12:43:38Z"}]}';

/// Builds a nested tree mixing photo formats, GPS sources, Google candidates,
/// and unsupported files across split subfolders.
///
/// Layout (paths relative to the temp root):
///   `2025/06/a.jpg`, `b.png`, `e.webp`
///   `RAF/c.raf`, `d.cr3`
///   `gps/track.gpx`, `places.kml`, `history.json` (real Google), `app.json`
///   `media/clip.mp4`, `scan.tif`, `ride.fit`, `notes.txt`
///   `empty/` (empty dir)
Directory _buildTree() {
  final root = Directory.systemTemp.createTempSync('scan');
  void write(String rel, [String content = 'x']) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  write(p.join('2025', '06', 'a.jpg'));
  write(p.join('2025', '06', 'b.png'));
  write(p.join('2025', '06', 'e.webp'));
  write(p.join('RAF', 'c.raf'));
  write(p.join('RAF', 'd.cr3'));
  write(p.join('gps', 'track.gpx'));
  write(p.join('gps', 'places.kml'));
  write(p.join('gps', 'history.json'), _googleRecords);
  write(p.join('gps', 'app.json'), '{"foo": 1}'); // not Google -> other
  write(p.join('media', 'clip.mp4'));
  write(p.join('media', 'scan.tif'));
  write(p.join('media', 'ride.fit'));
  write('notes.txt');
  Directory(p.join(root.path, 'empty')).createSync();
  return root;
}

Future<FolderScanResult> _resultOf(List<ScanEvent> events) async =>
    events.whereType<ScanDoneEvent>().single.result;

void main() {
  late Directory root;
  setUp(() => root = _buildTree());
  tearDown(() => root.deleteSync(recursive: true));

  test('classifies a nested mixed tree with exact counts', () async {
    final events = await FolderScanner().scan([root.path]).toList();
    final r = await _resultOf(events);

    expect(r.files, 13);
    // roots(1) + 2025 + 2025/06 + RAF + gps + media + empty = 7
    expect(r.dirs, 7);

    // 5 photos: jpg, png, webp, raf, cr3
    expect(r.photoCount, 5);
    expect(r.photos.map(p.basename).toSet(), {
      'a.jpg',
      'b.png',
      'e.webp',
      'c.raf',
      'd.cr3',
    });

    // gpx + kml are both tracks; google = validated json only.
    expect(r.gpxCount, 1);
    expect(r.kmlCount, 1);
    expect(r.trackCount, 2);
    expect(r.trackFiles.map(p.basename).toSet(), {'track.gpx', 'places.kml'});
    expect(r.googleCount, 1);
    expect(r.googleFiles.map(p.basename), ['history.json']);

    // unsupported: app.json(other), clip.mp4(video), scan.tif(image),
    // ride.fit(gpsData), notes.txt(other) = 5
    expect(r.unsupportedCount, 5);
    expect(r.unsupportedByCategory, {
      UnsupportedCategory.other: 2, // app.json + notes.txt
      UnsupportedCategory.video: 1,
      UnsupportedCategory.image: 1,
      UnsupportedCategory.gpsData: 1,
    });
    expect(r.unsupportedByExtension, {
      'json': 1,
      'mp4': 1,
      'tif': 1,
      'fit': 1,
      'txt': 1,
    });

    expect(r.byExtension['webp'], 1);
    expect(r.photosByFormat['webp'], 1);
  });

  test('a non-Google .json is unsupported/other, not a Google file', () async {
    final events = await FolderScanner().scan([root.path]).toList();
    final r = await _resultOf(events);
    final appJson = r.unsupported.firstWhere(
      (u) => p.basename(u.path) == 'app.json',
    );
    expect(appJson.category, UnsupportedCategory.other);
    expect(r.googleFiles.any((f) => p.basename(f) == 'app.json'), isFalse);
  });

  test('a timeline .json is detected as Google', () async {
    final dir = Directory.systemTemp.createTempSync('gjson');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(
      p.join(dir.path, 'Timeline.json'),
    ).writeAsStringSync('{"semanticSegments": []}');
    final r = await _resultOf(await FolderScanner().scan([dir.path]).toList());
    expect(r.googleCount, 1);
    expect(r.unsupportedCount, 0);
  });

  test('unsupported categorization per extension', () async {
    final dir = Directory.systemTemp.createTempSync('cats');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final name in ['v.mp4', 'i.tif', 'g.fit', 'x.xyz']) {
      File(p.join(dir.path, name)).writeAsStringSync('x');
    }
    final r = await _resultOf(await FolderScanner().scan([dir.path]).toList());
    final byCat = {
      for (final u in r.unsupported) p.basename(u.path): u.category,
    };
    expect(byCat['v.mp4'], UnsupportedCategory.video);
    expect(byCat['i.tif'], UnsupportedCategory.image);
    expect(byCat['g.fit'], UnsupportedCategory.gpsData);
    expect(byCat['x.xyz'], UnsupportedCategory.other);
  });

  test('an unreadable .json sniffs as other, not Google (posix)', () async {
    // A permission-denied .json: openRead throws FileSystemException, the
    // sniff returns false, and the file is bucketed as unsupported/other
    // rather than aborting the directory walk.
    final dir = Directory.systemTemp.createTempSync('permjson');
    addTearDown(() {
      Process.runSync('chmod', ['644', p.join(dir.path, 'locked.json')]);
      dir.deleteSync(recursive: true);
    });
    final f = File(p.join(dir.path, 'locked.json'))
      ..writeAsStringSync('{"locations":[]}');
    Process.runSync('chmod', ['000', f.path]);

    final r = await _resultOf(await FolderScanner().scan([dir.path]).toList());
    expect(r.googleCount, 0);
    expect(r.unsupportedCount, 1);
    expect(r.unsupported.single.category, UnsupportedCategory.other);
  }, testOn: '!windows');

  test('emits at least one progress event before done', () async {
    final events = await FolderScanner(
      throttle: Duration.zero,
    ).scan([root.path]).toList();
    final doneIndex = events.indexWhere((e) => e is ScanDoneEvent);
    final firstProgress = events.indexWhere((e) => e is ScanProgressEvent);
    expect(firstProgress, greaterThanOrEqualTo(0));
    expect(firstProgress, lessThan(doneIndex));
    expect(events.last, isA<ScanDoneEvent>());
  });

  test('concurrency=1 and concurrency=16 give identical totals', () async {
    final a = await _resultOf(
      await FolderScanner(concurrency: 1).scan([root.path]).toList(),
    );
    final b = await _resultOf(
      await FolderScanner(concurrency: 16).scan([root.path]).toList(),
    );
    expect(a.files, b.files);
    expect(a.dirs, b.dirs);
    expect(a.photoCount, b.photoCount);
    expect(a.trackCount, b.trackCount);
    expect(a.googleCount, b.googleCount);
    expect(a.unsupportedCount, b.unsupportedCount);
    expect(a.byExtension, b.byExtension);
    expect(a.unsupportedByCategory, b.unsupportedByCategory);
  });

  test('empty roots list yields a done event with zero counts', () async {
    final events = await FolderScanner().scan([]).toList();
    expect(events.last, isA<ScanDoneEvent>());
    final r = (events.last as ScanDoneEvent).result;
    expect(r.files, 0);
    expect(r.dirs, 0);
  });

  test('an empty directory is handled (counted, no files)', () async {
    final empty = Directory.systemTemp.createTempSync('emptyscan');
    addTearDown(() => empty.deleteSync(recursive: true));
    final r = await _resultOf(
      await FolderScanner().scan([empty.path]).toList(),
    );
    expect(r.files, 0);
    expect(r.dirs, 1);
  });

  test('an unreadable directory is skipped with a log, not fatal', () async {
    // A path that is not a directory: list() throws FileSystemException.
    final notADir = File(p.join(root.path, 'notes.txt')).path;
    final events = await FolderScanner().scan([notADir]).toList();
    expect(events.whereType<ScanLogEvent>(), isNotEmpty);
    expect(events.last, isA<ScanDoneEvent>());
    final r = (events.last as ScanDoneEvent).result;
    expect(r.files, 0);
  });

  test('unsupported sample list is capped while counts stay exact', () async {
    final big = Directory.systemTemp.createTempSync('capscan');
    addTearDown(() => big.deleteSync(recursive: true));
    const n = FolderScanResult.unsupportedPathCap + 3;
    for (var i = 0; i < n; i++) {
      File(p.join(big.path, 'f$i.txt')).writeAsStringSync('x');
    }
    final r = await _resultOf(await FolderScanner().scan([big.path]).toList());
    expect(r.unsupportedCount, n, reason: 'count is exact');
    expect(r.unsupported.length, FolderScanResult.unsupportedPathCap);
    expect(r.unsupportedByCategory[UnsupportedCategory.other], n);
    expect(r.toJson()['unsupportedPathCapped'], isTrue);
  });

  test('result and event toJson round-trip the headline numbers', () async {
    final events = await FolderScanner(
      throttle: Duration.zero,
    ).scan([root.path]).toList();
    final done = events.whereType<ScanDoneEvent>().single;
    final json = done.toJson();
    expect(json['event'], 'scanDone');
    expect(json['photoCount'], 5);
    expect(json['trackCount'], 2);
    expect(json['googleCount'], 1);
    expect(json['unsupportedCount'], 5);
    expect(json['unsupportedPathCapped'], isFalse);
    expect((json['unsupportedByCategory']! as Map)['video'], 1);
    final samples = json['unsupported']! as List;
    expect((samples.first as Map).containsKey('category'), isTrue);

    final progress = events.whereType<ScanProgressEvent>().first.toJson();
    expect(progress['event'], 'scanProgress');
    expect(progress.containsKey('tracks'), isTrue);

    final log = const ScanLogEvent('hi').toJson();
    expect(log, {'event': 'scanLog', 'message': 'hi'});

    expect(const ScanProgress(files: 3).toJson()['files'], 3);
    expect(
      const UnsupportedFile('/a.tif', UnsupportedCategory.image).toJson(),
      {'path': '/a.tif', 'category': 'image'},
    );
  });
}
