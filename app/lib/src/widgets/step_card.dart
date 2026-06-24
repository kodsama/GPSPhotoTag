import 'package:flutter/material.dart';

import '../state/wizard_step.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A single walkthrough card.
///
/// When [active] it shows [child] plus a Continue action; when [completed] it
/// collapses to a tappable one-line summary with a check; otherwise it is a
/// dimmed, non-interactive header (a future step).
class StepCard extends StatelessWidget {
  /// Builds a card for [step].
  const StepCard({
    super.key,
    required this.step,
    required this.active,
    required this.completed,
    required this.child,
    required this.continueLabel,
    required this.canContinue,
    required this.onContinue,
    required this.onRevisit,
  });

  /// Which step this card represents.
  final WizardStep step;

  /// Whether this is the currently expanded step.
  final bool active;

  /// Whether this step has already been finished.
  final bool completed;

  /// The expanded body (shown only when [active]).
  final Widget child;

  /// Label for the primary action button.
  final String continueLabel;

  /// Whether the Continue action is enabled.
  final bool canContinue;

  /// Invoked when Continue is pressed.
  final VoidCallback onContinue;

  /// Invoked when a completed/earlier card is tapped to revisit it.
  final VoidCallback onRevisit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          onTap: active ? null : (completed ? onRevisit : null),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context, scheme),
                if (active) ...[
                  const SizedBox(height: 16),
                  child,
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: canContinue ? onContinue : null,
                      child: Text(continueLabel),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ColorScheme scheme) {
    final text = Theme.of(context).textTheme;
    final dim = !active && !completed;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _badge(scheme),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.title,
                style: text.titleMedium?.copyWith(
                  color: dim ? scheme.onSurface.withValues(alpha: 0.5) : null,
                ),
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(step.subtitle, style: text.bodySmall),
                ),
            ],
          ),
        ),
        if (completed && !active)
          Text('Edit',
              style: text.labelLarge?.copyWith(color: scheme.primary)),
      ],
    );
  }

  Widget _badge(ColorScheme scheme) {
    final done = completed && !active;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: done
            ? AppColors.success.withValues(alpha: 0.16)
            : active
                ? scheme.primary
                : scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
        border: Border.all(
          color: done ? AppColors.success : scheme.outline,
        ),
      ),
      alignment: Alignment.center,
      child: done
          ? const Icon(Icons.check, size: 17, color: AppColors.success)
          : Text(
              '${step.number}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: active ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
    );
  }
}
