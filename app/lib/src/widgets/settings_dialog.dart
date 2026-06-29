/// The app-level Settings dialog: theme choice, the persisted defaults the Tag
/// action starts from (RAW mode and max time-difference), the customizable
/// background, and the live MCP server status.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stunda_engine/stunda_engine.dart';

import '../engine/mcp_service.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/library_action.dart' show Translator;
import '../theme/app_colors.dart';
import 'help.dart';

/// Opens the Settings dialog for [controller].
void showSettingsDialog(BuildContext context, AppController controller) {
  showDialog<void>(
    context: context,
    builder: (_) => SettingsDialog(controller: controller),
  );
}

/// A colour + label + tooltip describing an MCP server state, derived purely
/// from primitive state so all three branches can be unit-tested and the row
/// can reuse it. [running] wins; otherwise [error] (off) then starting. Strings
/// resolve via [tr] (the widget passes `context.tr`).
({Color color, String label, String tip}) mcpStatus(
  Translator tr, {
  required bool running,
  int? port,
  String? error,
}) {
  if (running) {
    return (
      color: AppColors.success,
      label: tr('settings_mcp_running', {'port': port}),
      tip: tr('settings_mcp_running_tip', {'port': port}),
    );
  }
  if (error != null) {
    return (
      color: AppColors.danger,
      label: tr('settings_mcp_off'),
      tip: tr('settings_mcp_failed_tip', {'error': error}),
    );
  }
  return (
    color: AppColors.warning,
    label: tr('settings_mcp_starting'),
    tip: tr('settings_mcp_starting_tip'),
  );
}

/// A small, tasteful settings surface bound to the [AppController].
class SettingsDialog extends StatelessWidget {
  /// Creates the settings dialog.
  const SettingsDialog({super.key, required this.controller});

  /// The controller whose preferences this dialog edits.
  final AppController controller;

