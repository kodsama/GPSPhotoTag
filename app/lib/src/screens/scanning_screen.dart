import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Live scan feedback: an indeterminate progress affordance plus running tally
/// tiles (files, folders, photos, tracks, history, unsupported) that update as
/// the worker walks the tree.
class ScanningScreen extends StatelessWidget {
  /// Creates the scanning screen.
  const ScanningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    final progress = controller.scanProgress ?? const ScanProgress();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Scanning your library…',
              style: text.headlineSmall,
              textAlign: TextAlign.center,
            ),
            if (controller.folderName != null) ...[
              const SizedBox(height: 6),
              Text(
                controller.folderName!,
                style: text.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(6)),
              child: LinearProgressIndicator(minHeight: 8),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                _Tile(label: 'Files', value: progress.files),
                _Tile(label: 'Folders', value: progress.dirs),
                _Tile(
                  label: 'Photos',
                  value: progress.photos,
                  accent: AppColors.terracotta,
                ),
                _Tile(
                  label: 'GPS tracks',
                  value: progress.tracks,
                  accent: AppColors.contour,
                ),
                _Tile(
                  label: 'Timeline',
                  value: progress.google,
                  accent: AppColors.contour,
                ),
                _Tile(label: 'Unsupported', value: progress.unsupported),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A single labelled live-count tile.
class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.accent});

  final String label;
  final int value;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      width: 156,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: text.headlineSmall?.copyWith(
              fontFeatures: AppTheme.tabular,
              color: accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: text.bodySmall),
        ],
      ),
    );
  }
}
