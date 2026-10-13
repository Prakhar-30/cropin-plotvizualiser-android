import 'package:flutter/material.dart';

/// Dark only. The app is used outdoors in daylight against a camera preview, and
/// a light chrome would wash the overlay out at exactly the moment it matters.
abstract final class PlotFinderColors {
  static const Color background = Color(0xFF0B0F14);
  static const Color surface = Color(0xFF121821);
  static const Color onSurface = Color(0xFFE5E7EB);
  static const Color onSurfaceVariant = Color(0xFF9CA3AF);
  static const Color primary = Color(0xFF4ADE80);
  static const Color onPrimary = Color(0xFF06210F);
  static const Color secondary = Color(0xFFF59E0B);
  static const Color error = Color(0xFFF87171);

  /// Translucent backing for text over the camera preview.
  static const Color scrim = Color(0xCC0B0F14);
  static const Color mutedText = Color(0xFFB6BEC9);
  static const Color faintText = Color(0xFF8A94A0);
  static const Color warning = Color(0xFFF59E0B);
}

ThemeData plotFinderTheme() {
  const scheme = ColorScheme.dark(
    primary: PlotFinderColors.primary,
    onPrimary: PlotFinderColors.onPrimary,
    secondary: PlotFinderColors.secondary,
    surface: PlotFinderColors.surface,
    onSurface: PlotFinderColors.onSurface,
    onSurfaceVariant: PlotFinderColors.onSurfaceVariant,
    error: PlotFinderColors.error,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: PlotFinderColors.background,
    useMaterial3: true,
  );
}

/// An opacity in 0..1 as the 0..255 alpha `Color.withAlpha` takes.
///
/// Used instead of `Color.withValues`, which only exists from Flutter 3.27, so
/// a host app on an older Flutter can still build this package.
int alpha8(double opacity) => (opacity.clamp(0.0, 1.0) * 255).round();
