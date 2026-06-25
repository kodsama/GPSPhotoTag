import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../explore/explore_interaction.dart';
import '../explore/explore_markers.dart';
import '../explore/explore_model.dart';
import '../explore/heatmap.dart';
import '../explore/map_display_mode.dart';
import '../explore/photo_detail_panel.dart';
import '../explore/tile_provider_scope.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A flutter_map [Marker] that remembers the [MapPoint] it represents, so a tap
/// can open the right photo(s) in the detail panel.
class PhotoMarker extends Marker {
  /// Creates a marker for [mapPoint].
  PhotoMarker({required this.mapPoint, required super.child})
    : super(point: mapPoint.position, width: 40, height: 40);

  /// The point (one or more photos at a coordinate) behind this marker.
  final MapPoint mapPoint;
}

/// The live, pannable/zoomable Explore map.
///
/// Loads every geotagged photo as a [PhotoMarker], clusters them with
/// [MarkerClusterLayerWidget] (clusters break apart into individual points as
/// you zoom in), fits the camera to the points' bounding box, and opens a
/// [PhotoDetailPanel] on tap. Zooming out past where the panel opened closes it
/// (see [shouldCloseOnZoom]). The [FlutterMap] glue here is a thin shell; the
/// grouping, paging and close-rule logic live in pure, unit-tested classes.
class ExploreMapScreen extends StatefulWidget {
  /// Creates the Explore screen.
  const ExploreMapScreen({super.key});

  @override
  State<ExploreMapScreen> createState() => _ExploreMapScreenState();
}

class _ExploreMapScreenState extends State<ExploreMapScreen> {
  final MapController _map = MapController();
  final ExploreInteractionController _detail = ExploreInteractionController();
  bool _focusHandled = false;
  MapDisplayMode _mode = MapDisplayMode.numbers;

  void _cycleMode() => setState(() => _mode = _mode.next);

  @override
  void initState() {
    super.initState();
    _detail.addListener(_onDetailChanged);
  }

  @override
  void dispose() {
    _detail
      ..removeListener(_onDetailChanged)
      ..dispose();
    super.dispose();
  }

  void _onDetailChanged() => setState(() {});

  /// The current camera zoom, or 0 before the map is attached/laid out.
  double _cameraZoom() {
    try {
      return _map.camera.zoom;
    } on Object {
      return 0;
    }
  }

  void _onMarkerTap(MapPoint point) =>
      _detail.open(point, atZoom: _cameraZoom());

  void _onMapEvent(MapEvent event) =>
      _detail.onZoom(event.source.name, event.camera.zoom);

  void _openFullscreen() {
    final selection = _detail.selection;
    if (selection == null) return;
    openFullscreen(context, selection.current.path);
  }

  /// If the controller asked to focus a specific photo (deep-link from the file
  /// list), open its detail immediately and schedule a camera move to it.
  ///
  /// Called from [build]: it opens the overlay synchronously (so the panel is
  /// part of this very frame), then moves the camera in a post-frame callback
  /// once the map is laid out.
  void _maybeHandleFocus(AppController controller, List<MapPoint> points) {
    final focus = controller.exploreFocusPath;
    if (focus == null || _focusHandled) return;
    for (final point in points) {
      final i = point.photos.indexWhere((p) => p.path == focus);
      if (i >= 0) {
        _focusHandled = true;
        controller.clearExploreFocus();
        _detail.open(point, index: i, atZoom: 16);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Best-effort camera move; the panel is already open regardless.
          try {
            _map.move(point.position, 16);
          } on Object {
            /* map not laid out yet */
          }
        });
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final points = groupPhotosIntoPoints(controller.explorePhotos);
    _maybeHandleFocus(controller, points);
    final selection = _detail.selection;

    return Stack(
      children: [
        _MapShell(
          mapController: _map,
          points: points,
          mode: _mode,
          onMapEvent: _onMapEvent,
          onMarkerTap: _onMarkerTap,
        ),
        Positioned(
          top: 12,
          left: 12,
          child: _BackButton(onPressed: controller.closeExplore),
        ),
        // Mode button top-right; the loading chip stacks just below it so the
        // two never overlap.
        Positioned(
          top: 12,
          right: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _ModeButton(mode: _mode, onPressed: _cycleMode),
              if (controller.exploreLoading) ...[
                const SizedBox(height: 8),
                _LoadingChip(
                  loaded: controller.exploreLoaded,
                  total: controller.exploreTotal,
                ),
              ],
            ],
          ),
        ),
        if (!controller.exploreLoading && points.isEmpty)
          const Center(child: _EmptyState()),
        if (selection != null)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: PhotoDetailPanel(
                selection: selection,
                onPrev: _detail.previous,
                onNext: _detail.next,
                onClose: _detail.close,
                onExpand: _openFullscreen,
              ),
            ),
          ),
      ],
    );
  }
}

