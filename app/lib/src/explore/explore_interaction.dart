import 'package:flutter/foundation.dart';

import 'detail_selection.dart';
import 'explore_model.dart';

/// Holds and drives the Explore map's detail-overlay state, independent of any
/// widget so it is fully unit testable.
///
/// The screen wires map callbacks to this: a marker tap calls [open]; the map's
/// zoom events call [onZoom] (which closes the overlay on a user zoom-out per
/// [shouldCloseOnZoom]); the prev/next buttons call [previous]/[next]. It
/// remembers the zoom the overlay was opened at so the close rule has a baseline.
class ExploreInteractionController extends ChangeNotifier {
  DetailSelection? _selection;
  double _openedAtZoom = 0;

  /// The open selection (point + current photo), or null when the overlay is
  /// closed.
  DetailSelection? get selection => _selection;

  /// The map zoom at which the overlay was opened (the close-rule baseline).
  double get openedAtZoom => _openedAtZoom;

  /// Whether the detail overlay is currently open.
  bool get isOpen => _selection != null;

  /// Opens the overlay on [point] at [index], recording [atZoom] as the
  /// baseline for [onZoom]'s close rule.
  void open(MapPoint point, {int index = 0, required double atZoom}) {
    _selection = DetailSelection(point: point, index: index);
    _openedAtZoom = atZoom;
    notifyListeners();
  }

  /// Closes the overlay (no-op when already closed).
  void close() {
    if (_selection == null) return;
    _selection = null;
    notifyListeners();
  }

  /// Pages to the next photo at the current point (wraps).
  void next() {
    final s = _selection;
    if (s == null) return;
    _selection = s.next();
    notifyListeners();
  }

  /// Pages to the previous photo at the current point (wraps).
  void previous() {
    final s = _selection;
    if (s == null) return;
    _selection = s.previous();
    notifyListeners();
  }

  /// The set of map-event sources that represent a *user* zoom change. Only
  /// these may dismiss the overlay; programmatic moves (camera fit, deep-link
  /// move, size changes) must not.
  static const userZoomSources = {
    'scrollWheel',
    'doubleTap',
    'doubleTapHold',
    'doubleTapZoomAnimationController',
    'onMultiFinger',
    'multiFingerEnd',
    'keyboard',
  };

  /// Reacts to a map zoom change from [sourceName] reaching [currentZoom]:
  /// closes the overlay when the user has zoomed out past where it opened.
  ///
  /// [sourceName] is the `MapEventSource.name` so this stays widget/plugin-free.
  void onZoom(String sourceName, double currentZoom) {
    if (_selection == null) return;
    if (!userZoomSources.contains(sourceName)) return;
    if (shouldCloseOnZoom(_openedAtZoom, currentZoom)) close();
  }
}