  Future<void> _pickImage(String imagesLabel) async {
    final group = XTypeGroup(
      label: imagesLabel,
      extensions: const ['png', 'jpg', 'jpeg', 'webp', 'heic'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file != null) controller.setBackgroundImagePath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(context.tr('settings_title')),
      content: SizedBox(
        // Cap at 460 on desktop but shrink to fit narrow phone screens (the
        // dialog's own insets take ~80px) so the content never overflows.
        width: (MediaQuery.of(context).size.width - 80).clamp(0.0, 460.0),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => HelpTarget(
            topic: HelpTopic.settings,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('settings_appearance'),
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Tooltip(
                    message: context.tr('tt_settings_theme'),
                    child: SegmentedButton<ThemeMode>(
                      segments: [
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text(context.tr('settings_light')),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text(context.tr('settings_dark')),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text(context.tr('settings_auto')),
                        ),
                      ],
                      selected: {controller.themeMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          controller.setThemeMode(s.first),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _LanguageSection(controller: controller),
                  const SizedBox(height: 20),
                  _BackgroundSection(
                    controller: controller,
                    onPick: () =>
                        _pickImage(context.tr('settings_images_picker')),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    context.tr('settings_tagging_defaults'),
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.tr('settings_tagging_defaults_desc'),
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.tr('settings_default_raw'),
                    style: text.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<RawMode>(
                    segments: [
                      ButtonSegment(
                        value: RawMode.auto,
                        label: Text(context.tr('settings_raw_auto')),
                      ),
                      ButtonSegment(
                        value: RawMode.sidecar,
                        label: Text(context.tr('settings_raw_sidecar')),
                      ),
                      ButtonSegment(
                        value: RawMode.embed,
                        label: Text(context.tr('settings_raw_embed')),
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
                          context.tr('settings_default_max_diff'),
                          style: text.bodyMedium,
                        ),
                      ),
                      SizedBox(
                        width: 110,
                        child: TextFormField(
                          key: const Key('settings-max-time-diff'),
                          initialValue:
                              '${controller.defaultMaxTimeDiffSeconds}',
                          keyboardType: TextInputType.number,
                          onChanged: (v) => controller.setDefaultMaxTimeDiff(
                            int.tryParse(v) ?? 300,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _HomeActionsSection(controller: controller),
                  const SizedBox(height: 20),
                  _McpStatusRow(mcp: controller.mcp),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('settings_done')),
        ),
      ],
    );
  }
}

/// The "Language" section: a dropdown of "System default" + the 9 supported
/// languages (each shown in its own name). Selecting persists the override and
/// rebuilds the app with the new locale live.
class _LanguageSection extends StatelessWidget {
  const _LanguageSection({required this.controller});

  final AppController controller;

  /// The dropdown entries: a null-valued "System default" then one per locale,
  /// each labelled in its own language (Français, 中文, …).
  static const _entries = <(String?, String)>[
    (null, 'lang_system'),
    ('en', 'lang_en'),
    ('fr', 'lang_fr'),
    ('sv', 'lang_sv'),
    ('zh', 'lang_zh'),
    ('ja', 'lang_ja'),
    ('de', 'lang_de'),
    ('pt', 'lang_pt'),
    ('es', 'lang_es'),
    ('da', 'lang_da'),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('settings_language'), style: text.titleMedium),
        const SizedBox(height: 8),
        Tooltip(
          message: context.tr('tt_settings_language'),
          child: DropdownButton<String?>(
            key: const Key('settings-language'),
            value: controller.localeCode,
            isExpanded: true,
            onChanged: controller.setLocaleCode,
            items: [
              for (final (code, key) in _entries)
                DropdownMenuItem<String?>(
                  value: code,
                  child: Text(context.tr(key)),
                ),
            ],
          ),
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
    final name = path == null
        ? context.tr('settings_default_map_style')
        : p.basename(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('settings_background'), style: text.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: context.tr('tt_settings_choose_image'),
              child: OutlinedButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(context.tr('settings_choose_image')),
              ),
            ),
            if (path != null)
              Tooltip(
                message: context.tr('tt_settings_reset_background'),
                child: TextButton(
                  onPressed: () => controller.setBackgroundImagePath(null),
                  child: Text(context.tr('settings_reset_default')),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(name, style: text.bodySmall, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 12),
        Text(
          context.tr('settings_background_intensity'),
          style: text.bodyMedium,
        ),
        Text(
          context.tr('settings_background_intensity_help'),
          style: text.bodySmall,
        ),
        Tooltip(
          message: context.tr('tt_settings_intensity'),
          child: Slider(
            value: controller.backgroundVeil,
            label: context.tr('settings_intensity_value', {
              'percent': (controller.backgroundVeil * 100).round(),
            }),
            divisions: 20,
            onChanged: controller.setBackgroundVeil,
          ),
        ),
      ],
    );
  }
}

/// The "Home actions" section: a reorderable list of every action card with a
/// show/hide [Switch] each. Dragging the handle reorders; toggling shows/hides.
/// Both persist and notify, so the workspace grid reflects changes live. Mirrors
/// the duplicate-finder keep-pipeline panel's style.
class _HomeActionsSection extends StatelessWidget {
  const _HomeActionsSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final order = controller.homeActions.order;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('settings_home_actions'), style: text.titleMedium),
        const SizedBox(height: 2),
        Text(context.tr('settings_home_actions_desc'), style: text.bodySmall),
        const SizedBox(height: 8),
        // The list is short (one row per action) so it sizes to its content
        // inside the surrounding scroll view.
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: controller.reorderHomeAction,
          children: [
            for (var i = 0; i < order.length; i++)
              Container(
                key: ValueKey(order[i]),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outline),
                ),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: Tooltip(
                        message: context.tr('tt_settings_home_drag'),
                        child: const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Icon(Icons.drag_handle, size: 20),
                        ),
                      ),
                    ),
                    Icon(order[i].icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(context.tr(order[i].titleKey))),
                    Tooltip(
                      message: context.tr('tt_settings_home_toggle'),
                      child: Switch(
                        value: controller.homeActions.isVisible(order[i]),
                        onChanged: (v) =>
                            controller.setHomeActionVisible(order[i], v),
                      ),
                    ),
                  ],
                ),
              ),
          ],
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
          context.tr,
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
              Text(context.tr('settings_mcp_server'), style: text.bodyMedium),
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
