import 'dart:math';

import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../explore/photo_detail_panel.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/duplicates_model.dart';
import '../state/library_action.dart' show Translator;
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/help.dart';
import '../widgets/image_compare_viewer.dart';
import '../widgets/run_view.dart';
import 'example_scene.dart';
import 'shrink_action.dart' show ShrinkAddButton;

/// The Find-Duplicates flow.
///
/// Like the other destructive actions, nothing is removed until the user
/// reviews and confirms. A similarity slider (Exact ↔ Loose) maps to a Hamming
/// threshold; pressing "Find duplicates" hashes every photo off the UI isolate
/// and shows the matches as pairs — best on the LEFT, the duplicate on the
/// RIGHT. Each pair can be swapped (flip which side is kept) or deselected (keep
/// both). The "Remove duplicates on the right" button gathers the still-selected
/// right-side files and trashes them behind a silly-word confirm gate.
class DuplicatesAction extends StatelessWidget {
  /// Creates the duplicates action body. [random] seeds the silly-word pick so
  /// the confirm dialog is deterministic in tests.
  DuplicatesAction({super.key, Random? random}) : _random = random ?? Random();

  /// Seam for the silly-word pick so the confirm dialog is deterministic.
  final Random _random;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);

    if (controller.lastSummary != null && !controller.running) {
      return _Done(controller: controller);
    }
    if (controller.running) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RunProgress(
            done: controller.done,
            total: controller.total,
            fraction: controller.fraction,
            rows: controller.rows,
          ),
        ],
      );
    }
    return _Review(controller: controller, random: _random);
  }
}

/// The slider + run button, then (after a run) the reviewable pairs and the
/// confirm-gated remove button.
class _Review extends StatelessWidget {
  const _Review({required this.controller, required this.random});

  final AppController controller;
  final Random random;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pairs = controller.duplicatePairs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        Text(context.tr('dup_intro'), style: text.bodyMedium),
        const SizedBox(height: 16),
        HelpTarget(
          topic: HelpTopic.duplicates,
          child: _MetricSelector(controller: controller),
        ),
        const SizedBox(height: 20),
        HelpTarget(
          topic: HelpTopic.duplicates,
          child: _SimilaritySlider(controller: controller),
        ),
        const SizedBox(height: 20),
        HelpTarget(
          topic: HelpTopic.duplicates,
          child: _KeepPipelinePanel(controller: controller),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: controller.findingDuplicates
              ? null
              : controller.runFindDuplicates,
          icon: const Icon(Icons.search),
          label: Text(context.tr('dup_find')),
        ),
        if (controller.findingDuplicates) ...[
          const SizedBox(height: 20),
          _HashingProgress(progress: controller.hashProgress),
        ],
        if (pairs != null && !controller.findingDuplicates) ...[
          const SizedBox(height: 20),
          _Results(controller: controller, pairs: pairs, random: random),
        ],
      ],
    );
  }
}

/// The top-of-screen metric selector: a Fast vs Smart choice, each shown as a
/// tappable card with a one-line explanation, a pro/con pair, and a small
/// illustration (mirroring the example-scene explain-with-pictures style). The
/// chosen metric is persisted and drives which similarity groups the files. When
/// Smart is selected but no model is bundled, an inline note says it falls back
/// to Fast.
class _MetricSelector extends StatelessWidget {
  const _MetricSelector({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final selected = controller.similarityMetric;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('dup_metric_title'), style: text.titleSmall),
        const SizedBox(height: 8),
        for (final metric in SimilarityMetric.values) ...[
          _MetricCard(
            metric: metric,
            selected: metric == selected,
            onSelected: controller.findingDuplicates
                ? null
                : () => controller.setSimilarityMetric(metric),
          ),
          const SizedBox(height: 8),
        ],
        if (selected == SimilarityMetric.smart &&
            !controller.smartMetricAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    context.tr('dup_metric_smart_unavailable'),
                    style: text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One metric option as a selectable card: an illustration, the metric name with
/// a radio indicator, a one-line explanation, and a pro/con pair.
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.metric,
    required this.selected,
    required this.onSelected,
  });