/// The bare FlutterMap + cluster layer. Kept as a thin glue shell (the only
/// part of the feature that stays uncovered by unit tests).
class _MapShell extends StatelessWidget {
  const _MapShell({
    required this.mapController,
    required this.points,
    required this.mode,
    required this.onMapEvent,
    required this.onMarkerTap,
  });

  final MapController mapController;
  final List<MapPoint> points;
  final MapDisplayMode mode;
  final void Function(MapEvent) onMapEvent;
  final void Function(MapPoint) onMarkerTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bounds = boundsOf(points);
    final markers = [
      for (final point in points)
        PhotoMarker(
          mapPoint: point,
          child: PhotoPin(count: point.count, color: scheme.primary),
        ),
    ];

    // Persistent disk-cached tiles in the real app; plain network in tests.
    final tileProvider =
        TileProviderScope.maybeOf(context) ?? NetworkTileProvider();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        onMapEvent: onMapEvent,
        // Not-yet-loaded areas read as paper, not grey.
        backgroundColor: isDark ? AppColors.duskSunk : AppColors.paperSunk,
        initialCenter: bounds == null
            ? const LatLng(20, 0)
            : LatLng(
                (bounds.southWest.latitude + bounds.northEast.latitude) / 2,
                (bounds.southWest.longitude + bounds.northEast.longitude) / 2,
              ),
        initialZoom: bounds == null ? 2 : 4,
        initialCameraFit: bounds == null
            ? null
            : CameraFit.bounds(
                bounds: LatLngBounds(bounds.southWest, bounds.northEast),
                padding: const EdgeInsets.all(48),
                maxZoom: 16,
              ),
        minZoom: 2,
        // Allow zooming past native (19) — the last tile upscales instead of
        // going grey.
        maxZoom: 20,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'github.com/kodsama/stunda',
          tileProvider: tileProvider,
          // Past native zoom flutter_map upscales the z19 tile.
          maxNativeZoom: 19,
          // Keep adjacent tiles warm so panning/zooming isn't grey.
          keepBuffer: 4,
          panBuffer: 2,
        ),
        if (mode.showsHeatmap) HeatmapLayer(points: points),
        if (mode.showsMarkers)
          MarkerClusterLayerWidget(
            options: MarkerClusterLayerOptions(
              maxClusterRadius: 60,
              size: const Size(44, 44),
              disableClusteringAtZoom: 17,
              markers: markers,
              onMarkerTap: (marker) {
                if (marker is PhotoMarker) onMarkerTap(marker.mapPoint);
              },
              builder: (context, clusterMarkers) => ClusterBadge(
                count: clusterMarkers.length,
                color: scheme.primary,
              ),
            ),
          ),
      ],
    );
  }
}

/// The upper-right button that cycles the map display mode (Numbers → Heatmap →
/// Both). Shows an icon + label reflecting the current [mode].
class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.onPressed});

  final MapDisplayMode mode;
  final VoidCallback onPressed;

  static (IconData, String) _face(MapDisplayMode mode) => switch (mode) {
    MapDisplayMode.numbers => (Icons.tag, 'Numbers'),
    MapDisplayMode.heatmap => (Icons.local_fire_department, 'Heatmap'),
    MapDisplayMode.both => (Icons.layers, 'Both'),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label) = _face(mode);
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      elevation: 3,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "← Map" / back-to-library affordance overlaid on the map.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      elevation: 3,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back, size: 18),
              SizedBox(width: 8),
              Text('Library'),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "loading coordinates N/M" chip shown while metadata streams in.
class _LoadingChip extends StatelessWidget {
  const _LoadingChip({required this.loaded, required this.total});

  final int loaded;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(20),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'loading coordinates $loaded/$total',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the library has no geotagged photos to plot.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.location_off_outlined, size: 40),
        const SizedBox(height: 10),
        Text('No geotagged photos to show.', style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Tag your photos with GPS first, then explore them here.',
          style: text.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
