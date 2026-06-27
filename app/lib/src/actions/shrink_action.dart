import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../explore/photo_detail_panel.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/duplicates_model.dart';
import '../state/library_action.dart' show Translator;
import '../state/shrink_model.dart';
import '../theme/app_theme.dart';
import '../widgets/run_view.dart';
import 'duplicates_action.dart' show formatBytes;

/// The "Shrink picture library" wizard.
///
/// A stepper through OPT-IN stages — duplicates, orphans, redundant RAW+photo
/// pairs, and low quality — building ONE cumulative trash set. A file flagged by
/// an earlier stage is never counted again by a later one. Each stage shows how
/// many files it flagged, the space freed, and the running total. A final
/// summary lists every staged file (reason, miniature, GPS indicator, size) and
/// gates trashing behind the silly-word confirm. Nothing is deleted without it.
class ShrinkAction extends StatelessWidget {
  /// Creates the shrink wizard body. [random] seeds the silly-word pick so the
  /// confirm dialog is deterministic in tests.
  ShrinkAction({super.key, Random? random}) : _random = random ?? Random();

  /// Seam for the silly-word pick so the confirm dialog is deterministic.
  final Random _random;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);

    if (controller.lastSummary != null && !controller.running) {
      return _Done(controller: controller);
    }
    if (controller.running) {
      return RunProgress(
        done: controller.done,
        total: controller.total,
        fraction: controller.fraction,
        rows: controller.rows,
      );
    }
    return _Wizard(controller: controller, random: _random);
  }
}

/// The stepper: every stage as a card with an include/skip toggle, its options,
/// a run button, and (after running) its per-stage result; then the final
/// summary + confirm.
class _Wizard extends StatelessWidget {
  const _Wizard({required this.controller, required this.random});

  final AppController controller;
  final Random random;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        Text(context.tr('shrink_intro'), style: text.bodyMedium),
        const SizedBox(height: 16),
        for (final stage in ShrinkStage.values) ...[
          _StageCard(controller: controller, stage: stage),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        _RunningTotal(controller: controller),
        const SizedBox(height: 16),
        _Summary(controller: controller, random: random),
      ],
    );
  }
}

/// The display title key for a stage.
String shrinkStageTitleKey(ShrinkStage stage) => switch (stage) {
  ShrinkStage.duplicates => 'shrink_stage_duplicates',
  ShrinkStage.orphans => 'shrink_stage_orphans',
  ShrinkStage.pairs => 'shrink_stage_pairs',
  ShrinkStage.lowQuality => 'shrink_stage_low_quality',
};

/// One stage card: include toggle, options, run button, and per-stage result.
class _StageCard extends StatelessWidget {
  const _StageCard({required this.controller, required this.stage});

  final AppController controller;
  final ShrinkStage stage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final included = controller.isShrinkStageIncluded(stage);
    final outcome = controller.shrinkOutcome(stage);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.tr(shrinkStageTitleKey(stage)),
                  style: text.titleSmall,
                ),
              ),
              Tooltip(
                message: context.tr('shrink_stage_include'),
                child: Switch(
                  value: included,
                  onChanged: (v) => controller.setShrinkStageIncluded(stage, v),
                ),
              ),
            ],
          ),
          if (included) ...[
            const SizedBox(height: 4),
            _StageOptions(controller: controller, stage: stage),
            const SizedBox(height: 8),
            if (controller.shrinkBusy &&
                (stage == ShrinkStage.duplicates ||
                    stage == ShrinkStage.lowQuality))
              _HashingBar(progress: controller.hashProgress)
            else
              FilledButton.icon(
                onPressed: controller.shrinkBusy
                    ? null
                    : () => _run(controller, stage),
                icon: const Icon(Icons.play_arrow),
                label: Text(context.tr('shrink_run_stage')),
              ),
            if (outcome != null) ...[
              const SizedBox(height: 10),
              _StageResult(controller: controller, outcome: outcome),
            ],
          ],
        ],
      ),
    );
  }

  void _run(AppController controller, ShrinkStage stage) {
    switch (stage) {
      case ShrinkStage.duplicates:
        controller.runShrinkDuplicates();
      case ShrinkStage.orphans:
        controller.runShrinkOrphans();
      case ShrinkStage.pairs:
        controller.runShrinkPairs();
      case ShrinkStage.lowQuality:
        controller.runShrinkLowQuality();
    }
  }
}

/// The per-stage options (orphan sides, pair drop side, quality threshold).
class _StageOptions extends StatelessWidget {
  const _StageOptions({required this.controller, required this.stage});

