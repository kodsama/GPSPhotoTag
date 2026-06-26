import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../state/controller_scope.dart';
import '../state/library_roots.dart';
import '../theme/app_theme.dart';

/// The workspace header strip: the library's name, a compact stat line, an
/// "Add folder" button, a "Change library" button, and — when the library spans
/// more than one root — a removable chip per root.
class LibraryBar extends StatelessWidget {
  /// Builds the bar over [scan] (the completed library scan).
  const LibraryBar({super.key, required this.scan});

  /// The scanned library.
  final FolderScanResult scan;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final roots = controller.roots;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.folder_special_outlined, color: scheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.folderName ?? 'Library',
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statLine(scan),
                      style: text.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Wrap so the two actions reflow onto a second line when the window
          // (or a test viewport) is narrow, never overflowing the row.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: controller.addFolder,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add folder'),
              ),
              OutlinedButton.icon(
                onPressed: controller.changeLibrary,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Change library'),
              ),
            ],
          ),
          if (roots.length > 1) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final root in roots)
                  Chip(
                    label: Text(rootLabel(root)),
                    onDeleted: () => controller.removeLibraryRoot(root),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    deleteButtonTooltipMessage: 'Remove from library',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _statLine(FolderScanResult scan) =>
      '${scan.dirs} folders · ${scan.photoCount} photos · '
      '${scan.gpxCount} GPX · ${scan.kmlCount} KML · '
      '${scan.googleCount} Timeline';
}
