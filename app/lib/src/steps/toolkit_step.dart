import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/controller_scope.dart';
import '../theme/app_colors.dart';

/// Body of the toolkit step.
///
/// The app ships its own exiftool, so this step is mostly a confirmation: it
/// runs the bundled `exiftool -ver` once and reports that photo tools are ready.
/// When no bundle is present (e.g. a plain `dart run` during development) it
/// falls back to probing the host and showing whether exiftool was found.
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
      if (controller.hasBundledExiftool) {
        if (controller.bundledExiftoolVersion == null &&
            !controller.bundleVerifyFailed) {
          controller.verifyBundledExiftool();
        }
      } else if (controller.toolkit.isEmpty && !controller.toolkitLoading) {
        controller.runToolkitCheck();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    if (controller.hasBundledExiftool) {
      return _bundledView(context, controller);
    }
    if (controller.toolkitLoading && controller.toolkit.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return _unbundledView(context, controller);
  }

  Widget _bundledView(BuildContext context, AppController controller) {
    final text = Theme.of(context).textTheme;
    if (controller.bundleVerifyFailed) {
      return _banner(
        context,
        AppColors.warning,
        'Photo tools bundled, but ExifTool could not run on this machine. '
        'RAW-embed and HEIC need Perl installed; pure-Dart JPEG/PNG tagging '
        'still works. You can continue.',
      );
    }
    final version = controller.bundledExiftoolVersion;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle, color: AppColors.success, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            version == null
                ? 'Photo tools ready — exiftool bundled ✓'
                : 'Photo tools ready — exiftool bundled (v$version) ✓',
            style: text.titleMedium?.copyWith(color: AppColors.success),
          ),
        ),
      ],
    );
  }

  Widget _unbundledView(BuildContext context, AppController controller) {
    final exiftool = controller.toolkit.where((t) => t.id == 'exiftool');
    final present = exiftool.any((t) => t.present);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (present)
          _banner(
            context,
            AppColors.success,
            'ExifTool found on PATH — RAW embedding and HEIC are supported.',
          )
        else
          _banner(
            context,
            AppColors.warning,
            'Pure-Dart JPEG/PNG tagging works without any tools. ExifTool was '
            'not found on PATH, so RAW-embed and HEIC are unavailable — RAW '
            'will fall back to XMP sidecars. You can continue.',
          ),
      ],
    );
  }

  Widget _banner(BuildContext context, Color color, String message) {
    final text = Theme.of(context).textTheme;
    if (color == AppColors.success) {
      return Text(
        message,
        style: text.bodySmall?.copyWith(color: AppColors.success),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(message, style: text.bodySmall?.copyWith(color: color)),
    );
  }
}
