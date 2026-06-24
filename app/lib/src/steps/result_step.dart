import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Body of the result step: the run summary as a table plus follow-up actions
/// (render heatmap, prune orphan RAWs, fix dates, tag another).
class ResultStep extends StatefulWidget {
  /// Creates the result step body.
  const ResultStep({super.key});

  @override
  State<ResultStep> createState() => _ResultStepState();
}

class _ResultStepState extends State<ResultStep> {
  String? _heatmapPath;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final summary = controller.lastSummary;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary != null) _SummaryTable(summary: summary),
        const SizedBox(height: 20),
        Text('Follow-up tools', style: text.titleMedium),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _action(
              context,
              Icons.map,
              'Render heatmap',
              controller.running ? null : () => _renderMap(controller),
            ),
            _action(
              context,
              Icons.delete_sweep,
              'Prune orphan RAWs',
              controller.running ? null : () => _confirmPrune(controller),
            ),
            _action(
              context,
              Icons.event,
              'Fix dates',
              controller.running ? null : () => _chooseFixDates(controller),
            ),
            _action(
              context,
              Icons.refresh,
              'Tag another',
              controller.running ? null : () => _tagAnother(controller),
            ),
          ],
        ),
        if (_heatmapPath != null) ...[
          const SizedBox(height: 18),
          Text('Heatmap', style: text.titleMedium),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: Image.file(File(_heatmapPath!), fit: BoxFit.contain),
          ),
        ],
      ],
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback? onTap,
  ) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );

  Future<void> _renderMap(AppController controller) async {
    final path = await controller.renderMap();
    if (mounted) setState(() => _heatmapPath = path);
  }

  Future<void> _confirmPrune(AppController controller) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prune orphan RAWs?'),
        content: const Text(
          'RAW files with no matching JPG/HEIC companion will be moved to the '
          'Trash. This scans the picked folder recursively.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Prune'),
          ),
        ],
      ),
    );
    if (ok ?? false) await controller.runPrune();
  }

  Future<void> _chooseFixDates(AppController controller) async {
    final mode = await showDialog<FixDatesMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Fix dates'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, FixDatesMode.exif),
            child: const Text('Set file date from EXIF capture time'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, FixDatesMode.file),
            child: const Text('Set EXIF capture time from file date'),
          ),
        ],
      ),
    );
    if (mode != null) await controller.runFixDates(mode);
  }

  void _tagAnother(AppController controller) => controller.tagAnother();
}

/// The done summary rendered as a tidy two-column table.
class _SummaryTable extends StatelessWidget {
  const _SummaryTable({required this.summary});

  final Map<String, int> summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = summary.values.fold(0, (a, b) => a + b);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        children: [
          for (final entry in summary.entries)
            _row(text, entry.key.replaceAll('_', ' '), '${entry.value}'),
          Container(height: 1, color: scheme.outline),
          _row(text, 'total', '$total', bold: true),
        ],
      ),
    );
  }

  Widget _row(TextTheme text, String label, String value, {bool bold = false}) {
    final style = bold
        ? text.titleMedium
        : text.bodyMedium?.copyWith(color: AppColors.inkSoft);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(
            value,
            style: (bold ? text.titleMedium : text.bodyMedium)?.copyWith(
              fontFeatures: AppTheme.tabular,
            ),
          ),
        ],
      ),
    );
  }
}
