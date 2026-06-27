import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../explore/explore_interaction.dart';
import '../explore/explore_markers.dart';
import '../explore/explore_model.dart';
import '../explore/heatmap.dart';
import '../explore/map_display_mode.dart';
import '../explore/map_tile_provider.dart';
import '../explore/photo_detail_panel.dart';
import '../explore/tile_cache.dart';
import '../explore/tile_provider_scope.dart';
import '../explore/timeline_filter.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The [CameraFit] that frames ALL [points] with sensible padding, or null when
/// there are no points (so callers can no-op / disable a "fit" action).
///
/// Pure: reuses [boundsOf] and the same padding/maxZoom as the map's initial
/// fit, so the default view and the reset button share one definition of
/// "fit to photos" and it stays unit testable without a map.
CameraFit? cameraFitForPoints(List<MapPoint> points) {
  final bounds = boundsOf(points);
  if (bounds == null) return null;
  return CameraFit.bounds(
    bounds: LatLngBounds(bounds.southWest, bounds.northEast),
    padding: const EdgeInsets.all(48),
    maxZoom: 16,
  );
}

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
  /// Creates the Explore screen. [savePathPicker] overrides the native
  /// save-location panel in tests; production uses [getSaveLocation].
  const ExploreMapScreen({super.key, this.savePathPicker, this.capturePng});

  /// Resolves the destination PNG path (null = user cancelled). Injectable so
  /// the save flow can be driven without the platform save dialog.
  final Future<String?> Function()? savePathPicker;

  /// Captures the current map view as PNG bytes (null = capture failed).
  /// Injectable so the save flow is testable without the real RepaintBoundary
  /// raster, which doesn't render reliably in headless concurrent test runs.
  final Future<Uint8List?> Function()? capturePng;

  @override
  State<ExploreMapScreen> createState() => _ExploreMapScreenState();
}

class _ExploreMapScreenState extends State<ExploreMapScreen> {
  final MapController _map = MapController();
  final ExploreInteractionController _detail = ExploreInteractionController();

  /// Wraps the map stack so the current view can be captured to a PNG.
  final GlobalKey _captureKey = GlobalKey();
  bool _focusHandled = false;
  bool _initialFitDone = false;
  MapDisplayMode _mode = MapDisplayMode.numbers;
  Timer? _prefetchDebounce;

  /// Whether the Timeline range selector is shown.
  bool _timelineOpen = false;

  /// The user-selected capture-time range, or null to use the full span (show
  /// everything). Kept as raw [DateTime]s so it survives photos streaming in;
  /// it's clamped to the live span at build time.
  DateSpan? _range;

  void _cycleMode() => setState(() => _mode = _mode.next);

  void _toggleTimeline() => setState(() => _timelineOpen = !_timelineOpen);

  /// Replaces the active range (live as the slider drags), or clears it back to
  /// the full span when [range] is null ("reset range").
  void _setRange(DateSpan? range) => setState(() => _range = range);

  /// The range to actually filter by, clamped to the live [span], or null when
  /// nothing should be filtered (no dated photos, or the user hasn't narrowed
  /// the range so the full span is shown).
  DateSpan? _effectiveRange(DateSpan? span) {
    if (span == null) return null;
    final range = _range;
    if (range == null) return null;
    final start = range.start.isBefore(span.start) ? span.start : range.start;
    final end = range.end.isAfter(span.end) ? span.end : range.end;
    return (start: start, end: end);
  }

  /// Moves the camera to fit ALL [points] into view (with sensible padding),
  /// reusing the same bounds→[CameraFit] logic as the initial fit. No-op when
  /// there are no points or the map isn't laid out yet.
  void _fitToPoints(List<MapPoint> points) {
    final fit = cameraFitForPoints(points);
    if (fit == null) return;
    try {
      _map.fitCamera(fit);
    } on Object {
      /* map not laid out yet */
    }
  }

