import 'package:flutter_test/flutter_test.dart';
import 'package:stunda/src/explore/explore_interaction.dart';
import 'package:stunda/src/explore/explore_model.dart';

MapPoint _point(List<String> paths) => MapPoint(
  latitude: 1,
  longitude: 2,
  photos: [
    for (final path in paths)
      ExplorePhoto(path: path, latitude: 1, longitude: 2),
  ],
);

void main() {
  group('ExploreInteractionController', () {
    test('starts closed', () {
      final c = ExploreInteractionController();
      expect(c.isOpen, isFalse);
      expect(c.selection, isNull);
    });

    test('open sets the selection, index and baseline zoom, notifies', () {
      final c = ExploreInteractionController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.open(_point(['/a.jpg', '/b.jpg']), index: 1, atZoom: 14);
      expect(c.isOpen, isTrue);
      expect(c.selection!.current.path, '/b.jpg');
      expect(c.openedAtZoom, 14);
      expect(notifications, 1);
    });

    test('close clears the selection; second close is a no-op', () {
      final c = ExploreInteractionController()
        ..open(_point(['/a.jpg']), atZoom: 14);
      var notifications = 0;
      c.addListener(() => notifications++);

      c.close();
      expect(c.isOpen, isFalse);
      expect(notifications, 1);

      c.close(); // already closed
      expect(notifications, 1);
    });

    test('next/previous page and wrap; no-op when closed', () {
      final c = ExploreInteractionController();
      // No-ops while closed.
      c.next();
      c.previous();
      expect(c.isOpen, isFalse);

      c.open(_point(['/a.jpg', '/b.jpg', '/c.jpg']), atZoom: 14);
      c.next();
      expect(c.selection!.current.path, '/b.jpg');
      c.previous();
      c.previous(); // wraps to last
      expect(c.selection!.current.path, '/c.jpg');
    });

    group('onZoom', () {
      test('no-op when closed', () {
        final c = ExploreInteractionController();
        c.onZoom('scrollWheel', 1);
        expect(c.isOpen, isFalse);
      });

      test('ignores programmatic / non-user sources', () {
        final c = ExploreInteractionController()
          ..open(_point(['/a.jpg']), atZoom: 16);
        // mapController / fitCamera moves must not close it even far out.
        c.onZoom('mapController', 2);
        c.onZoom('fitCamera', 2);
        c.onZoom('nonRotatedSizeChange', 2);
        expect(c.isOpen, isTrue);
      });

      test('a user zoom-out past the baseline closes the overlay', () {
        final c = ExploreInteractionController()
          ..open(_point(['/a.jpg']), atZoom: 16);
        c.onZoom('scrollWheel', 14);
        expect(c.isOpen, isFalse);
      });

      test('a user zoom-in keeps the overlay open', () {
        final c = ExploreInteractionController()
          ..open(_point(['/a.jpg']), atZoom: 16);
        c.onZoom('scrollWheel', 18);
        expect(c.isOpen, isTrue);
      });

      test('every declared user source is recognised', () {
        for (final source in ExploreInteractionController.userZoomSources) {
          final c = ExploreInteractionController()
            ..open(_point(['/a.jpg']), atZoom: 16);
          c.onZoom(source, 10); // well below baseline
          expect(c.isOpen, isFalse, reason: source);
        }
      });
    });
  });
}
