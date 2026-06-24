import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Body of the review step: the parsed summary (counts by format, date span,
/// detected GPS files) and a per-format include/exclude checklist.
class ReviewStep extends StatelessWidget {
  /// Creates the review step body.
  const ReviewStep({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sources(context, controller),
        const SizedBox(height: 16),
        Text('Photo formats', style: text.titleMedium),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTheme.radius),
            border: Border.all(color: scheme.outline),
          ),
          constraints: const BoxConstraints(maxHeight: 220),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final entry in _sortedFormats(controller))
                  _FormatRow(ext: entry.key, count: entry.value),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '${controller.includedCount} photo(s) will be tagged.',
          style: text.titleMedium?.copyWith(color: scheme.primary),
        ),
      ],
    );
  }

  List<MapEntry<String, int>> _sortedFormats(AppController controller) {
    final entries = controller.summary.countsByFormat.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  Widget _sources(BuildContext context, AppController controller) {
    final text = Theme.of(context).textTheme;
    final summary = controller.summary;
    final gpx = summary.gpxFiles.length;
    final google = summary.googleFiles.length;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        _chip(context, Icons.photo_library, '${summary.photoCount} photos'),
        _chip(context, Icons.route, '$gpx GPX file(s)', muted: gpx == 0),
        _chip(
          context,
          Icons.timeline,
          '$google Google file(s)',
          muted: google == 0,
        ),
        if (gpx == 0 && google == 0)
          Text(
            'No GPS source found in this folder — add a .gpx or Google export.',
            style: text.bodySmall?.copyWith(color: AppColors.warning),
          ),
      ],
    );
  }

  Widget _chip(
    BuildContext context,
    IconData icon,
    String label, {
    bool muted = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = muted
        ? scheme.onSurface.withValues(alpha: 0.45)
        : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// A checkbox row toggling every photo of one extension.
class _FormatRow extends StatelessWidget {
  const _FormatRow({required this.ext, required this.count});

  final String ext;
  final int count;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final included = controller.summary.photos
        .where((path) => path.toLowerCase().endsWith('.$ext'))
        .every(controller.isIncluded);
    return CheckboxListTile(
      dense: true,
      value: included,
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: (value) => controller.setFormatIncluded(ext, value ?? false),
      title: Text('.$ext'),
      secondary: Text('$count', style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
