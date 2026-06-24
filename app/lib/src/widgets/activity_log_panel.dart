import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../state/log_entry.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A right-side slide-over listing the activity log; tapping the scrim closes it.
class ActivityLogPanel extends StatelessWidget {
  /// Builds the panel with a [visible] flag and an [onClose] callback.
  const ActivityLogPanel({
    super.key,
    required this.visible,
    required this.onClose,
  });

  /// Whether the panel is shown.
  final bool visible;

  /// Invoked when the scrim is tapped.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: Stack(
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: visible ? 1 : 0,
            child: GestureDetector(
              onTap: onClose,
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOut,
            top: 0,
            bottom: 0,
            right: visible ? 0 : -380,
            width: 360,
            child: _Panel(controller: controller, onClose: onClose),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.controller, required this.onClose});

  final AppController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final entries = controller.logEntries.reversed.toList(growable: false);
    return Material(
      color: scheme.surface,
      elevation: 8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
            child: Row(
              children: [
                Text('Activity log', style: text.titleMedium),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close), onPressed: onClose),
              ],
            ),
          ),
          Container(height: 1, color: scheme.outline),
          Expanded(
            child: entries.isEmpty
                ? Center(child: Text('No activity yet.', style: text.bodySmall))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => _LogRow(entry: entries[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A single level-coloured log line.
class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.clock,
            style: text.bodySmall?.copyWith(fontFeatures: AppTheme.tabular),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.message,
              style: text.bodySmall?.copyWith(
                color: _color(context, entry.level),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _color(BuildContext context, LogLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      LogLevel.debug => scheme.onSurface.withValues(alpha: 0.55),
      LogLevel.info => scheme.onSurface,
      LogLevel.warning => AppColors.warning,
      LogLevel.error => AppColors.danger,
    };
  }
}
