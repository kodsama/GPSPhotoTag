import 'package:flutter/material.dart';

/// The GPSPhotoTag palette — a warm "field-notebook / topographic map" identity:
/// aged paper, ink, a terracotta route line, and a teal contour accent. Chosen
/// to feel like a cartographer's notebook rather than a default Material app.
abstract final class AppColors {
  // Light ("paper") -------------------------------------------------------
  /// Aged-paper window background.
  static const paper = Color(0xFFF3EDE1);

  /// Raised card / surface on paper.
  static const paperRaised = Color(0xFFFBF7EF);

  /// A slightly sunk panel (e.g. log, code).
  static const paperSunk = Color(0xFFEAE2D2);

  /// Hairline borders / contour lines.
  static const sand = Color(0xFFDDD2BD);

  /// Primary ink for text.
  static const ink = Color(0xFF23201A);

  /// Secondary ink for captions/help.
  static const inkSoft = Color(0xFF6B6358);

  // Accents ---------------------------------------------------------------
  /// Primary accent — the "route line".
  static const terracotta = Color(0xFFC25A3A);

  /// Pressed/darker terracotta.
  static const terracottaDark = Color(0xFFA4472B);

  /// Secondary accent — topographic contour teal.
  static const contour = Color(0xFF2E6F6A);

  // Status ----------------------------------------------------------------
  /// Success / present.
  static const success = Color(0xFF4C7A3F);

  /// Warning / attention.
  static const warning = Color(0xFFB7851F);

  /// Error / missing.
  static const danger = Color(0xFFB23A2E);

  // Dark ("dusk") ---------------------------------------------------------
  /// Dark-mode window background.
  static const dusk = Color(0xFF1A1816);

  /// Dark-mode raised surface.
  static const duskRaised = Color(0xFF24211D);

  /// Dark-mode sunk panel.
  static const duskSunk = Color(0xFF151311);

  /// Dark-mode hairline.
  static const duskBorder = Color(0xFF38332C);

  /// Dark-mode primary text.
  static const parchment = Color(0xFFEDE6D8);

  /// Dark-mode secondary text.
  static const parchmentSoft = Color(0xFFA89E8C);

  /// Brightened terracotta for dark surfaces.
  static const terracottaBright = Color(0xFFE0795A);

  /// Brightened contour for dark surfaces.
  static const contourBright = Color(0xFF5BA89F);
}
