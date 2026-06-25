import 'package:flutter/material.dart';

import '../branding/logo_mark.dart';
import '../state/controller_scope.dart';

/// The no-library hero: logo, name, value prop, and a big "Choose photo
/// library" button. The only way into the app.
class WelcomeScreen extends StatelessWidget {
  /// Creates the welcome screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
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
              'Place your photos on the map from the GPS tracks and location '
              'history you already have.',
              style: text.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: controller.pickLibrary,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose photo library'),
            ),
            const SizedBox(height: 16),
            Text(
              'Point it at any folder. Photos, GPX/KML tracks, and Google '
              'Timeline exports anywhere inside — in any layout — are all '
              'found.',
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
