import 'package:flutter/material.dart';

import '../branding/logo_mark.dart';
import '../state/controller_scope.dart';
import '../widgets/drop_zone.dart';

/// The no-library hero: logo, name, value prop, a big "Choose photo library"
/// button, an "Add folder" affordance, and a drag-and-drop zone. The way into
/// the app.
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
                  'Stunda',
                  style: text.displaySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  'Place your photos on the map from the GPS tracks and '
                  'location history you already have.',
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: controller.pickLibrary,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose photo library'),
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.addFolder,
                      icon: const Icon(Icons.add),
                      label: const Text('Add folder'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
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
                          'Drop folders or photos here',
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Point it at any folder, or combine several. Photos, GPX/KML '
                  'tracks, and Google Timeline exports anywhere inside — in any '
                  'layout — are all found.',
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
