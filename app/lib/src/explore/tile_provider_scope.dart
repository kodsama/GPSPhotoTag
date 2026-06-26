import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// Makes the app-wide map [TileProvider] available to the Explore screen
/// without threading it through the controller.
///
/// The real app installs a [TileProvider] backed by the persistent disk cache
/// (resolved once at startup); when absent (e.g. in widget tests) the Explore
/// screen falls back to a plain [NetworkTileProvider].
class TileProviderScope extends InheritedWidget {
  /// Wraps [child], exposing [tileProvider] to descendants.
  const TileProviderScope({
    super.key,
    required this.tileProvider,
    required super.child,
  });

  /// The provider Explore's [TileLayer] should use.
  final TileProvider tileProvider;

  /// The nearest provider, or null when none is in scope.
  static TileProvider? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TileProviderScope>()
      ?.tileProvider;

  @override
  bool updateShouldNotify(TileProviderScope oldWidget) =>
      oldWidget.tileProvider != tileProvider;
}
