import 'package:flutter/material.dart';

import '../state/controller_scope.dart';
import '../state/wizard_step.dart';
import '../steps/input_step.dart';
import '../steps/options_step.dart';
import '../steps/output_step.dart';
import '../steps/result_step.dart';
import '../steps/review_step.dart';
import '../steps/run_step.dart';
import '../steps/toolkit_step.dart';
import 'step_card.dart';

/// The stepped collapsible walkthrough: one [StepCard] per [WizardStep], exactly
/// one expanded at a time, completed steps collapsed and tappable to revisit.
class Walkthrough extends StatelessWidget {
  /// Creates the walkthrough.
  const Walkthrough({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    return Column(
      children: [
        for (final step in WizardStep.values) ...[
          StepCard(
            step: step,
            active: controller.step == step,
            completed: controller.isCompleted(step),
            continueLabel: _continueLabel(step),
            canContinue: controller.isStepSatisfied(step),
            onContinue: controller.completeAndAdvance,
            onRevisit: () => controller.goTo(step),
            child: _bodyFor(step),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }

  static String _continueLabel(WizardStep step) => switch (step) {
        WizardStep.run => 'Skip',
        WizardStep.result => 'Done',
        _ => 'Continue',
      };

  Widget _bodyFor(WizardStep step) => switch (step) {
        WizardStep.toolkit => const ToolkitStep(),
        WizardStep.input => const InputStep(),
        WizardStep.review => const ReviewStep(),
        WizardStep.options => const OptionsStep(),
        WizardStep.output => const OutputStep(),
        WizardStep.run => const RunStep(),
        WizardStep.result => const ResultStep(),
      };
}
