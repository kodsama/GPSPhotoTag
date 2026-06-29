import 'package:flutter/material.dart';

import '../actions/duplicates_action.dart';
import '../actions/prune_action.dart';
import '../actions/shrink_action.dart';
import '../actions/tag_action.dart';
import '../i18n/app_localizations.dart';
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
            Row(
              children: [
                // Navigating back NEVER cancels the run — it keeps going in the
                // background and the workspace card shows its progress. Mid
                // shrink session a stage page was reached from the wizard, so
                // back returns there; standalone it returns to the library. This
                // is the single back affordance in either context.
                TextButton.icon(
                  onPressed: controller.goBackFromAction,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: Text(
                    context.tr(
                      controller.inShrinkSession
                          ? 'shrink_review_back'
                          : 'action_library_back',
                    ),
                  ),
                ),
                const Spacer(),
                if (controller.runStateFor(action).running)
                  TextButton.icon(
                    onPressed: () => controller.cancelAction(action),
                    icon: const Icon(Icons.close, size: 18),
                    label: Text(context.tr('action_cancel')),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(action.icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text(action.title(context.tr), style: text.headlineSmall),
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
    LibraryAction.pruneRaw => const PruneAction(),
    LibraryAction.duplicates => DuplicatesAction(),
    LibraryAction.shrink => ShrinkAction(),
    // Explore is a full screen (AppScreen.explore), never an action panel.
    LibraryAction.explore => const SizedBox.shrink(),
  };
}
