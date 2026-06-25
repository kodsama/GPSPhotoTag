import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../state/controller_scope.dart';
import '../theme/app_theme.dart';

/// The workspace header strip: the library's basename, a compact stat line, and
/// a "Change library" button that returns to the welcome picker.
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
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outline),
      ),
      child: Row(
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
                Text(_statLine(scan), style: text.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: controller.changeLibrary,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Change library'),
          ),
        ],
      ),
    );
  }

  static String _statLine(FolderScanResult scan) =>
      '${scan.photoCount} photos · ${scan.gpxCount} GPX · '
      '${scan.kmlCount} KML · ${scan.googleCount} Timeline · ${scan.dirs} '
      'folders';
}
