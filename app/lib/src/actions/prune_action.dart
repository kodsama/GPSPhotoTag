import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:path/path.dart' as p;

import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/prune_direction.dart';
import '../widgets/run_view.dart';
import 'shrink_action.dart' show ShrinkAddButton;

/// The Match-Images-to-RAW flow.
///
/// Destructive actions preview first, then confirm: opening this action does
/// NOT delete anything. It shows a reviewable, filterable, selectable list of
/// every classified photo, with a direction toggle choosing which orphans are
/// trashable (orphan RAWs, or orphan images). Only after the user confirms a
/// dialog does it move the selected files to the Trash. Live progress and a
/// result summary follow, then a back-to-library affordance.
class PruneAction extends StatelessWidget {
  /// Creates the prune action body.
  const PruneAction({super.key});

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
          if (controller.errorMessage != null) ...[
            ErrorBanner(message: controller.errorMessage!),
            const SizedBox(height: 14),
          ],
          RunProgress(
            done: controller.done,
            total: controller.total,
            fraction: controller.fraction,
            rows: controller.rows,
          ),
        ],
      );
    }
    return _Review(controller: controller);
  }
}

/// The preview/review surface: direction toggle, summary header, filter row,
/// scrollable list, and the confirm-gated primary button.
class _Review extends StatelessWidget {
  const _Review({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final pairing = controller.pairing;
    final text = Theme.of(context).textTheme;
    if (pairing == null) {
      return Text(context.tr('prune_no_library'), style: text.bodyMedium);
    }

    final filtered = controller.filteredPairing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        _DirectionToggle(controller: controller),
        const SizedBox(height: 12),
        Text(
          context.tr('prune_review_intro', {
            'description': context.tr(controller.pruneDirection.descriptionKey),
          }),
          style: text.bodyMedium,
        ),
        const SizedBox(height: 12),
        Text(
          context.tr('prune_summary', {
            'orphans': pairing.orphanCount,
            'paired': pairing.pairedRawCount,
            'photos': pairing.photoWithoutRawCount,
          }),
          style: text.titleMedium,
        ),
        const SizedBox(height: 16),
        _FilterRow(controller: controller),
        const SizedBox(height: 12),
        _SelectAll(controller: controller),
        const SizedBox(height: 8),
        _FileList(controller: controller, files: filtered),
        const SizedBox(height: 20),
        _ConfirmButton(controller: controller),
      ],
    );
  }
}

/// The A/B direction selector: which orphans are selectable and trashed.
class _DirectionToggle extends StatelessWidget {
  const _DirectionToggle({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<PruneDirection>(
      segments: [
        ButtonSegment(
          value: PruneDirection.removeOrphanRaws,
          label: Text(context.tr('prune_dir_orphan_raws')),
          icon: const Icon(Icons.raw_on, size: 18),
          tooltip: context.tr('tt_prune_dir_orphan_raws'),
        ),
        ButtonSegment(
          value: PruneDirection.removeOrphanImages,
          label: Text(context.tr('prune_dir_orphan_images')),
          icon: const Icon(Icons.image_outlined, size: 18),
          tooltip: context.tr('tt_prune_dir_orphan_images'),
        ),
      ],
      selected: {controller.pruneDirection},
      onSelectionChanged: (s) => controller.setPruneDirection(s.first),
    );
  }
}

/// A filename text filter plus the per-kind visibility toggles.
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          onChanged: controller.setPruneFilter,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: context.tr('prune_filter_hint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Orphan RAWs — selectable deletion candidates in direction A.
            FilterChip(
              label: Text(context.tr('prune_chip_orphan_raws')),
              tooltip: context.tr('tt_prune_chip'),
              selected: controller.isKindVisible(PairKind.orphanRaw),
              onSelected: (v) =>
                  controller.setKindVisible(PairKind.orphanRaw, v),
            ),
            // One chip for the RAW+JPG pairing: shows both the paired RAFs and
            // their JPG twins (was two chips describing the same pairing).
            FilterChip(
              label: Text(context.tr('prune_chip_paired')),
              tooltip: context.tr('tt_prune_chip'),
              selected:
                  controller.isKindVisible(PairKind.pairedRaw) &&
                  controller.isKindVisible(PairKind.photoWithRaw),
              onSelected: (v) {
                controller.setKindVisible(PairKind.pairedRaw, v);
                controller.setKindVisible(PairKind.photoWithRaw, v);
              },
            ),
            // Orphan images — selectable deletion candidates in direction B.
            FilterChip(
              label: Text(context.tr('prune_chip_photos_no_raw')),
              tooltip: context.tr('tt_prune_chip'),
              selected: controller.isKindVisible(PairKind.photoWithoutRaw),
              onSelected: (v) =>
                  controller.setKindVisible(PairKind.photoWithoutRaw, v),
            ),
          ],
        ),
      ],
    );
  }
}

