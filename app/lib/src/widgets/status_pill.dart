import 'package:flutter/material.dart';
import 'package:gpsphototag_engine/gpsphototag_engine.dart';

import '../theme/app_colors.dart';

/// A small rounded chip showing a [PhotoStatus] in an outcome-appropriate colour.
class StatusPill extends StatelessWidget {
  /// Creates a pill for [status].
  const StatusPill(this.status, {super.key});

  /// The outcome to display.
  final PhotoStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        status.wire.replaceAll('_', ' '),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  static Color _colorFor(PhotoStatus status) => switch (status) {
    PhotoStatus.tagged ||
    PhotoStatus.interpolated ||
    PhotoStatus.datesFixed ||
    PhotoStatus.prunedTrashed => AppColors.success,
    PhotoStatus.alreadyTagged || PhotoStatus.dryRun => AppColors.contour,
    PhotoStatus.noGps || PhotoStatus.noTimestamp => AppColors.warning,
    PhotoStatus.prunedDeleted => AppColors.terracottaDark,
    PhotoStatus.error => AppColors.danger,
  };
}
