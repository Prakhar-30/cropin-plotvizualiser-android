import 'package:flutter/material.dart';

/// The Cropin Grow look for the planning screens: plot list, plot detail and
/// the permission gate. Read indoors or in shade before setting off, where a
/// light, card-based layout is the house style.
///
/// Token values are documented in `docs/design/plot-finder/MILESTONES.md`.
abstract final class GrowColors {
  static const Color primary = Color(0xFF234556);
  static const Color primaryDark = Color(0xFF1A3542);
  static const Color primaryTint = Color(0xFFE3ECF0);
  static const Color onPrimaryMuted = Color(0xFFC3D2DA);
  static const Color ground = Color(0xFFF2F4F5);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color outline = Color(0xFFDDE3E6);
  static const Color divider = Color(0xFFE6EBED);
  static const Color text = Color(0xFF1A2228);
  static const Color mutedText = Color(0xFF56636C);
  static const Color success = Color(0xFF2F7D45);
  static const Color successText = Color(0xFF1F5A31);
  static const Color successTint = Color(0xFFE8F2EB);
  static const Color warning = Color(0xFFA15C07);
  static const Color warningTint = Color(0xFFFDF1DE);
  static const Color danger = Color(0xFFC62828);

  /// The sketch keeps the dark plate it had: the cyan boundary and amber
  /// access point were chosen against dark, and read the same in the AR view.
  static const Color sketchPlate = Color(0xFF1A3542);
}

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
  static const Color scrim = Color(0xDB0F1A20);
  static const Color mutedText = Color(0xFFB6BEC9);
  static const Color faintText = Color(0xFF8A94A0);
  static const Color warning = Color(0xFFF59E0B);

  /// The AR screen's bottom sheet and its raised controls.
  static const Color sheet = Color(0xFF0F1A20);
  static const Color sheetRaised = Color(0xFF1E2B32);
  static const Color sheetDivider = Color(0xFF23323A);
}

/// Light Cropin Grow theme for everything outside the AR view.
ThemeData growTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: GrowColors.primary,
    primary: GrowColors.primary,
    onPrimary: Colors.white,
    surface: GrowColors.surface,
    onSurface: GrowColors.text,
    onSurfaceVariant: GrowColors.mutedText,
    outline: GrowColors.outline,
    error: GrowColors.danger,
  );
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  const buttonText = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: GrowColors.ground,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: GrowColors.primary,
      foregroundColor: Colors.white,
      elevation: 0,
      titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: GrowColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 48),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: GrowColors.primary,
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: GrowColors.primary, width: 1.5),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: GrowColors.primary, minimumSize: const Size(0, 48)),
    ),
    dividerTheme: const DividerThemeData(color: GrowColors.divider, thickness: 1, space: 1),
  );
}

/// The dark theme the AR view runs under.
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
    appBarTheme: const AppBarTheme(
      backgroundColor: GrowColors.primary,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
  );
}

/// White-on-dark primary action used over the camera, like the Grow scanner's
/// light pill buttons.
ButtonStyle cameraPrimaryButtonStyle() => FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: GrowColors.primaryDark,
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
    );

/// An opacity in 0..1 as the 0..255 alpha `Color.withAlpha` takes.
///
/// Used instead of `Color.withValues`, which only exists from Flutter 3.27, so
/// a host app on an older Flutter can still build this package.
int alpha8(double opacity) => (opacity.clamp(0.0, 1.0) * 255).round();