/// A "select all / none" affordance for the active direction's candidates.
class _SelectAll extends StatelessWidget {
  const _SelectAll({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final candidates = controller.pruneCandidateCount;
    final selected = controller.selectedCount;
    final text = Theme.of(context).textTheme;
    final key = controller.pruneDirection == PruneDirection.removeOrphanRaws
        ? 'prune_selected_orphan_raws'
        : 'prune_selected_orphan_images';
    return Row(
      children: [
        Checkbox(
          value: candidates == 0
              ? false
              : selected == candidates
              ? true
              : selected == 0
              ? false
              : null,
          tristate: true,
          onChanged: candidates == 0
              ? null
              : (_) => controller.selectAllCandidates(selected != candidates),
        ),
        Text(
          context.tr(key, {'selected': selected, 'candidates': candidates}),
          style: text.bodySmall,
        ),
      ],
    );
  }
}

/// The scrollable, virtualised list of filtered review rows.
class _FileList extends StatelessWidget {
  const _FileList({required this.controller, required this.files});

  final AppController controller;
  final List<PairedFile> files;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (files.isEmpty) {
      return Container(
        height: 80,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outline),
        ),
        child: Text(context.tr('prune_no_files_match'), style: text.bodySmall),
      );
    }
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outline),
      ),
      // ListView.builder keeps thousands of rows cheap (only visible ones build).
      child: ListView.builder(
        itemCount: files.length,
        itemBuilder: (context, i) =>
            _FileRow(controller: controller, file: files[i]),
      ),
    );
  }
}

/// One review row: filename, a small kind tag, and (for targets) a checkbox.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.controller, required this.file});

  final AppController controller;
  final PairedFile file;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isTarget = file.kind == controller.pruneDirection.target;
    final selected = controller.selectedPaths.contains(file.path);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          // Only the active direction's candidates are selectable; context rows
          // show a placeholder so names stay aligned.
          if (isTarget)
            Checkbox(
              value: selected,
              onChanged: (v) =>
                  controller.toggleSelected(file.path, v ?? false),
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: Text(
              p.basename(file.path),
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          _KindTag(kind: file.kind, emphasised: isTarget),
        ],
      ),
    );
  }
}

/// A small coloured tag naming a [PairKind]; the [emphasised] target is red.
class _KindTag extends StatelessWidget {
  const _KindTag({required this.kind, required this.emphasised});

  final PairKind kind;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = emphasised ? scheme.error : scheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        context.tr(_kindTagKeys[kind]!),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The primary "Move N selected to Trash" button; opens a confirm dialog.
class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final n = controller.selectedCount;
    // In a deferred shrink session the chosen orphans are added to the shrink
    // list and we return; standalone they move to Trash behind a confirm.
    if (controller.inShrinkSession) return ShrinkAddButton(count: n);
    return Tooltip(
      message: context.tr('tt_prune_move_selected'),
      child: FilledButton.icon(
        onPressed: n == 0 ? null : () => _confirm(context),
        icon: const Icon(Icons.delete_outline),
        label: Text(context.tr('prune_move_selected', {'count': n})),
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final n = controller.selectedCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('prune_confirm_title', {'count': n})),
        content: Text(context.tr('prune_confirm_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('prune_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('prune_move_to_trash')),
          ),
        ],
      ),
    );
    if (ok ?? false) await controller.runTrashSelected();
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ResultSummaryTable(summary: controller.lastSummary!),
        if (controller.rows.isNotEmpty) ...[
          const SizedBox(height: 16),
          RunProgress(
            done: controller.done,
            total: controller.total,
            fraction: controller.fraction,
            rows: controller.rows,
          ),
        ],
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

const Map<PairKind, String> _kindTagKeys = {
  PairKind.orphanRaw: 'prune_kind_orphan',
  PairKind.pairedRaw: 'prune_kind_paired',
  PairKind.photoWithoutRaw: 'prune_kind_no_raw',
  PairKind.photoWithRaw: 'prune_kind_has_raw',
};