  /// On first build with points available, fit the camera to them once the map
  /// is laid out. Photos stream in after the first frame, so [initialCameraFit]
  /// alone can fit an empty/partial set; this re-fits once they've settled.
  void _maybeInitialFit(List<MapPoint> points) {
    if (_initialFitDone || points.isEmpty) return;
    _initialFitDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitToPoints(points);
    });
  }

  @override
  void initState() {
    super.initState();
    _detail.addListener(_onDetailChanged);
  }

  @override
  void dispose() {
    _prefetchDebounce?.cancel();
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

  void _onMapEvent(MapEvent event) {
    _detail.onZoom(event.source.name, event.camera.zoom);
    // Warm tiles around the view once a gesture/animation settles — debounced
    // so it never fires mid-pan/zoom (a fresh event resets the timer).
    if (_settlesPrefetch(event)) {
      _prefetchDebounce?.cancel();
      _prefetchDebounce = Timer(
        const Duration(milliseconds: 400),
        () => _prefetchAround(event.camera),
      );
    }
  }

  /// True for the map events that mark the END of a pan/zoom (so prefetch only
  /// runs once the view has settled, not on every intermediate frame).
  static bool _settlesPrefetch(MapEvent event) =>
      event is MapEventMoveEnd ||
      event is MapEventFlingAnimationEnd ||
      event is MapEventDoubleTapZoomEnd ||
      event is MapEventScrollWheelZoom ||
      event is MapEventRotateEnd;

  /// Warms the tiles around [camera] (viewport + margin ring + one zoom level
  /// either side) into the disk cache at low priority. No-op without a caching
  /// provider in scope (e.g. widget tests).
  void _prefetchAround(MapCamera camera) {
    final provider = TileProviderScope.maybeOf(context);
    if (provider is! CachingTileProvider) return;
    final bounds = camera.visibleBounds;
    final coords = prefetchTileCoordinates(
      north: bounds.north,
      south: bounds.south,
      east: bounds.east,
      west: bounds.west,
      zoom: camera.zoom.round(),
    );
    for (final (z, x, y) in coords) {
      unawaited(provider.cache.prefetch(z, x, y));
    }
  }

  void _openFullscreen() {
    final selection = _detail.selection;
    if (selection == null) return;
    final photo = selection.current;
    openFullscreen(context, photo.path, meta: photo.meta);
  }

  /// Captures the current on-screen map view (tiles + heatmap + markers as
  /// framed) and saves it to a user-chosen PNG path.
  ///
  /// The two side-effecting shells — capturing the [RepaintBoundary] to PNG
  /// bytes and opening the native save panel — are the only uncovered parts;
  /// the pick→write→report logic lives in [AppController.savePng]. Reports the
  /// outcome via a SnackBar (and the activity log) and never throws.
  Future<void> _saveView() async {
    final controller = ControllerScope.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final captureFailed = context.tr('explore_capture_failed');
    final bytes = await (widget.capturePng ?? _capturePng)();
    if (bytes == null) {
      messenger?.showSnackBar(SnackBar(content: Text(captureFailed)));
      return;
    }
    final saved = await controller.savePng(
      bytes,
      pickPath: widget.savePathPicker ?? _pickSavePath,
    );
    // The save can outlive this screen (the user may navigate away mid-write);
    // don't touch a disposed messenger.
    if (saved != null && mounted) {
      final msg = context.tr('explore_saved_to', {'path': saved});
      messenger?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Opens the native save panel and returns the chosen path (null on cancel).
  /// The only genuinely-untestable shell of the save flow.
  Future<String?> _pickSavePath() async {
    final png = XTypeGroup(
      label: context.tr('explore_png_image'),
      extensions: const ['png'],
    );
    final location = await getSaveLocation(
      suggestedName: context.tr('explore_save_filename'),
      acceptedTypeGroups: [png],
    );
    return location?.path;
  }

  /// Renders the captured map [RepaintBoundary] to PNG bytes at the screen's
  /// device pixel ratio, or null when the boundary isn't laid out yet or the
  /// encode produced nothing.
  Future<Uint8List?> _capturePng() async {
    final boundary =
        _captureKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
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
    final allPhotos = controller.explorePhotos;
    // The full selectable span across every dated photo (null when none are
    // dated — the Timeline button is then disabled and the selector hidden).
    final span = dateSpanOf(allPhotos);
    // The active range, clamped to the live span (which grows as photos stream
    // in); null span means no filtering at all.
    final active = _effectiveRange(span);
    final photos = active == null
        ? allPhotos
        : filterPhotosByDateRange(
            allPhotos,
            start: active.start,
            end: active.end,
          );
    final points = groupPhotosIntoPoints(photos);
    _maybeHandleFocus(controller, points);
    _maybeInitialFit(points);
    final selection = _detail.selection;

    return Stack(
      children: [
        RepaintBoundary(
          key: _captureKey,
          child: _MapShell(
            mapController: _map,
            points: points,
            photos: photos,
            mode: _mode,
            onMapEvent: _onMapEvent,
            onMarkerTap: _onMarkerTap,
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          child: _BackButton(onPressed: controller.closeExplore),
        ),
        // Top-right controls: a "fit to photos" reset button sits immediately
        // left of the mode button; the loading chip stacks just below the row
        // so nothing overlaps.
        Positioned(
          top: 12,
          right: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Timeline is offered only when something is datable; with no
                  // dated photos there's no span to filter, so it's hidden.
                  if (span != null) ...[
                    _TimelineButton(
                      active: _timelineOpen,
                      onPressed: _toggleTimeline,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _ResetButton(
                    onPressed: points.isEmpty
                        ? null
                        : () => _fitToPoints(points),
                  ),
                  const SizedBox(width: 8),
                  _SaveButton(onPressed: points.isEmpty ? null : _saveView),
                  const SizedBox(width: 8),
                  _ModeButton(mode: _mode, onPressed: _cycleMode),
                ],
              ),
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
        if (_timelineOpen && span != null)
          Positioned(
            bottom: 16,
            left: 12,
            right: 12,
            child: Center(
              child: TimelinePanel(
                span: span,
                // The slider shows the full span until narrowed; once narrowed,
                // the clamped active range.
                selected: active ?? span,
                onChanged: _setRange,
                onReset: () => _setRange(null),
                onClose: _toggleTimeline,
              ),
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
    required this.photos,
    required this.mode,
    required this.onMapEvent,
    required this.onMarkerTap,
  });

  final MapController mapController;
  final List<MapPoint> points;
  final List<ExplorePhoto> photos;
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
        if (mode.showsHeatmap) HeatmapLayer(photos: photos),
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

/// The upper-right "fit to photos" button, sitting just left of the mode
/// button. Tapping it re-frames the camera on all photo points; it's disabled
/// (greyed, non-tappable) when [onPressed] is null (no points).
class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onPressed});

  /// The fit action, or null to render disabled (no points to fit).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: context.tr('explore_fit'),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        elevation: 3,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Icon(
              Icons.fit_screen,
              size: 18,
              color: enabled ? null : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// The upper-right "Save view as PNG" button, sitting between the fit and mode
/// buttons. Tapping it captures the current map view and opens a native save
/// panel; it's disabled (greyed, non-tappable) when [onPressed] is null (no
/// points to export).
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onPressed});

  /// The save action, or null to render disabled (no points to export).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: context.tr('explore_save_png'),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        elevation: 3,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Icon(
              Icons.save_alt,
              size: 18,
              color: enabled ? null : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// The upper-right "Timeline" pill that toggles the date/time range selector.
/// Highlighted (filled with the primary colour) while the selector is [active].
class _TimelineButton extends StatelessWidget {
  const _TimelineButton({required this.active, required this.onPressed});

  /// Whether the selector is currently shown (renders the pill highlighted).
  final bool active;

  /// Toggles the selector open/closed.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = active ? scheme.onPrimary : scheme.onSurface;
    return Tooltip(
      message: context.tr('explore_filter_by_date'),
      child: Material(
        color: active ? scheme.primary : scheme.surface,
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
                Icon(Icons.schedule, size: 18, color: fg),
                const SizedBox(width: 8),
                Text(
                  context.tr('explore_timeline'),
                  style: TextStyle(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
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
    MapDisplayMode.numbers => (Icons.tag, 'explore_mode_numbers'),
    MapDisplayMode.heatmap => (
      Icons.local_fire_department,
      'explore_mode_heatmap',
    ),
    MapDisplayMode.both => (Icons.layers, 'explore_mode_both'),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, labelKey) = _face(mode);
    final label = context.tr(labelKey);
    return Tooltip(
      message: context.tr('tt_explore_mode'),
      child: Material(
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
      ),
    );
  }
}

/// The overlaid bottom panel that filters the map by a capture-time range.
///
/// A dual-handle [RangeSlider] spans the photos' full [span]; the [selected]
/// start/end are shown as tappable labels that open precise date+time pickers.
/// Dragging the slider or picking a date calls [onChanged] live (the screen
/// re-filters markers AND heatmap on every change). A "reset range" affordance
/// ([onReset]) restores the full span; [onClose] hides the panel.
///
/// Pure presentation: it holds no range state of its own — the active range
/// lives in the screen — so the slider always reflects [selected].
class TimelinePanel extends StatelessWidget {
  /// Creates the range selector for [span], showing [selected] on the handles.
  const TimelinePanel({
    super.key,
    required this.span,
    required this.selected,
    required this.onChanged,
    required this.onReset,
    required this.onClose,
  });

  /// The full selectable span (slider min/max).
  final DateSpan span;

  /// The currently selected sub-range (slider handle positions).
  final DateSpan selected;

  /// Called with the new range as a handle drags or a date is picked.
  final ValueChanged<DateSpan> onChanged;

  /// Resets the range back to the full [span].
  final VoidCallback onReset;

  /// Hides the panel.
  final VoidCallback onClose;

  /// Whether the user has narrowed the range from the full span (enables reset).
  bool get _isNarrowed =>
      selected.start != span.start || selected.end != span.end;

  /// True when the whole library was captured at a single instant — there's
  /// nothing to slide between, so the slider is omitted (labels still show).
  bool get _zeroWidth => !span.end.isAfter(span.start);

  String _label(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<void> _pick(BuildContext context, {required bool isStart}) async {
    final current = isStart ? selected.start : selected.end;
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: span.start,
      lastDate: span.end,
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? current.hour,
      time?.minute ?? current.minute,
    );
    // Clamp into the span and keep start <= end.
    final clamped = picked.isBefore(span.start)
        ? span.start
        : (picked.isAfter(span.end) ? span.end : picked);
    if (isStart) {
      final end = clamped.isAfter(selected.end) ? clamped : selected.end;
      onChanged((start: clamped, end: end));
    } else {
      final start = clamped.isBefore(selected.start) ? clamped : selected.start;
      onChanged((start: start, end: clamped));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Card(
        color: scheme.surface.withValues(alpha: 0.96),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.date_range, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    context.tr('explore_date_range'),
                    style: text.titleSmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _isNarrowed ? onReset : null,
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: Text(context.tr('explore_reset_range')),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: context.tr('explore_hide_timeline'),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _DateLabel(
                    label: _label(selected.start),
                    onTap: () => _pick(context, isStart: true),
                  ),
                  _DateLabel(
                    label: _label(selected.end),
                    onTap: () => _pick(context, isStart: false),
                  ),
                ],
              ),
              if (!_zeroWidth)
                RangeSlider(
                  min: dateTimeToSliderValue(span.start),
                  max: dateTimeToSliderValue(span.end),
                  values: RangeValues(
                    dateTimeToSliderValue(selected.start),
                    dateTimeToSliderValue(selected.end),
                  ),
                  labels: RangeLabels(
                    _label(selected.start),
                    _label(selected.end),
                  ),
                  onChanged: (values) => onChanged((
                    start: sliderValueToDateTime(values.start),
                    end: sliderValueToDateTime(values.end),
                  )),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable capture-time label inside [TimelinePanel] that opens a precise
/// date+time picker for exact input.
class _DateLabel extends StatelessWidget {
  const _DateLabel({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
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
    return Tooltip(
      message: context.tr('tt_explore_back'),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
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
                const Icon(Icons.arrow_back, size: 18),
                const SizedBox(width: 8),
                Text(context.tr('explore_back')),
              ],
            ),
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
              context.tr('explore_loading', {'loaded': loaded, 'total': total}),
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
        Text(context.tr('explore_empty_title'), style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          context.tr('explore_empty_desc'),
          style: text.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
