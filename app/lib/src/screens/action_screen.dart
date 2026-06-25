import 'package:flutter/material.dart';

import '../actions/map_action.dart';
import '../actions/prune_action.dart';
import '../actions/tag_action.dart';
import '../state/controller_scope.dart';
import '../state/library_action.dart';

/// The focused panel for the selected [LibraryAction]: a "← Library" affordance,
/// the action title, and the action body. Routing is one switch over the
/// extensible [LibraryAction] enum.
class ActionScreen extends StatelessWidget {
  /// Creates the action screen.
  const ActionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final action = controller.action;
    if (action == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              onPressed: controller.running ? null : controller.backToLibrary,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Library'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(action.icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text(action.title, style: text.headlineSmall),
              ],
            ),
            const SizedBox(height: 20),
            _body(action),
          ],
        ),
      ),
    );
  }

  Widget _body(LibraryAction action) => switch (action) {
    LibraryAction.tag => const TagAction(),
    LibraryAction.map => const MapAction(),
    LibraryAction.pruneRaw => const PruneAction(),
  };
}
