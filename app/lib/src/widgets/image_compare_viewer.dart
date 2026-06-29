import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../explore/explore_model.dart';
import '../i18n/app_localizations.dart';
import '../state/controller_scope.dart';
import '../theme/app_theme.dart';
import 'image_compare_model.dart';

/// One image shown in the [ImageCompareViewer], with the metadata behind its
/// info line. [fileSize] is the on-disk byte count (null = omit it).
class ComparePane {
  /// Creates a pane for [path] with optional [meta]/[fileSize].
  const ComparePane({required this.path, this.meta, this.fileSize});

  /// The image file path.
  final String path;

  /// Dimensions/date/GPS behind the info line, when known.
  final FileMeta? meta;

  /// On-disk size in bytes for the info line, or null to omit.
  final int? fileSize;
}

/// Opens the [ImageCompareViewer] as a full-screen overlay.
///
/// One pane → single mode (zoom/pan + reset, no compare button); two panes →
/// compare mode (vertical curtain by default, switchable to horizontal curtain
/// or synced side-by-side).
void openImageCompare(BuildContext context, List<ComparePane> panes) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => ImageCompareViewer(panes: panes),
    ),
  );
}

/// A full-screen big-preview / before-after comparison viewer.
///
/// Renders one image (single mode) or two (compare mode). In compare mode a
/// top-right mode button cycles vertical curtain → horizontal curtain → synced
/// side-by-side; the curtains drag a divider to reveal more of one image, and
/// side-by-side shares one zoom/pan transform across both panes with a reset.
/// Single mode is just the zoomable image + reset. A one-line info strip per
/// image sits below, with a GPS pin (tooltip) shown only when coordinates are
/// present. The transform/curtain math lives in `image_compare_model.dart`; this
/// widget is the thin gesture/Image shell.
class ImageCompareViewer extends StatefulWidget {
  /// Creates the viewer over [panes] (1 = single, 2 = compare).
  const ImageCompareViewer({super.key, required this.panes});

  /// The one or two images to show.
  final List<ComparePane> panes;

  @override
  State<ImageCompareViewer> createState() => _ImageCompareViewerState();
}

class _ImageCompareViewerState extends State<ImageCompareViewer> {
  /// Shared transform for single mode and synced side-by-side.
  final TransformationController _transform = TransformationController();

  CompareMode _mode = CompareMode.verticalCurtain;
  double _fraction = 0.5;

  bool get _isCompare => widget.panes.length > 1;

  @override
  void initState() {
    super.initState();
    // Read the curated EXIF for the shown paths so the info line fills in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ControllerScope.of(
        context,
      ).loadCuratedExif([for (final p in widget.panes) p.path]);
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _reset() => _transform.value = Matrix4.identity();

