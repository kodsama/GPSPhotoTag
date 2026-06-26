import 'explore_model.dart';

/// The state of the photo-detail overlay: which [MapPoint] is open and which
/// photo within it is showing.
///
/// A point can hold several photos (a burst at one spot), so the overlay pages
/// through them with prev/next and a "1 / N" counter. This class is pure and
/// immutable so the paging arithmetic — wrap-around, the counter, the single-
/// vs-multi distinction — is unit testable without a widget.
class DetailSelection {
  /// Opens [point] at [index] (clamped into range).
  DetailSelection({required this.point, int index = 0})
    : index = point.photos.isEmpty
          ? 0
          : index.clamp(0, point.photos.length - 1);

  /// The point whose photos are being viewed.
  final MapPoint point;

  /// The zero-based index of the currently shown photo within [point].
  final int index;

  /// The photo currently shown.
  ExplorePhoto get current => point.photos[index];

  /// Total photos at this point.
  int get total => point.photos.length;

  /// Whether the point holds more than one photo (shows the pager).
  bool get isMulti => total > 1;

  /// The human "1 / N" counter (1-based current over total).
  String get counter => '${index + 1} / $total';

  /// The selection moved one photo forward, wrapping at the end.
  DetailSelection next() =>
      DetailSelection(point: point, index: (index + 1) % total);

  /// The selection moved one photo back, wrapping at the start.
  DetailSelection previous() =>
      DetailSelection(point: point, index: (index - 1 + total) % total);
}

/// Decides whether an open detail overlay should close given a camera zoom
/// change from [openedAtZoom] to [currentZoom].
///
/// The rule: close as soon as the user zooms out past where the overlay was
/// opened (clusters start re-forming), with a small [hysteresis] so ordinary
/// jitter or a slight zoom-*in* never dismisses it. Zooming further in keeps it
/// open. Pure so the threshold is unit testable.
bool shouldCloseOnZoom(
  double openedAtZoom,
  double currentZoom, {
  double hysteresis = 0.5,
}) => currentZoom < openedAtZoom - hysteresis;
