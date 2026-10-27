// Mirrors palette.json, which is shared with the web tool. Keep the two in
// step: a plot's colour slot is assigned server-side and must mean the same
// hue on the map and in the camera.

/// One palette slot. [index] is the value stored in `plots.colour_index`.
///
/// [argb] is packed 0xAARRGGBB, which is exactly what Flutter's `Color(int)`
/// takes.
class PlotColour {
  const PlotColour(this.index, this.name, this.argb);

  final int index;
  final String name;
  final int argb;
}

/// Boundary colours, shared with the web tool through palette.json.
///
/// Stored as 0xAARRGGBB with full alpha; the renderer applies [PlotAlpha] to the
/// surface it is drawing rather than baking transparency in here.
const List<PlotColour> plotColours = [
  PlotColour(0, 'red', 0xFFFF3B30),
  PlotColour(1, 'orange', 0xFFFF9F0A),
  PlotColour(2, 'yellow', 0xFFFFD60A),
  PlotColour(3, 'cyan', 0xFF64D2FF),
  PlotColour(4, 'blue', 0xFF0A84FF),
  PlotColour(5, 'purple', 0xFFBF5AF2),
  PlotColour(6, 'pink', 0xFFFF375F),
  PlotColour(7, 'white', 0xFFF2F2F7),
];

/// Opacity each surface is drawn at, shared with the web tool.
abstract final class PlotAlpha {
  static const double wallFill = 0.28;
  static const double groundFill = 0.18;
  static const double rail = 1.0;
  static const double outline = 0.95;
}

/// One crop-health severity band.
class SeverityColour {
  const SeverityColour(this.level, this.name, this.label, this.argb, this.fillAlpha);

  final int level;
  final String name;
  final String label;
  final int argb;

  /// Fill opacity for this band. Rises with severity; see palette.json.
  final double fillAlpha;
}

/// The crop-health ramp, shared with the web map through palette.json.
///
/// Healthy through mild and stressed to critical. Kept apart from
/// [plotColours] on purpose: that palette identifies a plot, this one grades a
/// condition, and swapping them would make a red-slot plot look like a dead one.
const List<SeverityColour> severityColours = [
  SeverityColour(0, 'healthy', 'Healthy', 0xFF2FD44E, 0.22),
  SeverityColour(1, 'mild', 'Mild', 0xFFFFE81A, 0.55),
  SeverityColour(2, 'stressed', 'Stressed', 0xFFFF8A00, 0.68),
  SeverityColour(3, 'critical', 'Critical', 0xFFFF2118, 0.8),
];

/// The band for a severity level, clamped rather than wrapped.
///
/// Wrapping would turn a corrupt level 4 into "healthy", which is the one wrong
/// answer that costs something: it hides a problem instead of inventing one.
SeverityColour severityColour(int level) =>
    severityColours[level.clamp(0, severityColours.length - 1)];

/// The colour for a plot. Out-of-range indices wrap rather than throw: a plot
/// that arrives with a bad slot should still be drawn, just not in the slot it
/// asked for.
PlotColour plotColour(int colourIndex) =>
    plotColours[((colourIndex % plotColours.length) + plotColours.length) % plotColours.length];
