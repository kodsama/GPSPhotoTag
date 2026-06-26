import 'dart:io';

import 'package:flutter/material.dart';

import '../state/controller_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/run_view.dart';

/// The Generate-map flow: a DPI option, a "Render heatmap" button, a live
/// progress affordance, and the produced PNG shown via [Image.file].
class MapAction extends StatefulWidget {
  /// Creates the map action body.
  const MapAction({super.key});

  @override
  State<MapAction> createState() => _MapActionState();
}

class _MapActionState extends State<MapAction> {
  int _dpi = 200;
  String? _output;

  @override
  Widget build(BuildContext context) {
    final controller = ControllerScope.of(context);
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controller.errorMessage != null) ...[
          ErrorBanner(message: controller.errorMessage!),
          const SizedBox(height: 14),
        ],
        Text('See where your photos were taken.', style: text.bodyMedium),
        const SizedBox(height: 16),
        Text('Resolution', style: text.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 100, label: Text('100 dpi')),
            ButtonSegment(value: 200, label: Text('200 dpi')),
            ButtonSegment(value: 300, label: Text('300 dpi')),
          ],
          selected: {_dpi},
          showSelectedIcon: false,
          onSelectionChanged: controller.running
              ? null
              : (s) => setState(() => _dpi = s.first),
        ),
        const SizedBox(height: 20),
        if (controller.running)
          RunProgress(
            done: controller.done,
            total: controller.total,
            fraction: controller.fraction,
            rows: controller.rows,
          )
        else
          FilledButton.icon(
            onPressed: () => _render(context),
            icon: const Icon(Icons.map),
            label: const Text('Render heatmap'),
          ),
        if (_output != null) ...[
          const SizedBox(height: 18),
          Text('Heatmap', style: text.titleMedium),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: Image.file(File(_output!), fit: BoxFit.contain),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: controller.backToLibrary,
            icon: const Icon(Icons.check),
            label: const Text('Done — back to library'),
          ),
        ],
      ],
    );
  }

  Future<void> _render(BuildContext context) async {
    final controller = ControllerScope.of(context);
    final path = await controller.renderMap(dpi: _dpi);
    if (mounted) setState(() => _output = path);
  }
}
