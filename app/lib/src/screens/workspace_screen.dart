import 'package:flutter/material.dart';

import '../state/controller_scope.dart';
import '../state/library_action.dart';
import '../widgets/action_card.dart';
import '../widgets/content_panel.dart';
import '../widgets/library_bar.dart';

/// The hub: a library bar, an expandable content breakdown, and the responsive
/// grid of action cards. Each card's readiness reflects the scan; tapping a
/// ready card opens its focused action panel.
class WorkspaceScreen extends StatelessWidget {
  /// Creates the workspace screen.
  const WorkspaceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final scan = controller.scan;
    if (scan == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LibraryBar(scan: scan),
            const SizedBox(height: 16),
            ContentPanel(scan: scan),
            const SizedBox(height: 24),
            Text('Actions', style: text.titleMedium),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, c) {
                const gap = 16.0;
                // Up to 3 across; reflow to 2 / 1 as the window narrows. Cards
                // share the width equally so there's never a dead gap.
                final cols = c.maxWidth >= 760
                    ? 3
                    : c.maxWidth >= 480
                    ? 2
                    : 1;
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final action in LibraryAction.all)
                      SizedBox(
                        width: w,
                        height: 196,
                        child: ActionCard(
                          action: action,
                          readiness: action.readiness(scan),
                          onOpen: () => controller.openAction(action),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
