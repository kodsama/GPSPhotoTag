import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../explore/photo_detail_panel.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/duplicates_model.dart'
    show
        HashProgress,
        qualityDegradation,
        qualityExampleKey,
        qualityPickedLabel;
import '../theme/app_theme.dart';
import 'duplicates_action.dart' show formatBytes;
import 'example_scene.dart' show QualityExamplePair;
import 'shrink_action.dart' show ShrinkAddButton;

/// The low-quality review (shrink stage 4).
///
/// The user sets a quality threshold, finds the photos scoring below it (hashing
/// off the UI isolate, reusing the composite quality the hasher computes), then
/// ticks the ones to add to the shrink list. Pure selection — nothing is trashed
/// here; the chosen files fold into the staged set on
/// [AppController.addActiveStageToShrinkList].
///
/// The surface has three unambiguous modes so the threshold control and the
/// hashing progress bar never stack into one confusing control:
///   * configuring (idle, not yet reviewed) — the explainer + threshold slider
///     + kept-vs-flagged example + Find button;
///   * hashing (busy) — ONLY the "Hashing N / M" progress bar;
///   * results (reviewed, not busy) — the below-threshold candidate list.
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
        const SizedBox(height: 16),
        // Mode 1 — hashing: show ONLY the progress bar (no slider/example), so
        // the threshold control can never be confused with the progress bar.
        if (controller.shrinkBusy)
          _HashingBar(progress: controller.hashProgress)
        // Mode 3 — results: the criteria toggles (so the found set can be
        // re-filtered WITHOUT re-hashing) above the below-threshold candidates.
        else if (controller.shrinkLowQReviewed) ...[
          _CriteriaToggles(controller: controller),
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
        ]
        // Mode 2 — configuring: explainer + threshold slider + example + Find.
        else ...[
          Text(context.tr('shrink_quality_explainer'), style: text.bodySmall),
          const SizedBox(height: 12),
          _CriteriaToggles(controller: controller),
          const SizedBox(height: 16),
          _QualitySlider(controller: controller),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: controller.runShrinkLowQualityHash,
            icon: const Icon(Icons.search),
            label: Text(context.tr('shrink_low_quality_find')),
          ),
        ],
        const SizedBox(height: 20),
        ShrinkAddButton(count: controller.shrinkLowQSelectedCount),
      ],
    );
  }
}

/// The Lenient ↔ Strict quality-threshold slider, with an always-visible
/// picked-threshold label and a kept-vs-flagged example keyed to the threshold.
///
/// Mirrors the duplicates similarity slider: the picked label
/// ([qualityPickedLabel]) sits beside the title, and the example
/// ([QualityExamplePair]) degrades its flagged tile by [qualityDegradation] with
/// a caption ([qualityExampleKey]) describing what the current threshold flags.
class _QualitySlider extends StatelessWidget {
  const _QualitySlider({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final threshold = controller.shrinkQualityThreshold;
    final caption = context.tr(qualityExampleKey(threshold));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(context.tr('shrink_quality_title'), style: text.titleSmall),
            const Spacer(),
            // The currently-picked threshold, always visible (not just the drag
            // tooltip): "Lenient ↔ Strict · NN%".
            Text(
              qualityPickedLabel(threshold, context.tr),
              style: text.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text(context.tr('lowq_lenient'), style: text.bodySmall),
            Expanded(
              child: Slider(
                value: threshold,
                divisions: 20,
                label: '${(threshold * 100).round()}%',
                onChanged: controller.setShrinkQualityThreshold,
              ),
            ),
            Text(context.tr('lowq_strict_end'), style: text.bodySmall),
          ],
        ),
        const SizedBox(height: 8),
        QualityExamplePair(
          degradation: qualityDegradation(threshold),
          keptLabel: context.tr('lowq_kept'),
          flaggedLabel: context.tr('lowq_flagged'),
          caption: caption,
        ),
      ],
    );
  }
}

/// The compact set of quality-criteria toggles deciding what counts as "low
/// quality": Blurriness (sharpness), Histogram (contrast), Color, Exposure.
///
/// Default ALL ON. Toggling one RE-FILTERS the already-hashed candidates without
/// re-hashing (the controller recomputes the candidate set from the stored
/// per-component scores). Each chip carries a tooltip explaining what it flags.
class _CriteriaToggles extends StatelessWidget {
  const _CriteriaToggles({required this.controller});

  final AppController controller;

  static const _labelKeys = {
    QualityParam.sharpness: 'lowq_param_sharpness',
    QualityParam.contrast: 'lowq_param_contrast',
    QualityParam.color: 'lowq_param_color',
    QualityParam.exposure: 'lowq_param_exposure',
  };

  static const _tooltipKeys = {
    QualityParam.sharpness: 'tt_lowq_sharpness',
    QualityParam.contrast: 'tt_lowq_contrast',
    QualityParam.color: 'tt_lowq_color',
    QualityParam.exposure: 'tt_lowq_exposure',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final allOff = controller.lowQParams.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('lowq_criteria_title'), style: text.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final param in QualityParam.values)
              Tooltip(
                message: context.tr(_tooltipKeys[param]!),
                child: FilterChip(
                  label: Text(context.tr(_labelKeys[param]!)),
                  selected: controller.isLowQParamEnabled(param),
                  onSelected: (on) => controller.setLowQParamEnabled(param, on),
                ),
              ),
          ],
        ),
        if (allOff) ...[
          const SizedBox(height: 8),
          Text(
            context.tr('lowq_criteria_all_off'),
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
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
              controller.displayFilename(file.path),
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
