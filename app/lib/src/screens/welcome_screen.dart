import 'package:flutter/material.dart';

import '../branding/logo_mark.dart';
import '../i18n/app_localizations.dart';
import '../state/controller_scope.dart';
import '../widgets/drop_zone.dart';

/// The no-library hero: logo, name, value prop, a big "Choose photo library"
/// button, and a drag-and-drop zone. The way into the app. (Adding more folders
/// to an existing library is offered later, in the workspace's library bar.)
class WelcomeScreen extends StatelessWidget {
  /// Creates the welcome screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DropZone(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const LogoMark(size: 88),
                const SizedBox(height: 24),
                Text(
                  context.tr('app_name'),
                  style: text.displaySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  context.tr('welcome_value_prop'),
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: controller.pickLibrary,
                  icon: const Icon(Icons.folder_open),
                  label: Text(context.tr('welcome_choose_library')),
                ),
                const SizedBox(height: 14),
                Text(
                  context.tr('welcome_or'),
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scheme.outline,
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.move_to_inbox_outlined, color: scheme.primary),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          context.tr('welcome_drop_hint'),
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  context.tr('welcome_drop_explainer'),
                  style: text.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
