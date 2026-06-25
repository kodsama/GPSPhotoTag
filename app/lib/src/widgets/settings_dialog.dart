/// The app-level Settings dialog: theme choice, the persisted defaults the Tag
/// action starts from (RAW mode and max time-difference), the customizable
/// background, and the live MCP server status.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

import '../engine/mcp_service.dart';
import '../state/app_controller.dart';
import '../theme/app_colors.dart';

/// Opens the Settings dialog for [controller].
void showSettingsDialog(BuildContext context, AppController controller) {
  showDialog<void>(
    context: context,
    builder: (_) => SettingsDialog(controller: controller),
  );
}

/// A colour + label + tooltip describing an MCP server state, derived purely
/// from primitive state so all three branches can be unit-tested and the row
/// can reuse it. [running] wins; otherwise [error] (off) then starting.
({Color color, String label, String tip}) mcpStatus({
  required bool running,
  int? port,
  String? error,
}) {
  if (running) {
    return (
      color: AppColors.success,
      label: 'running on :$port',
      tip: 'LLM endpoint live on 127.0.0.1:$port (MCP over TCP)',
    );
  }
  if (error != null) {
    return (
      color: AppColors.danger,
      label: 'off',
      tip: 'MCP server failed to start: $error',
    );
  }
  return (
    color: AppColors.warning,
    label: 'starting…',
    tip: 'Starting MCP server…',
  );
}

/// A small, tasteful settings surface bound to the [AppController].
class SettingsDialog extends StatelessWidget {
  /// Creates the settings dialog.
  const SettingsDialog({super.key, required this.controller});

  /// The controller whose preferences this dialog edits.
  final AppController controller;

  Future<void> _pickImage() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'heic'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file != null) controller.setBackgroundImagePath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 460,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => SingleChildScrollView(
            child: Column(
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
                _BackgroundSection(controller: controller, onPick: _pickImage),
                const SizedBox(height: 20),
                Text('Tagging defaults', style: text.titleMedium),
                const SizedBox(height: 2),
                Text('New tag runs start from these.', style: text.bodySmall),
                const SizedBox(height: 10),
                Text('Default RAW write mode', style: text.bodyMedium),
                const SizedBox(height: 6),
                SegmentedButton<RawMode>(
                  segments: [
                    const ButtonSegment(
                      value: RawMode.auto,
                      label: Text('Auto'),
                    ),
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
                const SizedBox(height: 20),
                _McpStatusRow(mcp: controller.mcp),
              ],
            ),
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

/// The "Background" section: image picker + reset, and the intensity slider.
class _BackgroundSection extends StatelessWidget {
  const _BackgroundSection({required this.controller, required this.onPick});

  final AppController controller;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final path = controller.backgroundImagePath;
    final name = path == null ? 'Default map style' : p.basename(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Background', style: text.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('Choose image…'),
            ),
            if (path != null)
              TextButton(
                onPressed: () => controller.setBackgroundImagePath(null),
                child: const Text('Reset to default'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(name, style: text.bodySmall, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 12),
        Text('Background intensity', style: text.bodyMedium),
        Text(
          'Higher is more subtle (more veil over the background).',
          style: text.bodySmall,
        ),
        Slider(
          value: controller.backgroundVeil,
          label: '${(controller.backgroundVeil * 100).round()}%',
          divisions: 20,
          onChanged: controller.setBackgroundVeil,
        ),
      ],
    );
  }
}

/// The live MCP server status: a coloured dot + label, kept current via the
/// service's [ListenableBuilder].
class _McpStatusRow extends StatelessWidget {
  const _McpStatusRow({required this.mcp});

  final McpService mcp;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: mcp,
      builder: (context, _) {
        final status = mcpStatus(
          running: mcp.running,
          port: mcp.port,
          error: mcp.error,
        );
        return Tooltip(
          message: status.tip,
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: status.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text('MCP server', style: text.bodyMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.label,
                  style: text.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
