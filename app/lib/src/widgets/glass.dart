/// Reusable frosted-glass surface used across the shell (header, action cards,
/// content panels). A [BackdropFilter] blurs whatever sits behind it (the
/// app-wide background + veil), over a semi-transparent surface fill with a
/// hairline border and a soft shadow — legible in both light and dark themes.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// Computes the readability veil colour for the given [brightness]: white in
/// light mode, black in dark mode, at [opacity] (clamped to 0.0–1.0).
///
/// Pure and unit-tested: the veil is what keeps frosted content legible over an
/// arbitrary background image.
Color veilColor(Brightness brightness, double opacity) {
  final base = brightness == Brightness.light ? Colors.white : Colors.black;
  return base.withValues(alpha: opacity.clamp(0.0, 1.0));
}

/// A frosted-glass container: rounded, blurred backdrop, translucent surface
/// fill, hairline border, and a subtle shadow. Place over the background layer.
class GlassSurface extends StatelessWidget {
  /// Creates a frosted surface wrapping [child].
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.padding,
    this.sigma = 16,
    this.opacity = 0.62,
  });

  /// The content rendered on top of the frosted fill.
  final Widget child;

  /// Corner rounding for the clip, border, and fill.
  final BorderRadius borderRadius;

  /// Optional inner padding around [child].
  final EdgeInsetsGeometry? padding;

  /// Gaussian blur radius applied to the backdrop.
  final double sigma;

  /// Alpha of the translucent surface fill (0.0–1.0).
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: glassDecoration(scheme, borderRadius, opacity),
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }
}

/// The translucent fill + hairline border + soft shadow used by [GlassSurface]
/// and by Material card surfaces that want the same frosted look.
BoxDecoration glassDecoration(
  ColorScheme scheme,
  BorderRadius borderRadius, [
  double opacity = 0.62,
]) {
  return BoxDecoration(
    color: scheme.surface.withValues(alpha: opacity),
    borderRadius: borderRadius,
    border: Border.all(color: scheme.outline.withValues(alpha: 0.6)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.10),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ],
  );
}
