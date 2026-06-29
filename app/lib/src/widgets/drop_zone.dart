import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../state/controller_scope.dart';
import '../theme/app_theme.dart';

/// Wraps [child] in a drag-and-drop target that adds dropped folders and photo/
/// GPS files to the current library (rescanning the combined roots).
///
/// The thin platform shell: the [DropTarget] callback hands the dropped paths
/// straight to [AppController.addDroppedPaths], where the pure classify/merge
/// logic (covered by tests) lives. On drag-over it paints a highlighted border
/// so the drop affordance is obvious.
class DropZone extends StatefulWidget {
  /// Wraps [child] as a drop target.
  const DropZone({super.key, required this.child});

  /// The content shown inside (and highlighted over) the drop zone.
  final Widget child;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  bool _dragging = false;

  Future<void> _onDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final paths = [for (final f in details.files) f.path];
    if (paths.isEmpty) return;
    await ControllerScope.of(context).addDroppedPaths(paths);
  }

  @override
  Widget build(BuildContext context) {
    // desktop_drop's DropTarget is a desktop affordance; on mobile there is no
    // drag-and-drop, so pass the child straight through (no DropTarget at all).
    if (ControllerScope.of(context).isMobile) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _onDrop,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(
            color: _dragging ? scheme.primary : Colors.transparent,
            width: 2,
          ),
          color: _dragging ? scheme.primary.withValues(alpha: 0.06) : null,
        ),
        child: widget.child,
      ),
    );
  }
}
