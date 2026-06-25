import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';
import 'package:path/path.dart' as p;

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../widgets/run_view.dart';

/// The Remove-orphan-RAWs flow.
///
/// Destructive actions preview first, then confirm: opening this action does
/// NOT delete anything. It shows a reviewable, filterable, selectable list of
/// every classified photo (orphan RAWs pre-selected), and only after the user
/// confirms a dialog does it move the selected files to the Trash. Live
/// progress and a result summary follow, then a back-to-library affordance.
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

/// The preview/review surface: summary header, filter row, scrollable list, and
/// the confirm-gated primary button.
class _Review extends StatelessWidget {
  const _Review({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final pairing = controller.pairing;
    final text = Theme.of(context).textTheme;
    if (pairing == null) {
      return Text('No library scanned.', style: text.bodyMedium);
    }

    final filtered = controller.filteredPairing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        Text(
          'Nothing is removed until you review the list below and confirm. '
          'RAW files with no JPG/HEIC companion anywhere in the library are '
          'pre-selected.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 12),
        Text(
          '${pairing.orphanCount} orphan RAWs · '
          '${pairing.pairedRawCount} RAWs with a JPG · '
          '${pairing.photoWithoutRawCount} photos without a RAW',
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
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Filter by filename',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _kindLabels.entries)
              FilterChip(
                label: Text(entry.value),
                selected: controller.isKindVisible(entry.key),
                onSelected: (v) => controller.setKindVisible(entry.key, v),
              ),
          ],
        ),
      ],
    );
  }
}

/// A "select all / none" affordance for the orphan candidates.
class _SelectAll extends StatelessWidget {
  const _SelectAll({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final orphans = controller.pairing?.orphanCount ?? 0;
    final selected = controller.selectedCount;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Checkbox(
          value: orphans == 0
              ? false
              : selected == orphans
              ? true
              : selected == 0
              ? false
              : null,
          tristate: true,
          onChanged: orphans == 0
              ? null
              : (_) => controller.selectAllOrphans(selected != orphans),
        ),
        Text(
          '$selected of $orphans orphan RAWs selected',
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
        child: Text('No files match.', style: text.bodySmall),
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

/// One review row: filename, a small kind tag, and (for orphans) a checkbox.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.controller, required this.file});

  final AppController controller;
  final PairedFile file;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isOrphan = file.kind == PairKind.orphanRaw;
    final selected = controller.selectedPaths.contains(file.path);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          // Only orphan RAWs are selectable; context rows show a placeholder so
          // names stay aligned.
          if (isOrphan)
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
          _KindTag(kind: file.kind),
        ],
      ),
    );
  }
}

/// A small coloured tag naming a [PairKind].
class _KindTag extends StatelessWidget {
  const _KindTag({required this.kind});

  final PairKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = kind == PairKind.orphanRaw ? scheme.error : scheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        _kindTags[kind]!,
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
    return FilledButton.icon(
      onPressed: n == 0 ? null : () => _confirm(context),
      icon: const Icon(Icons.delete_outline),
      label: Text('Move $n selected to Trash'),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final n = controller.selectedCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move $n RAW files to the Trash?'),
        content: const Text('You can restore them from the Trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move to Trash'),
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
          label: const Text('Done — back to library'),
        ),
      ],
    );
  }
}

const Map<PairKind, String> _kindLabels = {
  PairKind.orphanRaw: 'Orphan RAWs',
  PairKind.pairedRaw: 'RAWs with JPG',
  PairKind.photoWithoutRaw: 'Photos without RAW',
  PairKind.photoWithRaw: 'Photos with RAW',
};

const Map<PairKind, String> _kindTags = {
  PairKind.orphanRaw: 'Orphan',
  PairKind.pairedRaw: 'Paired',
  PairKind.photoWithoutRaw: 'No RAW',
  PairKind.photoWithRaw: 'Has RAW',
};
