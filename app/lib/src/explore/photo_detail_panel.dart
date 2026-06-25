import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

import '../state/controller_scope.dart';
import '../theme/app_theme.dart';
import 'detail_selection.dart';
import 'explore_model.dart';

/// Opens the reusable photo preview ([PhotoPreview]) for [path] as a standalone
/// dialog (the filename-tap entry point in the file list).
///
/// Shows the thumbnail/miniature, the [meta] (filename, date, W×H, and
/// coordinates when present) and an expand control to view the image fullscreen.
/// This is the same preview the map overlay shows — only the chrome differs.
Future<void> showPhotoPreviewDialog(
  BuildContext context, {
  required String path,
  FileMeta? meta,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: PhotoPreview(
        path: path,
        meta: meta,
        onClose: () => Navigator.of(dialogContext).pop(),
        onExpand: () => openFullscreen(dialogContext, path),
      ),
    ),
  );
}

/// Pushes the [FullscreenImageView] for [path].
void openFullscreen(BuildContext context, String path) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => FullscreenImageView(path: path)),
  );
}

/// The reusable photo preview: a [PhotoThumbnail], the metadata (filename,
/// date, W×H, coordinates when known) and an expand-to-fullscreen control.
///
/// One widget, two homes: the standalone filename-tap dialog
/// ([showPhotoPreviewDialog]) and the map's detail overlay ([PhotoDetailPanel],
/// which wraps it with pager chrome). [trailing] lets the overlay inject its
/// prev/next/counter controls into the same top-right action row. Pure
/// presentation so it is widget-testable with seeded data.
class PhotoPreview extends StatelessWidget {
  /// Creates a preview of [path] with optional [meta].
  const PhotoPreview({
    super.key,
    required this.path,
    this.meta,
    required this.onExpand,
    this.onClose,
    this.trailing = const [],
    this.width = 320,
    this.thumbnailHeight = 200,
  });

  /// The image file path.
  final String path;

  /// The metadata behind this photo (date, dimensions, coordinates), if known.
  final FileMeta? meta;

  /// Opens the image fullscreen.
  final VoidCallback onExpand;

  /// Dismisses the preview; when null the close button is hidden.
  final VoidCallback? onClose;

  /// Extra controls placed before the expand/close buttons (the map overlay's
  /// prev/next/counter).
  final List<Widget> trailing;

  /// Card width.
  final double width;

