import 'package:flutter/material.dart';

import '../state/library_action.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// One action in the workspace grid: icon, title, one-line description, and a
/// readiness chip. Disabled when [readiness] blocks it; tapping a ready card
/// invokes [onOpen]. Hover/pressed states make it feel tactile.
class ActionCard extends StatefulWidget {
  /// Builds a card for [action] with its computed [readiness].
  const ActionCard({
    super.key,
    required this.action,
    required this.readiness,
    required this.onOpen,
  });

  /// The action this card represents.
  final LibraryAction action;

  /// Whether the action can run, and the chip text.
  final ActionReadiness readiness;

  /// Invoked when an enabled card is tapped.
  final VoidCallback onOpen;

  @override
  State<ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<ActionCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final enabled = widget.readiness.enabled;
    final base = scheme.surface;
    final color = !enabled
        ? base
        : _hover
        ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.06), base)
        : base;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: double.infinity,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppTheme.radius),
            border: Border.all(
              color: enabled && _hover ? scheme.primary : scheme.outline,
              width: enabled && _hover ? 1.4 : 1,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppTheme.radius),
              onTap: enabled ? widget.onOpen : null,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(widget.action.icon, size: 28, color: scheme.primary),
                    const SizedBox(height: 14),
                    Text(widget.action.title, style: text.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      widget.action.description,
                      style: text.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Spacer(),
                    _ReadinessChip(readiness: widget.readiness),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small chip echoing whether the action is ready, in a fitting colour.
class _ReadinessChip extends StatelessWidget {
  const _ReadinessChip({required this.readiness});

  final ActionReadiness readiness;

  @override
  Widget build(BuildContext context) {
    final color = readiness.enabled ? AppColors.success : AppColors.inkSoft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            readiness.enabled
                ? Icons.check_circle_outline
                : Icons.do_not_disturb_on_outlined,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              readiness.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
