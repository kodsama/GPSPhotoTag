import 'package:flutter/material.dart';

/// A single photo pin for the Explore map; shows a small count badge when the
/// point holds several photos. Kept as a standalone widget so it is testable
/// without rendering the full map.
class PhotoPin extends StatelessWidget {
  /// Creates a pin in [color], badged with [count] when greater than one.
  const PhotoPin({super.key, required this.count, required this.color});

  /// Number of photos at this point.
  final int count;

  /// The pin colour (theme primary).
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(Icons.location_on, color: color, size: 36),
        if (count > 1)
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1),
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              alignment: Alignment.center,
              child: Text(
                '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The round count badge drawn for a cluster of points on the Explore map.
class ClusterBadge extends StatelessWidget {
  /// Creates a badge showing [count] in [color].
  const ClusterBadge({super.key, required this.count, required this.color});

  /// Number of markers gathered into this cluster.
  final int count;

  /// The badge colour (theme primary).
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