  final SimilarityMetric metric;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final smart = metric == SimilarityMetric.smart;
    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.4)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MetricIllustration(transformed: smart, glyph: smart ? '≈' : '='),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: selected ? scheme.primary : scheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          context.tr(similarityMetricLabelKey(metric)),
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.tr(similarityMetricDescKey(metric)),
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  _ProCon(
                    icon: Icons.add_circle_outline,
                    color: AppColors.success,
                    label: context.tr(similarityMetricProKey(metric)),
                  ),
                  const SizedBox(height: 2),
                  _ProCon(
                    icon: Icons.remove_circle_outline,
                    color: scheme.onSurfaceVariant,
                    label: context.tr(similarityMetricConKey(metric)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single pro or con line: a small coloured icon plus its text.
class _ProCon extends StatelessWidget {
  const _ProCon({required this.icon, required this.color, required this.label});

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

/// The Exact ↔ Loose similarity slider.
class _SimilaritySlider extends StatelessWidget {
  const _SimilaritySlider({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final selected = context.tr(similarityExampleKey(controller.similarity));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(context.tr('dup_similarity'), style: text.titleSmall),
            const Spacer(),
            // The currently-picked setting, always visible (not just the drag
            // tooltip): the level's plain-language name + its looseness percent.
            Text(
              context.tr('dup_similarity_value', {
                'label': selected,
                'percent': controller.similarity,
              }),
              style: text.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text(context.tr('dup_exact'), style: text.bodySmall),
            Expanded(
              child: Tooltip(
                message: context.tr('tt_dup_similarity'),
                child: Slider(
                  value: controller.similarity.toDouble(),
                  min: similarityMinPercent.toDouble(),
                  max: similarityMaxPercent.toDouble(),
                  divisions: similaritySteps,
                  label: selected,
                  onChanged: controller.findingDuplicates
                      ? null
                      : (v) => controller.setSimilarity(v.round()),
                ),
              ),
            ),
            Text(context.tr('dup_loose'), style: text.bodySmall),
          ],
        ),
        const SizedBox(height: 8),
        ExampleScenePair(
          variance: sceneVariance(controller.similarity),
          caption: selected,
        ),
      ],
    );
  }
}

/// A plain-language name for a keep [rule], resolved via [tr] for the pipeline
/// list.
String keepRuleLabel(KeepRule rule, Translator tr) => switch (rule) {
  KeepRule.resolution => tr('dup_keep_resolution'),
  KeepRule.quality => tr('dup_keep_quality'),
  KeepRule.people => tr('dup_keep_people'),
};

/// The hover tooltip for a keep [rule], resolved via [tr], or null when the rule
/// needs no extra explanation. Only the people rule has one today: it notes that
/// the rule uses the people/pet tags already present in the photos.
String? keepRuleTooltip(KeepRule rule, Translator tr) => switch (rule) {
  KeepRule.people => tr('tt_dup_keep_people'),
  _ => null,
};

/// One keep-rule's label, with a hover [Tooltip] when [keepRuleTooltip] returns
/// one for the rule (the people rule's "uses your photo tags" note).
class _KeepRuleLabel extends StatelessWidget {
  const _KeepRuleLabel({required this.rule});

  final KeepRule rule;

  @override
  Widget build(BuildContext context) {
    final label = Text(keepRuleLabel(rule, context.tr));
    final tip = keepRuleTooltip(rule, context.tr);
    if (tip == null) return label;
    return Tooltip(message: tip, child: label);
  }
}

/// The compact keep-priority pipeline control: a draggable list of the keep
/// rules (placement = priority) each with an enable [Switch], plus a one-line
/// explainer. Reordering or toggling drives the controller's pipeline, which
/// re-decides the kept (left) side of the review.
///
/// Every [KeepRule] — including [KeepRule.people] — is reorderable/toggleable.
/// The people rule's label carries a tooltip noting it uses the people/pet tags
/// already present in the photos (see [keepRuleTooltip]).
class _KeepPipelinePanel extends StatelessWidget {
  const _KeepPipelinePanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final steps = controller.keepPipeline.steps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('dup_keep_priority'), style: text.titleSmall),
        const SizedBox(height: 4),
        Text(context.tr('dup_keep_priority_explainer'), style: text.bodySmall),
        const SizedBox(height: 8),
        // The list is short (two rules) so it sizes to its content inside the
        // surrounding scroll view.
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: controller.reorderKeepRule,
          children: [
            for (var i = 0; i < steps.length; i++)
              Container(
                key: ValueKey(steps[i].rule),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outline),
                ),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: Tooltip(
                        message: context.tr('tt_dup_drag_handle'),
                        child: const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Icon(Icons.drag_handle, size: 20),
                        ),
                      ),
                    ),
                    Text('${i + 1}.', style: text.labelLarge),
                    const SizedBox(width: 8),
                    Expanded(child: _KeepRuleLabel(rule: steps[i].rule)),
                    Tooltip(
                      message: context.tr('tt_dup_rule_switch'),
                      child: Switch(
                        value: steps[i].enabled,
                        onChanged: (v) =>
                            controller.setKeepRuleEnabled(steps[i].rule, v),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Determinate hashing progress shown while a find-duplicates run is in flight:
/// a bar tracking files-hashed/total plus a "Hashing N / M" label. The bar is
/// indeterminate (null value) only in the brief window before the total is
/// known.
class _HashingProgress extends StatelessWidget {
  const _HashingProgress({required this.progress});

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

/// The list of reviewable pairs plus the remove button, or an empty-state note.
class _Results extends StatelessWidget {
  const _Results({
    required this.controller,
    required this.pairs,
    required this.random,
  });

  final AppController controller;
  final List<DuplicatePair> pairs;
  final Random random;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (pairs.isEmpty) {
      return Text(context.tr('dup_none_found'), style: text.titleMedium);
    }
    final n = controller.duplicateRemovalCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('dup_pairs', {'count': pairs.length}),
          style: text.titleMedium,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < pairs.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _PairRow(controller: controller, index: i, pair: pairs[i]),
          ),
        const SizedBox(height: 8),
        // In a deferred shrink session the terminal action adds the still-
        // selected duplicates to the shrink list and returns; standalone it
        // trashes them behind the silly-word confirm.
        if (controller.inShrinkSession)
          ShrinkAddButton(count: n)
        else
          Tooltip(
            message: context.tr('tt_dup_remove_button'),
            child: FilledButton.icon(
              onPressed: n == 0
                  ? null
                  : () => _confirm(context, controller, random),
              icon: const Icon(Icons.delete_outline),
              label: Text(context.tr('dup_remove_button', {'count': n})),
            ),
          ),
      ],
    );
  }
}

