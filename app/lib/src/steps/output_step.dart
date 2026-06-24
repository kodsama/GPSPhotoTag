import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../state/controller_scope.dart';
import '../theme/app_colors.dart';

/// Body of the output step: when copying, pick a destination folder; otherwise
/// confirm that originals will be modified in place.
class OutputStep extends StatelessWidget {
  /// Creates the output step body.
  const OutputStep({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (!controller.copyToFolder) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.edit_note, color: AppColors.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Originals will be modified in place. Turn on "Copy to a new '
                'folder" in Options to keep them untouched.',
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    final dir = controller.outDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await getDirectoryPath();
            if (picked != null) controller.setOutDir(picked);
          },
          icon: const Icon(Icons.folder_open),
          label: Text(dir == null ? 'Choose destination folder' : 'Change'),
        ),
        if (dir != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(dir, style: text.bodyMedium)),
            ],
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Pick a folder to continue.',
                style: text.bodySmall?.copyWith(color: AppColors.warning)),
          ),
      ],
    );
  }
}