  void _cycleMode() {
    setState(() => _mode = nextCompareMode(_mode));
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _body()),
            Positioned(top: 8, right: 8, child: _controls()),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final showReset = !_isCompare || _mode == CompareMode.sideBySide;
    return Row(
      children: [
        if (_isCompare)
          _OverlayButton(
            icon: _modeIcon(_mode),
            tooltip: context.tr('viewer_mode'),
            onPressed: _cycleMode,
          ),
        if (showReset)
          _OverlayButton(
            icon: Icons.center_focus_strong,
            tooltip: context.tr('viewer_reset'),
            onPressed: _reset,
          ),
        _OverlayButton(
          icon: Icons.close,
          tooltip: context.tr('viewer_close'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  static IconData _modeIcon(CompareMode mode) => switch (mode) {
    CompareMode.verticalCurtain => Icons.splitscreen,
    CompareMode.horizontalCurtain => Icons.horizontal_split,
    CompareMode.sideBySide => Icons.view_column,
  };

  Widget _body() {
    if (!_isCompare) {
      return _PaneColumn(
        pane: widget.panes.first,
        image: _Zoomable(
          controller: _transform,
          child: _PaneImage(path: widget.panes.first.path),
        ),
      );
    }
    return switch (_mode) {
      CompareMode.verticalCurtain => _curtain(vertical: true),
      CompareMode.horizontalCurtain => _curtain(vertical: false),
      CompareMode.sideBySide => _sideBySide(),
    };
  }

  Widget _curtain({required bool vertical}) {
    final a = widget.panes[0], b = widget.panes[1];
    return Column(
      children: [
        Expanded(
          child: _Curtain(
            vertical: vertical,
            fraction: _fraction,
            onFraction: (f) => setState(() => _fraction = f),
            first: _PaneImage(path: a.path),
            second: _PaneImage(path: b.path),
          ),
        ),
        _InfoLine(pane: a),
        _InfoLine(pane: b),
      ],
    );
  }

  Widget _sideBySide() {
    final a = widget.panes[0], b = widget.panes[1];
    return Row(
      children: [
        Expanded(
          child: _PaneColumn(
            pane: a,
            image: _Zoomable(
              controller: _transform,
              child: _PaneImage(path: a.path),
            ),
          ),
        ),
        const VerticalDivider(width: 1, color: Colors.white24),
        Expanded(
          child: _PaneColumn(
            pane: b,
            image: _Zoomable(
              controller: _transform,
              child: _PaneImage(path: b.path),
            ),
          ),
        ),
      ],
    );
  }
}

/// An image (top) over its one-line info strip (bottom).
class _PaneColumn extends StatelessWidget {
  const _PaneColumn({required this.pane, required this.image});

  final ComparePane pane;
  final Widget image;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: image),
        _InfoLine(pane: pane),
      ],
    );
  }
}

/// A zoom/pan wrapper sharing [controller] (so side-by-side panes move together)
/// over a centered [child].
class _Zoomable extends StatelessWidget {
  const _Zoomable({required this.controller, required this.child});

  final TransformationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: controller,
      minScale: 0.5,
      maxScale: 6,
      child: Center(child: child),
    );
  }
}

/// Two stacked images split by a draggable divider. Dragging the handle reveals
/// more of one image (before/after swipe); the math is in [dragFraction].
class _Curtain extends StatelessWidget {
  const _Curtain({
    required this.vertical,
    required this.fraction,
    required this.onFraction,
    required this.first,
    required this.second,
  });

  final bool vertical;
  final double fraction;
  final ValueChanged<double> onFraction;
  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = vertical ? constraints.maxWidth : constraints.maxHeight;
        final split = extent * fraction;
        void onUpdate(double position) => onFraction(
          dragFraction(from: 0, start: 0, current: position, extent: extent),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: vertical
              ? null
              : (d) => onUpdate(d.localPosition.dy),
          onHorizontalDragUpdate: vertical
              ? (d) => onUpdate(d.localPosition.dx)
              : null,
          child: Stack(
            children: [
              Positioned.fill(child: Center(child: second)),
              // The first image is clipped to the divider fraction.
              Positioned.fill(
                child: ClipRect(
                  clipper: _CurtainClipper(vertical: vertical, split: split),
                  child: Center(child: first),
                ),
              ),
              _DividerHandle(vertical: vertical, split: split),
            ],
          ),
        );
      },
    );
  }
}

/// Clips a child to the [split] portion along the divider axis.
class _CurtainClipper extends CustomClipper<Rect> {
  const _CurtainClipper({required this.vertical, required this.split});

  final bool vertical;
  final double split;

  @override
  Rect getClip(Size size) => vertical
      ? Rect.fromLTWH(0, 0, split, size.height)
      : Rect.fromLTWH(0, 0, size.width, split);

  @override
  bool shouldReclip(_CurtainClipper old) =>
      old.split != split || old.vertical != vertical;
}

/// The thin handle line drawn on the divider.
class _DividerHandle extends StatelessWidget {
  const _DividerHandle({required this.vertical, required this.split});

  final bool vertical;
  final double split;

  @override
  Widget build(BuildContext context) {
    if (vertical) {
      return Positioned(
        left: split - 1,
        top: 0,
        bottom: 0,
        child: Container(
          width: 2,
          color: Colors.white,
          alignment: Alignment.center,
          child: const _HandleKnob(),
        ),
      );
    }
    return Positioned(
      top: split - 1,
      left: 0,
      right: 0,
      child: Container(
        height: 2,
        color: Colors.white,
        alignment: Alignment.center,
        child: const _HandleKnob(),
      ),
    );
  }
}

