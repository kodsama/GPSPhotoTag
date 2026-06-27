import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

import '../explore/photo_detail_panel.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/shrink_model.dart';
import '../theme/app_theme.dart';
import 'duplicates_action.dart' show formatBytes;
import 'shrink_action.dart' show ShrinkAddButton;

/// The redundant RAW + photo pairs review (shrink stage 3).
///
/// Where both a RAW and its non-RAW partner exist, the user picks which side to
/// drop (keep the photo, or keep the RAW), reviews the drop-side files, and ticks
/// the ones to add to the shrink list. Pure selection — nothing is trashed here;
/// the chosen files are folded into the cumulative staged set on
/// [AppController.addActiveStageToShrinkList].
class ShrinkPairsReview extends StatelessWidget {
  /// Creates the redundant-pairs review surface.
  const ShrinkPairsReview({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    final candidates = controller.shrinkPairCandidates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('shrink_pairs_intro'), style: text.bodyMedium),
        const SizedBox(height: 12),
        SegmentedButton<PairDropSide>(
          segments: [
            ButtonSegment(
              value: PairDropSide.dropRaw,
              label: Text(context.tr('shrink_keep_photo')),
            ),
            ButtonSegment(
              value: PairDropSide.dropPhoto,
              label: Text(context.tr('shrink_keep_raw')),
            ),
          ],
          selected: {controller.shrinkPairDrop},
          onSelectionChanged: (s) => controller.setShrinkPairDrop(s.first),
        ),
        const SizedBox(height: 16),
        if (candidates.isEmpty)
          Text(context.tr('shrink_pairs_none'), style: text.titleMedium)
        else ...[
          _SelectAll(
            controller: controller,
            selected: controller.shrinkPairSelectedCount,
            total: candidates.length,
          ),
          const SizedBox(height: 8),
          for (final file in candidates)
            _PairCandidateRow(controller: controller, file: file),
        ],
        const SizedBox(height: 20),
        ShrinkAddButton(count: controller.shrinkPairSelectedCount),
      ],
    );
  }
}

/// A tristate select-all / none row for the drop-side candidates.
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
              : (_) => controller.selectAllShrinkPairs(selected != total),
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

/// One drop-side candidate: checkbox, thumbnail, filename.
class _PairCandidateRow extends StatelessWidget {
  const _PairCandidateRow({required this.controller, required this.file});

  final AppController controller;
  final PairedFile file;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final selected = controller.isShrinkPairSelected(file.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: (v) =>
                controller.setShrinkPairSelected(file.path, v ?? false),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 56,
              height: 56,
              child: PhotoThumbnail(path: file.path, height: 56),
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
            formatBytes(controller.shrinkSizeOf(file.path), context.tr),
            style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
          ),
        ],
      ),
    );
  }
}
