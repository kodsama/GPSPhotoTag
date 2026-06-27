import 'package:flutter/material.dart';
import 'package:stunda_engine/stunda_engine.dart';

import '../data/iana_timezones.dart';
import '../i18n/app_localizations.dart';
import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';
import '../widgets/run_view.dart';

/// The Tag-with-GPS flow: every [TagOptions] field, a primary button that names
/// the commitment ("Tag N photos" / "Preview N photos" for dry-run), live
/// progress with per-item rows, an error surface, the result summary, and a
/// "Done — back to library" affordance.
class TagAction extends StatelessWidget {
  /// Creates the tag action body.
  const TagAction({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);

    if (controller.lastSummary != null && !controller.running) {
      return _Done(controller: controller);
    }
    if (controller.running) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (controller.errorMessage != null) ...[
            ErrorBanner(message: controller.errorMessage!),
            const SizedBox(height: 14),
          ],
          RunProgress(
            done: controller.done,
            total: controller.total,
            fraction: controller.fraction,
            rows: controller.rows,
          ),
        ],
      );
    }
    return _Options(controller: controller);
  }
}

/// The pre-run options form plus the primary commit button.
class _Options extends StatelessWidget {
  const _Options({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.photoCount;
    final label = controller.dryRun
        ? context.tr('tag_preview_photos', {'count': count})
        : context.tr('tag_tag_photos', {'count': count});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        _Switch(
          label: context.tr('tag_copy_label'),
          help: context.tr('tag_copy_help'),
          value: controller.copyToFolder,
          onChanged: controller.setCopyToFolder,
        ),
        if (controller.copyToFolder) _outDir(context),
        _Switch(
          label: context.tr('tag_replace_label'),
          help: context.tr('tag_replace_help'),
          value: controller.replace,
          onChanged: controller.setReplace,
        ),
        const SizedBox(height: 8),
        _rawMode(context),
        const SizedBox(height: 16),
        _maxTimeDiff(context),
        const SizedBox(height: 16),
        _timezone(context),
        const SizedBox(height: 8),
        _Switch(
          label: context.tr('tag_dry_run'),
          help: context.tr('tag_dry_run_help'),
          value: controller.dryRun,
          onChanged: controller.setDryRun,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: (count > 0 && controller.outputValid)
              ? controller.runTag
              : null,
          icon: const Icon(Icons.play_arrow),
          label: Text(label),
        ),
      ],
    );
  }

  Widget _outDir(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final dir = controller.outDir;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: controller.pickOutDir,
            icon: const Icon(Icons.folder_open),
            label: Text(
              dir == null
                  ? context.tr('tag_choose_destination')
                  : context.tr('tag_change'),
            ),
          ),
          if (dir != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(dir, style: text.bodyMedium)),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr('tag_pick_folder'),
                style: text.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rawMode(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final embedDisabled = !controller.exiftoolAvailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('tag_raw_mode'), style: text.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<RawMode>(
          segments: [
            ButtonSegment(
              value: RawMode.auto,
              label: Text(context.tr('tag_raw_auto')),
            ),
            ButtonSegment(
              value: RawMode.sidecar,
              label: Text(context.tr('tag_raw_sidecar')),
            ),
            ButtonSegment(
              value: RawMode.embed,
              label: Text(context.tr('tag_raw_embed')),
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
            child: Text(context.tr('tag_embed_help'), style: text.bodySmall),
          ),
      ],
    );
  }

  Widget _maxTimeDiff(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.tr('tag_max_diff'), style: text.titleMedium),
              const SizedBox(height: 2),
              Text(context.tr('tag_max_diff_help'), style: text.bodySmall),
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

  Widget _timezone(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('tag_timezone_optional'), style: text.titleMedium),
        const SizedBox(height: 2),
        Text(context.tr('tag_timezone_help'), style: text.bodySmall),
        const SizedBox(height: 8),
        DropdownMenu<String>(
          // The auto-detect sentinel maps to a null timezone (use EXIF offset).
          initialSelection: controller.timezone ?? _autoDetect,
          enableFilter: true,
          requestFocusOnTap: true,
          expandedInsets: EdgeInsets.zero,
          label: Text(context.tr('tag_timezone')),
          onSelected: (value) => controller.setTimezone(
            value == null || value == _autoDetect ? null : value,
          ),
          dropdownMenuEntries: [
            DropdownMenuEntry(
              value: _autoDetect,
              label: context.tr('tag_auto_detect'),
            ),
            for (final zone in kIanaTimezones)
              DropdownMenuEntry(value: zone, label: zone),
          ],
        ),
      ],
    );
  }
}

/// The sentinel "auto-detect" entry that maps to a null timezone.
const _autoDetect = 'Auto-detect';

/// The post-run result: summary table + back-to-library button.
class _Done extends StatelessWidget {
  const _Done({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ResultSummaryTable(summary: controller.lastSummary!),
        if (controller.rows.isNotEmpty) ...[
          const SizedBox(height: 16),
          RunProgress(
            done: controller.done,
            total: controller.total,
            fraction: controller.fraction,
            rows: controller.rows,
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: controller.backToLibrary,
          icon: const Icon(Icons.check),
          label: Text(context.tr('done_back_to_library')),
        ),
      ],
    );
  }
}

/// A labelled switch row with helper text.
class _Switch extends StatelessWidget {
  const _Switch({
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