  final AppController controller;
  final ShrinkStage stage;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    switch (stage) {
      case ShrinkStage.duplicates:
        return Text(
          context.tr('shrink_duplicates_hint'),
          style: text.bodySmall,
        );
      case ShrinkStage.orphans:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _OrphanCheck(
              value: controller.shrinkOrphanRaws,
              label: context.tr('shrink_orphan_raws'),
              onChanged: controller.setShrinkOrphanRaws,
            ),
            _OrphanCheck(
              value: controller.shrinkOrphanImages,
              label: context.tr('shrink_orphan_images'),
              onChanged: controller.setShrinkOrphanImages,
            ),
          ],
        );
      case ShrinkStage.pairs:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('shrink_pairs_hint'), style: text.bodySmall),
            const SizedBox(height: 4),
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
          ],
        );
      case ShrinkStage.lowQuality:
        final pct = (controller.shrinkQualityThreshold * 100).round();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('shrink_quality_threshold', {'percent': pct}),
              style: text.bodySmall,
            ),
            Slider(
              value: controller.shrinkQualityThreshold,
              divisions: 20,
              label: '$pct%',
              onChanged: controller.setShrinkQualityThreshold,
            ),
          ],
        );
    }
  }
}

/// A compact checkbox + tappable label for an orphan-side toggle, avoiding the
/// Material-ancestor requirement [CheckboxListTile] has inside a decorated card.
class _OrphanCheck extends StatelessWidget {
  const _OrphanCheck({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

/// A stage's result: how many it flagged, the space freed, the running total,
/// and a reviewable, deselectable list of its newly-added candidates.
class _StageResult extends StatelessWidget {
  const _StageResult({required this.controller, required this.outcome});

  final AppController controller;
  final ShrinkStageOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('shrink_stage_flagged', {
            'count': outcome.stageTally.count,
            'size': formatBytes(outcome.stageTally.bytes, context.tr),
          }),
          style: text.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
        Text(
          context.tr('shrink_running_total', {
            'count': outcome.runningTotal.count,
            'size': formatBytes(outcome.runningTotal.bytes, context.tr),
          }),
          style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
        ),
        for (final cand in outcome.added)
          _CandidateRow(controller: controller, candidate: cand),
      ],
    );
  }
}

/// The running grand total across every stage so far.
class _RunningTotal extends StatelessWidget {
  const _RunningTotal({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final total = controller.shrinkTotal;
    return Text(
      context.tr('shrink_grand_total', {
        'count': total.count,
        'size': formatBytes(total.bytes, context.tr),
      }),
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontFeatures: AppTheme.tabular),
    );
  }
}

/// The final review: every staged file with reason, miniature, GPS, size, a
/// deselect checkbox, and the confirm-gated trash button.
class _Summary extends StatelessWidget {
  const _Summary({required this.controller, required this.random});

  final AppController controller;
  final Random random;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final staged = controller.shrinkStaged;
    if (staged.isEmpty) {
      return Text(context.tr('shrink_nothing_staged'), style: text.bodyMedium);
    }
    final n = controller.shrinkSelectedCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('shrink_summary_title'), style: text.titleMedium),
        const SizedBox(height: 8),
        for (final cand in staged)
          _CandidateRow(controller: controller, candidate: cand),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: n == 0
              ? null
              : () => _confirm(context, controller, random),
          icon: const Icon(Icons.delete_outline),
          label: Text(context.tr('shrink_trash_button', {'count': n})),
        ),
      ],
    );
  }
}

/// One staged-file row: deselect checkbox, miniature, filename, reason, GPS
/// indicator, and size.
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.controller, required this.candidate});

  final AppController controller;
  final ShrinkCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final selected = controller.isShrinkSelected(candidate.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: selected,
            onChanged: (v) =>
                controller.setShrinkSelected(candidate.path, v ?? false),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 64,
              height: 64,
              child: PhotoThumbnail(path: candidate.path, height: 64),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(candidate.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                Row(
                  children: [
                    Text(
                      candidate.reason.label(context.tr),
                      style: text.labelSmall?.copyWith(color: scheme.error),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      candidate.hasGps ? Icons.location_on : Icons.location_off,
                      size: 14,
                      color: candidate.hasGps
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    Text(
                      context.tr(
                        candidate.hasGps ? 'shrink_has_gps' : 'shrink_no_gps',
                      ),
                      style: text.labelSmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatBytes(candidate.sizeBytes, context.tr),
            style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
          ),
        ],
      ),
    );
  }
}

/// Determinate hashing progress for a hashing stage in flight.
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

/// Shows the silly-word confirm dialog; on success trashes the staged set.
Future<void> _confirm(
  BuildContext context,
  AppController controller,
  Random random,
) async {
  final word = pickSillyWord(random);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _ConfirmDialog(count: controller.shrinkSelectedCount, word: word),
  );
  if (ok ?? false) await controller.runTrashShrink();
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
      title: Text(context.tr('shrink_confirm_title', {'count': widget.count})),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.tr('shrink_confirm_body')),
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

/// A localized reason label resolver exposed for unit tests.
String shrinkReasonLabel(ShrinkReason reason, Translator tr) =>
    reason.label(tr);
