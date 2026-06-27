import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

import '../explore/photo_detail_panel.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/duplicates_model.dart' show HashProgress;
import '../theme/app_theme.dart';
import 'duplicates_action.dart' show formatBytes;
import 'shrink_action.dart' show ShrinkAddButton;

/// The low-quality review (shrink stage 4).
///
/// The user sets a quality threshold, finds the photos scoring below it (hashing
/// off the UI isolate, reusing the composite quality the hasher computes), then
/// ticks the ones to add to the shrink list. Pure selection — nothing is trashed
/// here; the chosen files fold into the staged set on
/// [AppController.addActiveStageToShrinkList].
class ShrinkLowQualityReview extends StatelessWidget {
  /// Creates the low-quality review surface.
  const ShrinkLowQualityReview({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    final pct = (controller.shrinkQualityThreshold * 100).round();
    final candidates = controller.shrinkLowQCandidates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('shrink_low_quality_intro'), style: text.bodyMedium),
        const SizedBox(height: 12),
        Text(
          context.tr('shrink_quality_threshold', {'percent': pct}),
          style: text.bodySmall,
        ),
        Slider(
          value: controller.shrinkQualityThreshold,
          divisions: 20,
          label: '$pct%',
          onChanged: controller.shrinkBusy
              ? null
              : controller.setShrinkQualityThreshold,
        ),
        const SizedBox(height: 8),
        if (controller.shrinkBusy)
          _HashingBar(progress: controller.hashProgress)
        else
          FilledButton.icon(
            onPressed: controller.runShrinkLowQualityHash,
            icon: const Icon(Icons.search),
            label: Text(context.tr('shrink_low_quality_find')),
          ),
        if (controller.shrinkLowQReviewed && !controller.shrinkBusy) ...[
          const SizedBox(height: 16),
          if (candidates.isEmpty)
            Text(context.tr('shrink_low_quality_none'), style: text.titleMedium)
          else ...[
            Text(
              context.tr('shrink_low_quality_count', {
                'count': candidates.length,
                'percent': pct,
              }),
              style: text.titleMedium,
            ),
            const SizedBox(height: 8),
            _SelectAll(
              controller: controller,
              selected: controller.shrinkLowQSelectedCount,
              total: candidates.length,
            ),
            const SizedBox(height: 8),
            for (final h in candidates)
              _LowQRow(controller: controller, file: h),
          ],
        ],
        const SizedBox(height: 20),
        ShrinkAddButton(count: controller.shrinkLowQSelectedCount),
      ],
    );
  }
}

/// A tristate select-all / none row for the below-threshold candidates.
class _SelectAll extends StatelessWidget {
  const _SelectAll({
    required this.controller,
    required this.selected,
    required this.total,
  });

  final AppController controller;
  final int selected;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value: total == 0
              ? false
              : selected == total
              ? true
              : selected == 0
              ? false
              : null,
          tristate: true,
          onChanged: total == 0
              ? null
              : (_) => controller.selectAllShrinkLowQ(selected != total),
        ),
        Text(
          context.tr('shrink_pairs_selected', {
            'selected': selected,
            'candidates': total,
          }),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// One below-threshold candidate: checkbox, thumbnail, filename, size.
class _LowQRow extends StatelessWidget {
  const _LowQRow({required this.controller, required this.file});

  final AppController controller;
  final HashedFile file;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final selected = controller.isShrinkLowQSelected(file.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: (v) =>
                controller.setShrinkLowQSelected(file.path, v ?? false),
          ),
          // Tapping the miniature opens the big-preview viewer (single mode).
          Tooltip(
            message: context.tr('tt_dup_open_compare'),
            child: InkWell(
              onTap: () => openFullscreen(context, file.path),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: PhotoThumbnail(path: file.path, height: 56),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p.basename(file.path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatBytes(file.fileSize, context.tr),
            style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
          ),
        ],
      ),
    );
  }
}

/// Determinate hashing progress while the low-quality scan is in flight.
class _HashingBar extends StatelessWidget {
  const _HashingBar({required this.progress});

  final HashProgress progress;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.fraction,
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          context.tr('hashing_progress', {
            'done': progress.groupedDone,
            'total': progress.groupedTotal,
          }),
          style: text.bodyMedium?.copyWith(fontFeatures: AppTheme.tabular),
        ),
      ],
    );
  }
}
