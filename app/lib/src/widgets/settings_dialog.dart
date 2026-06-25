/// The app-level Settings dialog: theme choice plus the persisted defaults the
/// Tag action starts from (RAW mode and max time-difference).
library;

import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../state/app_controller.dart';

/// Opens the Settings dialog for [controller].
void showSettingsDialog(BuildContext context, AppController controller) {
  showDialog<void>(
    context: context,
    builder: (_) => SettingsDialog(controller: controller),
  );
}

/// A small, tasteful settings surface bound to the [AppController].
class SettingsDialog extends StatelessWidget {
  /// Creates the settings dialog.
  const SettingsDialog({super.key, required this.controller});

  /// The controller whose preferences this dialog edits.
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 460,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Appearance', style: text.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                ],
                selected: {controller.themeMode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => controller.setThemeMode(s.first),
              ),
              const SizedBox(height: 20),
              Text('Tagging defaults', style: text.titleMedium),
              const SizedBox(height: 2),
              Text('New tag runs start from these.', style: text.bodySmall),
              const SizedBox(height: 10),
              Text('Default RAW write mode', style: text.bodyMedium),
              const SizedBox(height: 6),
              SegmentedButton<RawMode>(
                segments: [
                  const ButtonSegment(value: RawMode.auto, label: Text('Auto')),
                  const ButtonSegment(
                    value: RawMode.sidecar,
                    label: Text('Sidecar'),
                  ),
                  ButtonSegment(
                    value: RawMode.embed,
                    label: const Text('Embed'),
                    enabled: controller.exiftoolAvailable,
                  ),
                ],
                selected: {controller.defaultRawMode},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    controller.setDefaultRawMode(s.first),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Default max time difference (seconds)',
                      style: text.bodyMedium,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextFormField(
                      key: const Key('settings-max-time-diff'),
                      initialValue: '${controller.defaultMaxTimeDiffSeconds}',
                      keyboardType: TextInputType.number,
                      onChanged: (v) => controller.setDefaultMaxTimeDiff(
                        int.tryParse(v) ?? 300,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
