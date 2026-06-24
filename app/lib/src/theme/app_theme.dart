import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Builds the light and dark [ThemeData] for GPSPhotoTag.
///
/// The look is intentionally non-default: warm paper surfaces, square-ish cards
/// with hairline contour borders, a terracotta primary, and a typographic scale
/// with tight, deliberate spacing. Numeric/coordinate styles use tabular figures
/// so latitudes and longitudes line up.
abstract final class AppTheme {
  /// Corner radius used across cards and controls.
  static const radius = 10.0;

  /// Tabular-figures feature for aligning coordinate columns.
  static const tabular = [FontFeature.tabularFigures()];

  /// The light ("paper") theme.
  static ThemeData get light => _build(
        brightness: Brightness.light,
        bg: AppColors.paper,
        surface: AppColors.paperRaised,
        sunk: AppColors.paperSunk,
        border: AppColors.sand,
        text: AppColors.ink,
        textSoft: AppColors.inkSoft,
        primary: AppColors.terracotta,
        secondary: AppColors.contour,
      );

  /// The dark ("dusk") theme.
  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        bg: AppColors.dusk,
        surface: AppColors.duskRaised,
        sunk: AppColors.duskSunk,
        border: AppColors.duskBorder,
        text: AppColors.parchment,
        textSoft: AppColors.parchmentSoft,
        primary: AppColors.terracottaBright,
        secondary: AppColors.contourBright,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color sunk,
    required Color border,
    required Color text,
    required Color textSoft,
    required Color primary,
    required Color secondary,
  }) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: brightness == Brightness.light ? Colors.white : AppColors.dusk,
      secondary: secondary,
      onSecondary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: sunk,
      outline: border,
      outlineVariant: border,
    );

    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final t = base.textTheme.apply(bodyColor: text, displayColor: text);

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      textTheme: t.copyWith(
        displaySmall: t.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          height: 1.05,
        ),
        headlineSmall: t.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: t.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
        labelLarge: t.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
        bodyMedium: t.bodyMedium?.copyWith(color: text, height: 1.4),
        bodySmall: t.bodySmall?.copyWith(color: textSoft, height: 1.4),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor:
              brightness == Brightness.light ? Colors.white : AppColors.dusk,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: textSoft, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sunk,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: text,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: bg, fontSize: 12),
      ),
    );
  }
}
