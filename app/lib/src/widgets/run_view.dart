import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';
import 'package:path/path.dart' as p;

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'status_pill.dart';

/// Live run feedback shared by every action: a global progress bar with
/// done/total and the most recent per-item rows (status pill + coordinates).
class RunProgress extends StatelessWidget {
  /// Builds progress for [done]/[total] with the latest [rows].
  const RunProgress({
    super.key,
    required this.done,
    required this.total,
    required this.fraction,
    required this.rows,
  });

  /// Items completed so far.
  final int done;

  /// Total items in the run (0 = indeterminate).
  final int total;

  /// Completion fraction in 0..1.
  final double fraction;

  /// The most recent per-item rows, newest first.
  final List<PhotoRow> rows;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: total == 0 ? null : fraction,
                  minHeight: 8,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$done/$total',
              style: text.bodyMedium?.copyWith(fontFeatures: AppTheme.tabular),
            ),
          ],
        ),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Recent results', style: text.titleMedium),
          const SizedBox(height: 8),
          _ResultsList(rows: rows),
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

/// One per-item row: filename, coordinates (tabular), and a status pill.
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
class ErrorBanner extends StatelessWidget {
  /// Shows [message] in an error-styled strip.
  const ErrorBanner({super.key, required this.message});

  /// The error text.
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
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// The done summary rendered as a tidy two-column table.
class ResultSummaryTable extends StatelessWidget {
  /// Renders [summary] (status → count) with a total row.
  const ResultSummaryTable({super.key, required this.summary});

  /// The status tally from the completed run.
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
