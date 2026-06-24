import 'package:flutter/material.dart';

import '../state/controller_scope.dart';
import '../theme/app_theme.dart';

/// Body of the input step: a large drop-zone-style button to pick the photos
/// folder, plus a one-line confirmation of what was chosen.
class InputStep extends StatelessWidget {
  /// Creates the input step body.
  const InputStep({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final folder = controller.summary.folder;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          onTap: controller.parsing ? null : controller.pickInput,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 36),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: scheme.outline, width: 1.4),
            ),
            child: Column(
              children: [
                Icon(Icons.folder_open, size: 38, color: scheme.primary),
                const SizedBox(height: 12),
                Text(
                  controller.parsing ? 'Scanning…' : 'Choose photos folder',
                  style: text.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Folders are scanned recursively for photos and GPS files.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
        ),
        if (folder != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$folder — ${controller.summary.photoCount} photo(s) found',
                  style: text.bodyMedium,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
