import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';

/// Body of the toolkit step: runs a probe on first build and lists each tool
/// with its presence, version, purpose, and an Install action when missing.
class ToolkitStep extends StatefulWidget {
  /// Creates the toolkit step body.
  const ToolkitStep({super.key});

  @override
  State<ToolkitStep> createState() => _ToolkitStepState();
}

class _ToolkitStepState extends State<ToolkitStep> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = ControllerScope.of(context);
      if (controller.toolkit.isEmpty && !controller.toolkitLoading) {
        controller.runToolkitCheck();
      }
    });
  }

  Future<void> _install(AppController controller, ToolStatus tool) async {
    final command = tool.installCommand;
    if (command == null) return;
    setState(() => _installing = tool.id);
    try {
      final parts = command.split(' ');
      await Process.run(parts.first, parts.sublist(1));
    } on Object {
      // Surface failure only through the re-check below.
    }
    await controller.runToolkitCheck();
    if (mounted) setState(() => _installing = null);
  }

  String? _installing;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    if (controller.toolkitLoading && controller.toolkit.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final tool in controller.toolkit)
          _ToolRow(
            tool: tool,
            installing: _installing == tool.id,
            onInstall: tool.installCommand != null && !tool.present
                ? () => _install(controller, tool)
                : null,
          ),
        const SizedBox(height: 12),
        _capabilityBanner(context, controller),
      ],
    );
  }

  Widget _capabilityBanner(BuildContext context, AppController controller) {
    final text = Theme.of(context).textTheme;
    if (controller.exiftoolAvailable) {
      return Text(
        'All capabilities available — RAW embedding and HEIC are supported.',
        style: text.bodySmall?.copyWith(color: AppColors.success),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Text(
        'Pure-Dart JPEG/PNG tagging works without any tools. ExifTool is '
        'missing, so RAW-embed and HEIC are unavailable — RAW will fall back '
        'to XMP sidecars. You can continue.',
        style: text.bodySmall?.copyWith(color: AppColors.warning),
      ),
    );
  }
}

/// One tool's status line with optional Install button.
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.tool,
    required this.installing,
    required this.onInstall,
  });

  final ToolStatus tool;
  final bool installing;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = tool.present ? AppColors.success : AppColors.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(tool.present ? Icons.check_circle : Icons.cancel,
              color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(tool.name, style: text.titleMedium),
                    if (tool.version != null) ...[
                      const SizedBox(width: 8),
                      Text('v${tool.version}', style: text.bodySmall),
                    ],
                    if (!tool.required) ...[
                      const SizedBox(width: 8),
                      Text('optional',
                          style: text.bodySmall
                              ?.copyWith(fontStyle: FontStyle.italic)),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(tool.purpose, style: text.bodySmall),
              ],
            ),
          ),
          if (onInstall != null) ...[
            const SizedBox(width: 12),
            installing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : OutlinedButton(
                    onPressed: onInstall,
                    child: const Text('Install'),
                  ),
          ],
        ],
      ),
    );
  }
}
