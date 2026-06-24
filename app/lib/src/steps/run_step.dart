import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:path/path.dart' as p;

import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/status_pill.dart';

/// Body of the run step: a Start action, a live progress bar with done/total,
/// the most recent per-item results, and a prominent error surface.
class RunStep extends StatelessWidget {
  /// Creates the run step body.
  const RunStep({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          _ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        if (!controller.running && controller.lastSummary == null)
          FilledButton.icon(
            onPressed: controller.runTag,
            icon: const Icon(Icons.play_arrow),
            label: Text('Tag ${controller.includedCount} photo(s)'),
          ),
        if (controller.running) ...[
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: controller.total == 0 ? null : controller.fraction,
                    minHeight: 8,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text('${controller.done}/${controller.total}',
                  style: text.bodyMedium?.copyWith(
                      fontFeatures: AppTheme.tabular)),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (controller.rows.isNotEmpty) ...[
          Text('Recent results', style: text.titleMedium),
          const SizedBox(height: 8),
          _ResultsList(rows: controller.rows),
        ],
      ],
    );
  }
}

/// A scrollable list of the most recent per-item rows.
class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.rows});

  final List<PhotoRow> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outline),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: rows.length,
        itemBuilder: (context, i) => _ResultRow(row: rows[i]),
      ),
    );
  }
}

/// One per-item row: filename, status pill, and coordinates (tabular).
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.row});

  final PhotoRow row;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final loc = row.location;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              p.basename(row.path),
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium,
            ),
          ),
          if (loc != null) ...[
            const SizedBox(width: 8),
            Text(
              '${loc.latitude.toStringAsFixed(4)}, '
              '${loc.longitude.toStringAsFixed(4)}',
              style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
            ),
          ],
          const SizedBox(width: 10),
          StatusPill(row.status),
        ],
      ),
    );
  }
}

/// A prominent red banner for fatal errors.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.danger),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}