/// A small round grip drawn at the centre of the divider.
class _HandleKnob extends StatelessWidget {
  const _HandleKnob();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.drag_indicator, size: 18, color: Colors.black87),
    );
  }
}

/// Renders [path]: a decoded [Image.file] for jpg/png/…, the controller's
/// extracted JPEG for RAW/HEIC, or a typed placeholder otherwise.
class _PaneImage extends StatelessWidget {
  const _PaneImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    // On mobile the path is a downscaled proxy; load the ORIGINAL full-resolution
    // bytes from the photo library and render them with Image.memory, showing the
    // proxy file as an instant placeholder while the full bytes load.
    final fullBytes = controller.fullBytesForProxyPath(path);
    if (fullBytes != null) {
      return FutureBuilder<Uint8List>(
        future: fullBytes,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData &&
              snapshot.data!.isNotEmpty) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.contain,
              errorBuilder: (context, _, _) => _proxyPlaceholder(),
            );
          }
          // While loading (or on empty/failed full bytes) show the proxy as a
          // decodable placeholder so the viewer is never blank.
          return _proxyPlaceholder();
        },
      );
    }
    if (needsPreviewExtraction(path)) {
      return FutureBuilder<String?>(
        future: controller.previewImageFor(path, full: true),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            );
          }
          final jpeg = snapshot.data;
          if (jpeg == null) return _Placeholder(label: fileTypeLabel(path));
          return Image.file(
            File(jpeg),
            fit: BoxFit.contain,
            errorBuilder: (context, _, _) =>
                _Placeholder(label: fileTypeLabel(path)),
          );
        },
      );
    }
    if (!isDecodableImage(path)) {
      return _Placeholder(label: fileTypeLabel(path));
    }
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      errorBuilder: (context, _, _) => _Placeholder(label: fileTypeLabel(path)),
    );
  }

  /// The downscaled proxy JPEG, shown on mobile as an instant placeholder while
  /// the full-resolution original bytes load (and as the fallback if they fail).
  Widget _proxyPlaceholder() => Image.file(
    File(path),
    fit: BoxFit.contain,
    errorBuilder: (context, _, _) => _Placeholder(label: fileTypeLabel(path)),
  );
}

/// The non-decodable placeholder: a muted icon + file-type tag.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.image_not_supported_outlined,
            size: 48,
            color: Colors.white54,
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

/// One image's compact one-line info strip: filename · W×H · size · time · GPS
/// pin (only with coords) · curated EXIF. Overflows with ellipsis.
class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.pane});

  final ComparePane pane;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    // On mobile the pane path is a downscaled, stripped proxy; show the ORIGINAL
    // asset's filename / size / dimensions / date / GPS instead. Falls back to
    // the desktop path (proxy/file name + read meta) when it doesn't resolve.
    final info = controller.mobileInfoForProxyPath(pane.path);
    final name = info?.filename ?? pane.path.split(RegExp(r'[/\\]')).last;
    final segments = compareInfoSegments(
      name: name,
      fileSize: info?.fileSize ?? pane.fileSize,
      meta: info?.meta ?? pane.meta,
      exif: controller.curatedExif(pane.path),
      tr: context.tr,
    );

    final children = <Widget>[];
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) {
        children.add(
          const Text(' · ', style: TextStyle(color: Colors.white38)),
        );
      }
      final seg = segments[i];
      if (seg.isGps) {
        children.add(
          Tooltip(
            message: seg.text,
            child: const Icon(Icons.place, size: 14, color: Colors.white70),
          ),
        );
      } else {
        children.add(
          Flexible(
            child: Text(
              seg.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: Colors.black,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFeatures: AppTheme.tabular),
        child: Row(children: children),
      ),
    );
  }
}

/// A round dark overlay icon button used for the viewer's top-right controls.
class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black54,
          foregroundColor: Colors.white,
        ),
        icon: Icon(icon),
      ),
    );
  }
}
