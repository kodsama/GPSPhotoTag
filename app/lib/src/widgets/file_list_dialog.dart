import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

import '../explore/photo_detail_panel.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_theme.dart';

/// Opens the drill-down dialog for a file group.
///
/// [supported] groups (a photo format or a GPS source) show a checkbox per row
/// so the user can exclude files from processing; unsupported groups are
/// read-only (informational — they are never processed). [gps] sources read
/// their metadata in-process; image groups stream it via the engine.
Future<void> showFileListDialog(
  BuildContext context, {
  required String title,
  required List<String> paths,
  required bool supported,
  required bool gps,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => FileListDialog(
      title: title,
      paths: paths,
      supported: supported,
      gps: gps,
    ),
  );
}

/// A scrollable, filterable list of the files behind one Library-contents chip.
///
/// Rows fill in progressively as metadata streams into the controller's cache;
/// a header offers select-all/none (supported only) and a filename filter.
class FileListDialog extends StatefulWidget {
  /// Creates the dialog over [paths].
  const FileListDialog({
    super.key,
    required this.title,
    required this.paths,
    required this.supported,
    required this.gps,
  });

  /// Dialog title, e.g. "JPG — 2887 files".
  final String title;

  /// The file paths in this group, in scan order.
  final List<String> paths;

  /// Whether files in this group can be excluded (true) or are read-only.
  final bool supported;

  /// Whether these are GPS-source files (parsed in-process) vs images.
  final bool gps;

  @override
  State<FileListDialog> createState() => _FileListDialogState();
}

class _FileListDialogState extends State<FileListDialog> {
  String _filter = '';

  @override
  void initState() {
    super.initState();
    // Kick off metadata loading once the controller is in scope.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = ControllerScope.of(context);
      if (widget.gps) {
        controller.loadGpsMeta(widget.paths);
      } else {
        controller.loadImageMeta(widget.paths);
      }
    });
  }

  List<String> get _visible {
    final needle = _filter.toLowerCase();
    if (needle.isEmpty) return widget.paths;
    return [
      for (final path in widget.paths)
        if (p.basename(path).toLowerCase().contains(needle)) path,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final visible = _visible;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(widget.title, style: text.titleMedium)),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Header(
                controller: controller,
                paths: widget.paths,
                supported: widget.supported,
                onFilter: (value) => setState(() => _filter = value),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          'No matching files.',
                          style: text.bodySmall,
                        ),
                      )
                    : Material(
                        color: scheme.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radius),
                          side: BorderSide(color: scheme.outline),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, i) => _FileRow(
                            path: visible[i],
                            supported: widget.supported,
                            gps: widget.gps,
                            controller: controller,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Select-all/none controls (supported only), a "reading N/M" affordance, and a
/// filename filter field.
class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.paths,
    required this.supported,
    required this.onFilter,
  });

  final AppController controller;
  final List<String> paths;
  final bool supported;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final loaded = paths.where((p) => controller.fileMeta(p) != null).length;
    final reading = loaded < paths.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (supported) ...[
              TextButton(
                onPressed: () => controller.setGroupIncluded(paths, true),
                child: const Text('Select all'),
              ),
              TextButton(
                onPressed: () => controller.setGroupIncluded(paths, false),
                child: const Text('Select none'),
              ),
              const Spacer(),
            ] else
              const Spacer(),
            if (reading)
              Text(
                'reading $loaded/${paths.length}',
                style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Filter by filename…',
            border: OutlineInputBorder(),
          ),
          onChanged: onFilter,
        ),
      ],
    );
  }
}

/// One file row: an optional checkbox, the filename, a GPS pin, and the file's
/// metadata (dimensions + date for images, point count + span for sources).
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.path,
    required this.supported,
    required this.gps,
    required this.controller,
  });

  final String path;
  final bool supported;
  final bool gps;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final meta = controller.fileMeta(path);
    final included = controller.isFileIncluded(path);

    return InkWell(
      onTap: supported
          ? () => controller.setFileIncluded(path, !included)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            if (supported)
              Checkbox(
                value: included,
                onChanged: (v) => controller.setFileIncluded(path, v ?? false),
              )
            else
              const SizedBox(width: 12),
            Expanded(
              child: gps
                  ? Text(
                      p.basename(path),
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    )
                  // Image rows: tapping the filename opens the standalone photo
                  // preview (thumbnail + metadata + expand), not the map.
                  : InkWell(
                      onTap: () => showPhotoPreviewDialog(
                        context,
                        path: path,
                        meta: controller.fileMeta(path),
                      ),
                      child: Text(
                        p.basename(path),
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: scheme.onSurface.withValues(
                            alpha: 0.3,
                          ),
                        ),
                      ),
                    ),
            ),
            if ((meta?.hasGps ?? false) && !gps) ...[
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Explore on map',
                icon: Icon(Icons.place, size: 16, color: scheme.primary),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () {
                  Navigator.of(context).pop();
                  controller.openExploreAt(path);
                },
              ),
            ] else if (meta?.hasGps ?? false) ...[
              const SizedBox(width: 6),
              Icon(Icons.place, size: 16, color: scheme.primary),
            ],
            const SizedBox(width: 10),
            _MetaText(path: path, meta: meta),
          ],
        ),
      ),
    );
  }
}

/// The trailing metadata text for a row, or a subtle placeholder while loading.
class _MetaText extends StatelessWidget {
  const _MetaText({required this.path, required this.meta});

  final String path;
  final FileMeta? meta;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);

    if (meta == null) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline),
      );
    }

    final summary = _summarize(meta!);
    if (summary.isEmpty) return const SizedBox.shrink();
    return Text(
      summary,
      style: text.bodySmall?.copyWith(
        color: muted,
        fontFeatures: AppTheme.tabular,
      ),
    );
  }

  static String _summarize(FileMeta meta) {
    final parts = <String>[];
    if (meta.width != null && meta.height != null) {
      parts.add('${meta.width}×${meta.height}');
    }
    if (meta.date != null) parts.add(_fmtDate(meta.date!));
    if (meta.pointCount != null) {
      parts.add('${meta.pointCount} pts');
    }
    final start = meta.spanStart, end = meta.spanEnd;
    if (start != null && end != null) {
      parts.add('${_fmtDate(start)}–${_fmtDate(end)}');
    }
    return parts.join(' · ');
  }

  static String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
