import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../explore/photo_detail_panel.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/duplicates_model.dart' show pickSillyWord, sillyWordMatches;
import '../state/library_action.dart' show Translator;
import '../state/shrink_model.dart';
import '../theme/app_theme.dart';
import '../widgets/help.dart';
import '../widgets/run_view.dart';
import 'duplicates_action.dart' show DuplicatesAction, formatBytes;
import 'prune_action.dart' show PruneAction;
import 'shrink_pairs_review.dart';
import 'shrink_low_quality_review.dart';

/// The "Shrink picture library" wizard.
///
/// A cumulative shrink session: the hub is a step list of OPT-IN stages —
/// duplicates, orphans, redundant RAW+photo pairs, and low quality. Opening a
/// stage navigates to that feature's REAL review surface in a deferred shrink
/// session: the page's terminal button becomes "Add to shrink list" (folding the
/// chosen files into ONE cumulative [StagedSet], deduped across stages) and
/// returns here. A running total tracks the space "to free"; a final review
/// lists every staged file (reason, miniature, GPS indicator, size) and gates
/// the actual trash behind the silly-word confirm. Nothing is deleted until then.
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
    // A stage's real review page is open in deferred shrink-session mode.
    final stage = controller.shrinkActiveStage;
    if (stage != null) {
      return _StageReview(controller: controller, stage: stage);
    }
    return _Wizard(controller: controller, random: _random);
  }
}

/// Routes to the real review surface for the active [stage], each running in
/// shrink-session mode (its terminal button reads [AppController.inShrinkSession]
/// and adds to the staged set instead of trashing).
class _StageReview extends StatelessWidget {
  const _StageReview({required this.controller, required this.stage});

  final AppController controller;
  final ShrinkStage stage;

  @override
  Widget build(BuildContext context) {
    final body = switch (stage) {
      ShrinkStage.duplicates => DuplicatesAction(),
      ShrinkStage.orphans => const PruneAction(),
      ShrinkStage.pairs => const ShrinkPairsReview(),
      ShrinkStage.lowQuality => const ShrinkLowQualityReview(),
    };
    // The single back affordance lives on the action screen's top bar (it reads
    // [AppController.inShrinkSession] and returns to the wizard). The stage page
    // shows only its title + body, so there is exactly one, unambiguous back.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(shrinkStageTitleKey(stage)),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        body,
      ],
    );
  }
}

/// The wizard hub: every stage as a row (include/skip toggle, an open/review
/// button, and its contribution once reviewed), the running total, and the final
/// review + confirm.
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
          HelpTarget(
            topic: HelpTopic.shrink,
            child: _StageCard(controller: controller, stage: stage),
          ),
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

/// The one-line hint key describing what a stage does.
String shrinkStageHintKey(ShrinkStage stage) => switch (stage) {
  ShrinkStage.duplicates => 'shrink_duplicates_hint',
  ShrinkStage.orphans => 'shrink_orphans_hint',
  ShrinkStage.pairs => 'shrink_pairs_hint',
  ShrinkStage.lowQuality => 'shrink_low_quality_hint',
};

/// One stage row: include toggle, an open/review button, and (once reviewed) the
/// stage's contribution to the shrink list.
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
            Text(context.tr(shrinkStageHintKey(stage)), style: text.bodySmall),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => controller.openShrinkStage(stage),
              icon: Icon(outcome == null ? Icons.search : Icons.edit, size: 18),
              label: Text(
                context.tr(
                  outcome == null ? 'shrink_open_stage' : 'shrink_review_again',
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (outcome == null)
              Text(
                context.tr('shrink_stage_not_reviewed'),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('shrink_stage_added', {
                        'count': outcome.stageTally.count,
                        'size': formatBytes(
                          outcome.stageTally.bytes,
                          context.tr,
                        ),
                      }),
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                        fontFeatures: AppTheme.tabular,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Clears ONLY this stage's contribution + cached selections;
                  // other stages and the running total adjust independently.
                  TextButton.icon(
                    onPressed: () => controller.clearShrinkStage(stage),
                    icon: const Icon(Icons.clear, size: 16),
                    label: Text(context.tr('shrink_stage_clear')),
                  ),
                ],
              ),
          ] else
            Text(
              context.tr('shrink_stage_skipped'),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// The running grand total across every staged file so far ("to free").
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
          // Tapping the miniature opens the big-preview viewer (single mode).
          Tooltip(
            message: context.tr('tt_dup_open_compare'),
            child: InkWell(
              onTap: () => openFullscreen(context, candidate.path),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: PhotoThumbnail(path: candidate.path, height: 64),
                ),
              ),
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

/// The "Add to shrink list" terminal button shared by the stage review pages
/// when a shrink session is active. Reads the [count] the stage will add and
/// folds the selection into the staged set on tap, returning to the wizard.
class ShrinkAddButton extends StatelessWidget {
  /// Creates the add-to-list button for [count] selected files.
  const ShrinkAddButton({super.key, required this.count});

  /// Number of files the active stage will add.
  final int count;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    return FilledButton.icon(
      onPressed: count == 0 ? null : controller.addActiveStageToShrinkList,
      icon: const Icon(Icons.playlist_add),
      label: Text(
        count == 0
            ? context.tr('shrink_add_none')
            : context.tr('shrink_add_to_list', {'count': count}),
      ),
    );
  }
}
