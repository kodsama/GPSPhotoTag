import 'dart:io';

import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Collectors', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('collectors_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String touch(String relative) {
      final path = p.join(tmp.path, relative);
      Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync('x');
      return path;
    }

    test('photos: recurses, filters by extension, sorts, de-dupes', () {
      touch('a.jpg');
      touch('sub/b.RAF');
      touch('sub/deeper/c.png');
      touch('ignore.txt');
      touch('notes.md');

      // Pass the directory once and one file explicitly (already inside) to
      // exercise de-duplication of the same absolute path.
      final result = Collectors.photos([tmp.path, p.join(tmp.path, 'a.jpg')]);

      expect(result, [
        p.absolute(p.join(tmp.path, 'a.jpg')),
        p.absolute(p.join(tmp.path, 'sub', 'b.RAF')),
        p.absolute(p.join(tmp.path, 'sub', 'deeper', 'c.png')),
      ]);
      // Sorted ascending.
      final sorted = [...result]..sort();
      expect(result, sorted);
    });

    test('photos: explicit file input is filtered by extension', () {
      final jpg = touch('only.jpg');
      final txt = touch('skip.txt');
      expect(Collectors.photos([jpg]), [p.absolute(jpg)]);
      expect(Collectors.photos([txt]), isEmpty);
    });

    test('photos: non-existent path is silently ignored', () {
      expect(Collectors.photos([p.join(tmp.path, 'nope.jpg')]), isEmpty);
    });

    test('gpx: keeps only .gpx', () {
      touch('track.gpx');
      touch('other.json');
      touch('photo.jpg');
      expect(Collectors.gpx([tmp.path]), [
        p.absolute(p.join(tmp.path, 'track.gpx')),
      ]);
    });

    test('googleHistory: keeps json and kml', () {
      touch('Records.json');
      touch('Timeline.kml');
      touch('track.gpx');
      final result = Collectors.googleHistory([tmp.path]);
      expect(result, [
        p.absolute(p.join(tmp.path, 'Records.json')),
        p.absolute(p.join(tmp.path, 'Timeline.kml')),
      ]);
    });

    test('empty inputs produce empty output', () {
      expect(Collectors.photos(const []), isEmpty);
    });
  });
}
