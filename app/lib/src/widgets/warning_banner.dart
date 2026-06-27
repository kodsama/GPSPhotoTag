import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';

/// A slim, dismissible warning strip shown under the header when the startup
/// environment self-check found a problem (e.g. exiftool couldn't launch).
///
/// Renders nothing when there is no warning or the user has dismissed it, so it
/// never blocks the walkthrough below.
class WarningBanner extends StatelessWidget {
  /// Creates the banner.
  const WarningBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    if (!controller.hasEnvironmentWarning || controller.warningDismissed) {
      return const SizedBox.shrink();
    }
    final message = context.tr('warning_exiftool');
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      color: AppColors.warning.withValues(alpha: 0.12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: AppColors.warning,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: text.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: context.tr('warning_dismiss'),
            icon: const Icon(Icons.close, size: 18),
            color: AppColors.warning,
            visualDensity: VisualDensity.compact,
            onPressed: controller.dismissWarning,
          ),
        ],
      ),
    );
  }
}
