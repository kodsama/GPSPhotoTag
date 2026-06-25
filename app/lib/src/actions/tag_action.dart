import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

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
        ? 'Preview $count photos'
        : 'Tag $count '
              'photos';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        _Switch(
          label: 'Copy to a new folder',
          help: 'Off modifies originals in place; on writes tagged copies.',
          value: controller.copyToFolder,
          onChanged: controller.setCopyToFolder,
        ),
        if (controller.copyToFolder) _outDir(context),
        _Switch(
          label: 'Replace existing GPS',
          help: 'Overwrite coordinates already present in a photo.',
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
          label: 'Dry run',
          help: 'Locate and report only — write nothing.',
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
            label: Text(dir == null ? 'Choose destination folder' : 'Change'),
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
                'Pick a folder to continue.',
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
              'Embed needs ExifTool (missing) — Auto falls back to sidecars.',
              style: text.bodySmall,
            ),
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

  Widget _timezone(BuildContext context) {
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
          label: const Text('Done — back to library'),
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
