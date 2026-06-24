import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';

/// Body of the options step: every [TagOptions] field with smart defaults.
class OptionsStep extends StatelessWidget {
  /// Creates the options step body.
  const OptionsStep({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _OptionSwitch(
          label: 'Copy to a new folder',
          help: 'Off modifies originals in place; on writes tagged copies.',
          value: controller.copyToFolder,
          onChanged: controller.setCopyToFolder,
        ),
        _OptionSwitch(
          label: 'Replace existing GPS',
          help: 'Overwrite coordinates already present in a photo.',
          value: controller.replace,
          onChanged: controller.setReplace,
        ),
        const SizedBox(height: 8),
        _rawMode(context, controller),
        const SizedBox(height: 16),
        _maxTimeDiff(context, controller),
        const SizedBox(height: 16),
        _timezone(context, controller),
        const SizedBox(height: 8),
        _OptionSwitch(
          label: 'Dry run',
          help: 'Locate and report only — write nothing.',
          value: controller.dryRun,
          onChanged: controller.setDryRun,
        ),
      ],
    );
  }

  Widget _rawMode(BuildContext context, AppController controller) {
    final text = Theme.of(context).textTheme;
    final embedDisabled = !controller.exiftoolAvailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('RAW write mode', style: text.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<RawMode>(
          segments: [
            const ButtonSegment(value: RawMode.auto, label: Text('Auto')),
            const ButtonSegment(value: RawMode.sidecar, label: Text('Sidecar')),
            ButtonSegment(
              value: RawMode.embed,
              label: const Text('Embed'),
              enabled: !embedDisabled,
            ),
          ],
          selected: {controller.rawMode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => controller.setRawMode(s.first),
        ),
        if (embedDisabled)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Embed needs ExifTool (missing) — Auto falls back to '
              'sidecars.',
              style: text.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _maxTimeDiff(BuildContext context, AppController controller) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Max time difference (seconds)', style: text.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Largest gap between a photo and a GPS point.',
                style: text.bodySmall,
              ),
            ],
          ),
        ),
        SizedBox(
          width: 110,
          child: TextFormField(
            initialValue: '${controller.maxTimeDiffSeconds}',
            keyboardType: TextInputType.number,
            onChanged: (v) => controller.setMaxTimeDiff(int.tryParse(v) ?? 300),
          ),
        ),
      ],
    );
  }

  Widget _timezone(BuildContext context, AppController controller) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Timezone (optional)', style: text.titleMedium),
        const SizedBox(height: 2),
        Text(
          'IANA name used when EXIF has no offset, e.g. Europe/Paris.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: controller.timezone ?? '',
          decoration: const InputDecoration(hintText: 'Europe/Paris'),
          onChanged: controller.setTimezone,
        ),
      ],
    );
  }
}

/// A labelled switch row with helper text.
class _OptionSwitch extends StatelessWidget {
  const _OptionSwitch({
    required this.label,
    required this.help,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String help;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(help, style: text.bodySmall),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
