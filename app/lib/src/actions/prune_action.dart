import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../widgets/run_view.dart';

/// The Remove-orphan-RAWs flow: a dry-run toggle to preview first, a clearly
/// labelled commit button ("Move N RAWs to Trash" / "Preview orphan RAWs"),
/// live progress, the result summary, and a back-to-library affordance.
class PruneAction extends StatefulWidget {
  /// Creates the prune action body.
  const PruneAction({super.key});

  @override
  State<PruneAction> createState() => _PruneActionState();
}

class _PruneActionState extends State<PruneAction> {
  bool _dryRun = true;

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
    return _Options(controller: controller, dryRun: _dryRun, onDryRun: _set);
  }

  void _set(bool value) => setState(() => _dryRun = value);
}

class _Options extends StatelessWidget {
  const _Options({
    required this.controller,
    required this.dryRun,
    required this.onDryRun,
  });

  final AppController controller;
  final bool dryRun;
  final ValueChanged<bool> onDryRun;

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
        Text(
          'RAW files with no matching JPG/HEIC companion are moved to the '
          'Trash. The scan walks the whole library.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Preview first (dry run)', style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    'List what would be moved without touching any files.',
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            Switch(value: dryRun, onChanged: onDryRun),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => controller.runPrune(dryRun: dryRun),
          icon: Icon(dryRun ? Icons.search : Icons.delete_outline),
          label: Text(
            dryRun
                ? 'Preview orphan RAWs'
                : 'Move orphan RAWs to '
                      'Trash',
          ),
        ),
      ],
    );
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