/// One reviewable pair: kept (left) vs duplicate (right), with swap + deselect.
class _PairRow extends StatelessWidget {
  const _PairRow({
    required this.controller,
    required this.index,
    required this.pair,
  });

  final AppController controller;
  final int index;
  final DuplicatePair pair;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Tapping either image opens the kept-vs-other comparison (kept on the left,
    // the default before/after vertical curtain).
    void openCompare() => openImageCompare(context, [
      hashedComparePane(pair.kept),
      hashedComparePane(pair.other),
    ]);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _PairSide(
                  file: pair.kept,
                  label: context.tr('dup_keep'),
                  keep: true,
                  onTap: openCompare,
                ),
              ),
              Column(
                children: [
                  IconButton(
                    tooltip: context.tr('dup_swap_tooltip'),
                    icon: const Icon(Icons.swap_horiz),
                    onPressed: () => controller.swapDuplicatePair(index),
                  ),
                ],
              ),
              Expanded(
                child: _PairSide(
                  file: pair.other,
                  label: context.tr(
                    pair.removeSelected ? 'dup_remove' : 'dup_kept',
                  ),
                  keep: !pair.removeSelected,
                  onTap: openCompare,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Tooltip(
                message: context.tr(
                  pair.removeSelected
                      ? 'tt_dup_remove_right'
                      : 'tt_dup_keep_both',
                ),
                child: Checkbox(
                  value: pair.removeSelected,
                  onChanged: (v) =>
                      controller.setDuplicateRemoval(index, v ?? false),
                ),
              ),
              Flexible(
                child: Text(
                  context.tr(
                    pair.removeSelected ? 'dup_remove_right' : 'dup_keep_both',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One side of a pair: a thumbnail + filename + resolution/size, tinted by
/// whether it is kept or slated for removal.
class _PairSide extends StatelessWidget {
  const _PairSide({
    required this.file,
    required this.label,
    required this.keep,
    required this.onTap,
  });

  final HashedFile file;
  final String label;
  final bool keep;

  /// Opens the full-screen comparison for this pair.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = keep ? scheme.primary : scheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: color.withValues(alpha: 0.12),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message: context.tr('tt_dup_open_compare'),
          child: InkWell(
            onTap: onTap,
            child: PhotoThumbnail(path: file.path, height: 120),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          ControllerScope.of(context).displayFilename(file.path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          context.tr('dup_pair_dimensions', {
            'width': file.width,
            'height': file.height,
            'size': formatBytes(file.fileSize, context.tr),
          }),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Builds a [ComparePane] for the big-preview viewer from a [HashedFile],
/// carrying its dimensions (when known) and on-disk size for the info line.
ComparePane hashedComparePane(HashedFile file) => ComparePane(
  path: file.path,
  meta: (file.width > 0 && file.height > 0)
      ? FileMeta(path: file.path, width: file.width, height: file.height)
      : null,
  fileSize: file.fileSize > 0 ? file.fileSize : null,
);

/// Formats [bytes] as a compact human-readable size (KB/MB), resolving the unit
/// suffix via [tr].
String formatBytes(int bytes, Translator tr) {
  if (bytes < 1024) return tr('dup_size_bytes', {'count': bytes});
  if (bytes < 1024 * 1024) {
    return tr('dup_size_kb', {'count': (bytes / 1024).toStringAsFixed(0)});
  }
  return tr('dup_size_mb', {
    'count': (bytes / (1024 * 1024)).toStringAsFixed(1),
  });
}

/// Shows the silly-word confirm dialog; on success trashes the selected set.
Future<void> _confirm(
  BuildContext context,
  AppController controller,
  Random random,
) async {
  final word = pickSillyWord(random);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _ConfirmDialog(count: controller.duplicateRemovalCount, word: word),
  );
  if (ok ?? false) await controller.runTrashDuplicates();
}

/// The confirm popup gated on typing a randomly-chosen silly word.
class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.count, required this.word});

  final int count;
  final String word;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  String _typed = '';

  @override
  Widget build(BuildContext context) {
    final matches = sillyWordMatches(_typed, widget.word);
    return AlertDialog(
      title: Text(context.tr('dup_confirm_title', {'count': widget.count})),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.tr('dup_confirm_body')),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              text: context.tr('dup_confirm_type_prefix'),
              children: [
                TextSpan(
                  text: widget.word,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: context.tr('dup_confirm_type_suffix')),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _typed = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.tr('dup_cancel')),
        ),
        FilledButton(
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(context.tr('dup_move_to_trash')),
        ),
      ],
    );
  }
}

/// The post-run summary + back affordance.
class _Done extends StatelessWidget {
  const _Done({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ResultSummaryTable(summary: controller.lastSummary!),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: controller.backToLibrary,
          icon: const Icon(Icons.check),
          label: Text(context.tr('done_back_to_library')),
        ),
      ],
    );
  }
}
