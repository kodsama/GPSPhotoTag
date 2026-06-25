import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/explore/map_display_mode.dart';

void main() {
  group('MapDisplayMode.next', () {
    test('cycles numbers -> heatmap -> both -> numbers', () {
      expect(MapDisplayMode.numbers.next, MapDisplayMode.heatmap);
      expect(MapDisplayMode.heatmap.next, MapDisplayMode.both);
      expect(MapDisplayMode.both.next, MapDisplayMode.numbers);
    });
  });

  group('showsMarkers / showsHeatmap', () {
    test('numbers shows markers only', () {
      expect(MapDisplayMode.numbers.showsMarkers, isTrue);
      expect(MapDisplayMode.numbers.showsHeatmap, isFalse);
    });

    test('heatmap shows heat only', () {
      expect(MapDisplayMode.heatmap.showsMarkers, isFalse);
      expect(MapDisplayMode.heatmap.showsHeatmap, isTrue);
    });

    test('both shows markers and heat', () {
      expect(MapDisplayMode.both.showsMarkers, isTrue);
      expect(MapDisplayMode.both.showsHeatmap, isTrue);
    });
  });
}