  /// Thumbnail height.
  final double thumbnailHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              PhotoThumbnail(path: path, height: thumbnailHeight),
              Positioned(
                top: 4,
                right: 4,
                child: Row(
                  children: [
                    ...trailing,
                    RoundIconButton(
                      icon: Icons.open_in_full,
                      tooltip: 'View fullscreen',
                      onPressed: onExpand,
                    ),
                    if (onClose != null)
                      RoundIconButton(
                        icon: Icons.close,
                        tooltip: 'Close',
                        onPressed: onClose!,
                      ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(path),
                  style: text.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                for (final line in previewMetaLines(path, meta))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      line,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.7),
                        fontFeatures: AppTheme.tabular,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The metadata lines (date, W×H, coordinates) for [path]'s [meta].
///
/// Coordinates are included only when the meta carries GPS. Pure, so the line
/// formatting is unit testable.
List<String> previewMetaLines(String path, FileMeta? meta) {
  final lines = <String>[];
  final date = meta?.date;
  if (date != null) {
    String two(int n) => n.toString().padLeft(2, '0');
    lines.add(
      '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}',
    );
  }
  if (meta?.width != null && meta?.height != null) {
    lines.add('${meta!.width} × ${meta.height}');
  }
  final lat = meta?.latitude, lon = meta?.longitude;
  if (meta?.hasGps == true && lat != null && lon != null) {
    lines.add('${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}');
  }
  return lines;
}

/// The floating detail card for the photo (or photos) at a tapped map point.
///
/// Reuses [PhotoPreview] for the thumbnail + metadata + expand control, adding
/// prev/next + a "1 / N" counter when the point holds several photos. All paging
/// arithmetic lives in [DetailSelection]; this widget is pure presentation so it
/// is widget-testable with seeded data.
class PhotoDetailPanel extends StatelessWidget {
  /// Creates the panel for [selection].
  const PhotoDetailPanel({
    super.key,
    required this.selection,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
    required this.onExpand,
  });

  /// Which point + photo is shown.
  final DetailSelection selection;

  /// Pages to the previous photo (only relevant when [DetailSelection.isMulti]).
  final VoidCallback onPrev;

  /// Pages to the next photo.
  final VoidCallback onNext;

  /// Dismisses the panel.
  final VoidCallback onClose;

  /// Opens the current image fullscreen.
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final photo = selection.current;

    return Card(
      elevation: 8,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: PhotoPreview(
        path: photo.path,
        meta: photo.meta,
        onExpand: onExpand,
        onClose: onClose,
        trailing: [
          if (selection.isMulti) ...[
            RoundIconButton(
              icon: Icons.chevron_left,
              tooltip: 'Previous',
              onPressed: onPrev,
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                selection.counter,
                style: text.labelMedium?.copyWith(
                  color: Colors.white,
                  fontFeatures: AppTheme.tabular,
                ),
              ),
            ),
            RoundIconButton(
              icon: Icons.chevron_right,
              tooltip: 'Next',
              onPressed: onNext,
            ),
          ],
        ],
      ),
    );
  }
}

/// A thumbnail for [path]: a decoded [Image.file] for jpg/png/webp/gif/bmp, or
/// a tasteful typed placeholder for HEIC/RAW (and anything Flutter can't
/// decode). The decode path uses [cacheWidth] to avoid full-res decodes.
class PhotoThumbnail extends StatelessWidget {
  /// Creates a thumbnail for [path] sized to [height].
  const PhotoThumbnail({
    super.key,
    required this.path,
    this.height = 200,
    this.cacheWidth = 640,
  });

  /// The image file path.
  final String path;

  /// The fixed display height.
  final double height;

  /// Decode width hint passed to [Image.file].
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    if (needsPreviewExtraction(path)) {
      return _ExtractedImage(
        path: path,
        full: false,
        height: height,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
      );
    }
    if (!isDecodableImage(path)) {
      return _Placeholder(label: fileTypeLabel(path), height: height);
    }
    return Image.file(
      File(path),
      height: height,
      width: double.infinity,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: (context, _, _) =>
          _Placeholder(label: fileTypeLabel(path), height: height),
    );
  }
}

/// Renders a RAW/HEIC [path] by extracting its embedded JPEG via the controller
/// (off the UI isolate), showing a spinner while extracting and the typed
/// placeholder on failure. Thin glue around [AppController.previewImageFor] and
/// an [Image.file]; the decision to use it lives in [needsPreviewExtraction].
class _ExtractedImage extends StatelessWidget {
  const _ExtractedImage({
    required this.path,
    required this.full,
    required this.height,
    this.cacheWidth,
    this.fit = BoxFit.contain,
  });

  /// The RAW/HEIC source file.
  final String path;

  /// Whether to extract the large (fullscreen) preview vs the small thumbnail.
  final bool full;

  /// Fixed display height (also sizes the spinner/placeholder).
  final double height;

  /// Optional decode width hint for the resulting JPEG.
  final int? cacheWidth;

  /// How the extracted JPEG fits its box.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    return FutureBuilder<String?>(
      future: controller.previewImageFor(path, full: full),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _Spinner(height: height);
        }
        final jpeg = snapshot.data;
        if (jpeg == null) {
          return _Placeholder(label: fileTypeLabel(path), height: height);
        }
        return Image.file(
          File(jpeg),
          height: height,
          width: full ? null : double.infinity,
          fit: fit,
          cacheWidth: cacheWidth,
          errorBuilder: (context, _, _) =>
              _Placeholder(label: fileTypeLabel(path), height: height),
        );
      },
    );
  }
}

/// A centered progress indicator sized to [height], shown while a preview is
/// being extracted.
class _Spinner extends StatelessWidget {
  const _Spinner({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
  }
}

/// The non-decodable placeholder: a muted panel with an icon and file-type tag.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.label, required this.height});

  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            size: 36,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small circular dark icon button used over the thumbnail.
class RoundIconButton extends StatelessWidget {
  /// Creates a circular dark [icon] button with [tooltip].
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  /// The button glyph.
  final IconData icon;

  /// The button tooltip.
  final String tooltip;

  /// Tap handler.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
      ),
      icon: Icon(icon),
    );
  }
}

/// A fullscreen view of [path] in an [InteractiveViewer] for pinch/scroll zoom,
/// with a close affordance. Non-decodable files show the typed placeholder.
class FullscreenImageView extends StatelessWidget {
  /// Creates the fullscreen view for [path].
  const FullscreenImageView({super.key, required this.path});

  /// The image file path.
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(p.basename(path)),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: needsPreviewExtraction(path)
              ? _ExtractedImage(path: path, full: true, height: 240)
              : isDecodableImage(path)
              ? Image.file(
                  File(path),
                  errorBuilder: (context, _, _) =>
                      _Placeholder(label: fileTypeLabel(path), height: 240),
                )
              : _Placeholder(label: fileTypeLabel(path), height: 240),
        ),
      ),
    );
  }
}
