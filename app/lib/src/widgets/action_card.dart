import 'dart:ui';

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../state/action_run_state.dart';
import '../state/library_action.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'glass.dart';

/// One action in the workspace grid: icon, title, one-line description, and a
/// readiness chip. Disabled when [readiness] blocks it; tapping a ready card
/// invokes [onOpen]. Hover/pressed states make it feel tactile.
///
/// While the action's background [runState] is running, a progress ring overlays
/// the icon (determinate when the fraction is known, else indeterminate) and the
/// card stays tappable so the user can return to watch it. When a finished run
/// needs review, a gently pulsing attention badge shows until the user opens it.
class ActionCard extends StatefulWidget {
  /// Builds a card for [action] with its computed [readiness] and [runState].
  const ActionCard({
    super.key,
    required this.action,
    required this.readiness,
    required this.onOpen,
    this.runState = ActionRunState.idle,
  });

  /// The action this card represents.
  final LibraryAction action;

  /// Whether the action can run, and the chip text.
  final ActionReadiness readiness;

  /// The action's background-run lifecycle (drives the ring + badge).
  final ActionRunState runState;

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
    final run = widget.runState;
    // A running or to-be-reviewed action is always tappable (to return to it),
    // even if its idle readiness would block a fresh run.
    final enabled = widget.readiness.enabled || run.running || run.needsReview;
    final radius = BorderRadius.circular(AppTheme.radius);
    // Frosted fill, with a faint primary wash on hover for tactility.
    final decoration = glassDecoration(scheme, radius).copyWith(
      color: enabled && _hover
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.10),
              scheme.surface.withValues(alpha: 0.62),
            )
          : scheme.surface.withValues(alpha: 0.62),
      border: Border.all(
        color: enabled && _hover
            ? scheme.primary
            : scheme.outline.withValues(alpha: 0.6),
        width: enabled && _hover ? 1.4 : 1,
      ),
    );

    return Tooltip(
      message: context.tr('tt_action_card', {
        'description': widget.action.description(context.tr),
      }),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: double.infinity,
                decoration: decoration,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: radius,
                    onTap: enabled ? widget.onOpen : null,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _IconWithRing(
                                icon: widget.action.icon,
                                run: run,
                                color: scheme.primary,
                              ),
                              const Spacer(),
                              if (run.attention) const _AttentionBadge(),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            widget.action.title(context.tr),
                            style: text.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.action.description(context.tr),
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
          ),
        ),
      ),
    );
  }
}

/// The action icon, overlaid by a [CircularProgressIndicator] while its run is
/// in flight: determinate when the fraction is known, else indeterminate.
class _IconWithRing extends StatelessWidget {
  const _IconWithRing({
    required this.icon,
    required this.run,
    required this.color,
  });

  final IconData icon;
  final ActionRunState run;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (run.running)
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                // Determinate when the fraction is known, else a spinner.
                value: run.progress,
                strokeWidth: 2.5,
                color: color,
              ),
            ),
          Icon(icon, size: 24, color: color),
        ],
      ),
    );
  }
}

/// A gently pulsing dot shown when a finished run needs the user's attention,
/// looping its opacity + scale until the user opens the action (which clears it).
class _AttentionBadge extends StatefulWidget {
  const _AttentionBadge();

  @override
  State<_AttentionBadge> createState() => _AttentionBadgeState();
}

class _AttentionBadgeState extends State<_AttentionBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.4, end: 1).animate(_controller),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.8, end: 1.15).animate(_controller),
        child: Tooltip(
          message: context.tr('card_needs_review'),
          child: Container(
            width: 14,
            height: 14,
            decoration: const BoxDecoration(
              color: AppColors.warning,
              shape: BoxShape.circle,
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
    return Tooltip(
      message: context.tr('tt_readiness_chip'),
      child: Container(
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
                readiness.label(context.tr),
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
      ),
    );
  }
}
