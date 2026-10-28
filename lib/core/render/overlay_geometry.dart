import 'dart:math' as math;

import '../geo/enu.dart';
import '../geo/linear.dart';
import '../geo/polygon_geometry.dart';
import '../geo/projection.dart';
import '../math_util.dart';

/// Decides what the overlay should draw, in screen coordinates, without touching
/// a Canvas. Pure, so the mode switch and the culling are unit-testable.

/// Switch point between the two modes, measured to the nearest edge.
const double nearModeThresholdM = 30.0;

/// How wide a plot's boundary ribbon is, measured inwards from the boundary.
///
/// The boundary is drawn flat on the ground, not stood up as a wall: walls of
/// several neighbouring plots overlapped in the camera and made it hard to tell
/// which fence belonged to which plot. A ribbon on the ground lies only inside
/// its own plot, starting exactly on the boundary, so two plots sharing an edge
/// show two bands side by side - each in its own colour, neither covering the
/// other. Wide enough to read in perspective a few tens of metres off; the
/// line down its middle keeps it visible further out.
const double boundaryRibbonWidthM = 0.6;

/// Plots further than this from their nearest edge are drawn as one marker
/// instead of their whole boundary.
///
/// From a distance a field of outlines is clutter: a dozen ribbons and their
/// drop points crowd the frame while saying little more than "there is a plot
/// over there, and this much of it needs attention". The marker says exactly
/// that, and the full boundary comes in as the agent walks up to it.
const double plotMarkerBeyondM = 50.0;

/// Half the band around [plotMarkerBeyondM] in which a plot keeps whichever
/// look it had, so walking along the 50 m line does not flicker between them.
const double plotMarkerHysteresisM = 5.0;

/// How tall a plot marker stands: above the crop drop points (4.5 m), so the
/// two never read as the same kind of thing.
const double plotMarkerHeightM = 6.0;

/// Whether a plot [edgeDistanceM] from the agent is drawn as a marker, given
/// whether it was last time.
bool showsAsMarker(double edgeDistanceM, {required bool wasMarker}) {
  if (edgeDistanceM >= plotMarkerBeyondM + plotMarkerHysteresisM) return true;
  if (edgeDistanceM <= plotMarkerBeyondM - plotMarkerHysteresisM) return false;
  return wasMarker;
}

enum RenderMode {
  /// Beyond 30 m from the nearest edge.
  far('FAR'),

  /// Inside 30 m. The label then carries the live GNSS accuracy, because at
  /// this range it is the size of the error that matters.
  near('NEAR');

  const RenderMode(this.wireName);

  /// The name the telemetry table has always used for this value.
  final String wireName;
}

/// One boundary edge's ribbon on the ground, projected.
///
/// [nearestDistanceM] lets the painter draw far ribbons first, so a near one is
/// never painted over by one behind it.
class OverlayRibbon {
  const OverlayRibbon(this.corners, this.nearestDistanceM);

  final List<ScreenPoint> corners;
  final double nearestDistanceM;
}

/// The line down the middle of one edge's ribbon, projected. Stroked at a fixed
/// pixel width, so a boundary stays visible however far off it is.
class OverlayLine {
  const OverlayLine(this.from, this.to);

  final ScreenPoint from;
  final ScreenPoint to;
}

/// A far plot's marker: a stem up from a point in the plot, its header on top.
class OverlayMarker {
  const OverlayMarker(this.base, this.top);

  final ScreenPoint base;
  final ScreenPoint top;
}

class OverlayLabel {
  const OverlayLabel(this.at, this.distanceM);

  final ScreenPoint at;
  final double distanceM;
}

class PlotOverlay {
  const PlotOverlay({
    required this.mode,
    required this.edgeDistanceM,
    required this.centroidDistanceM,
    required this.ribbons,
    required this.lines,
    this.marker,
    required this.label,
    required this.offscreenBearingDeg,
  });

  final RenderMode mode;
  final double edgeDistanceM;
  final double centroidDistanceM;

  /// The boundary ribbon, one quad per edge, ordered far to near.
  final List<OverlayRibbon> ribbons;

  /// The line down the middle of each ribbon.
  final List<OverlayLine> lines;

  /// The plot as one marker, when it is drawn as one; its ribbons are then empty.
  final OverlayMarker? marker;

  /// Where the label stands: on the ground inside the plot, or on top of the
  /// marker.
  final OverlayLabel? label;

  /// Relative bearing to the plot when nothing of it is on screen, so the UI can
  /// put an arrow at the edge. Negative is left, positive is right.
  final double? offscreenBearingDeg;
}

List<ScreenPoint> projectVisible(List<Vec3> points, CameraIntrinsics intrinsics) => [
      for (final p in points)
        if (projectDevice(p, intrinsics) case final projected?) projected,
    ];

/// Projects one plot's boundary for the sensor fallback path.
///
/// All geometry sits on the ground plane, taken as the device's own altitude
/// minus [eyeHeight] - measured by ARCore when it has found the floor, a fixed
/// assumption otherwise. There is no terrain model and no attempt at one: a
/// wrong elevation would tilt the whole shape, and on the flat farmland this is
/// built for, assuming level ground is both simpler and closer to true.
PlotOverlay buildPlotOverlay({
  required List<LatLng> ring,
  required LatLng centroid,
  required LatLng agent,
  required EnuFrame frame,
  required Mat3 deviceToEnu,
  required CameraIntrinsics intrinsics,
  double eyeHeight = eyeHeightM,
  bool asMarker = false,
}) {
  final enuToDevice = deviceToEnu.transpose();
  final groundUp = -eyeHeight;

  final ringGround = openRing([for (final p in ring) frame.toEnu(p, groundUp)]);

  // The camera. It sits at the agent's own position, at up = 0, which puts it
  // eyeHeight above the ground plane the boundary is drawn on. Everything
  // projected below is measured from here, never from the frame origin.
  final eye = frame.toEnu(agent);

  // Distances are measured on the ground, ignoring the eye-height offset.
  final agentFlat = Enu(eye.east, eye.north);
  final ringFlat = [for (final p in ringGround) Enu(p.east, p.north)];

  final edgeDistanceM = distanceToNearestEdgeM(ringFlat, agentFlat);
  final centroidEnu = frame.toEnu(centroid, groundUp);
  final centroidDistanceM = hypot(
    centroidEnu.east - agentFlat.east,
    centroidEnu.north - agentFlat.north,
  );

  final mode = edgeDistanceM < nearModeThresholdM ? RenderMode.near : RenderMode.far;

  final (ribbons, lines) =
      asMarker ? (const <OverlayRibbon>[], const <OverlayLine>[]) : _buildRibbons(ringGround, eye, enuToDevice, intrinsics);

  OverlayMarker? marker;
  if (asMarker) {
    final base = projectDevice(toDevice(centroidEnu, eye, enuToDevice), intrinsics);
    final top = projectDevice(
      toDevice(Enu(centroidEnu.east, centroidEnu.north, centroidEnu.up + plotMarkerHeightM), eye, enuToDevice),
      intrinsics,
    );
    if (base != null && top != null) marker = OverlayMarker(base, top);
  }

  final labelPoint = marker?.top ?? (asMarker ? null : projectDevice(toDevice(centroidEnu, eye, enuToDevice), intrinsics));
  final label = labelPoint == null ? null : OverlayLabel(labelPoint, centroidDistanceM);

  // Short-circuits on the first visible point instead of concatenating every
  // projected point of the plot into a throwaway list each frame.
  bool onScreen(ScreenPoint p) => p.isOnScreen(intrinsics);
  final anythingVisible = ribbons.any((r) => r.corners.any(onScreen)) ||
      lines.any((l) => onScreen(l.from) || onScreen(l.to)) ||
      (marker != null && (onScreen(marker.base) || onScreen(marker.top)));

  final offscreenBearingDeg = anythingVisible
      ? null
      : angleDifferenceDeg(
          cameraHeadingDeg(deviceToEnu),
          Enu(centroidEnu.east - agentFlat.east, centroidEnu.north - agentFlat.north).bearingDeg,
        );

  return PlotOverlay(
    mode: mode,
    edgeDistanceM: edgeDistanceM,
    centroidDistanceM: centroidDistanceM,
    ribbons: ribbons,
    lines: lines,
    marker: marker,
    label: label,
    offscreenBearingDeg: offscreenBearingDeg,
  );
}

/// Lays each boundary edge on the ground as a ribbon running from the boundary
/// [boundaryRibbonWidthM] into the plot, plus the line down its middle.
///
/// Each ribbon is clipped to the near plane as a polygon, so walking across a
/// boundary keeps the part in front of the camera rather than dropping the edge.
(List<OverlayRibbon>, List<OverlayLine>) _buildRibbons(
  List<Enu> ringGround,
  Enu eye,
  Mat3 enuToDevice,
  CameraIntrinsics intrinsics,
) {
  final n = ringGround.length;
  if (n < 3) return (const <OverlayRibbon>[], const <OverlayLine>[]);
  final inner = insetRing(ringGround, boundaryRibbonWidthM);
  final middle = insetRing(ringGround, boundaryRibbonWidthM / 2);

  final ribbons = <OverlayRibbon>[];
  final lines = <OverlayLine>[];
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    final quad = [ringGround[i], ringGround[j], inner[j], inner[i]];
    final projected = projectVisible(
      clipToNearPlane([for (final p in quad) toDevice(p, eye, enuToDevice)]),
      intrinsics,
    );
    if (projected.length >= 3) {
      ribbons.add(OverlayRibbon(projected, projected.map((p) => p.distanceM).reduce(math.min)));
    }

    final segment = clipSegmentToNearPlane(
      toDevice(middle[i], eye, enuToDevice),
      toDevice(middle[j], eye, enuToDevice),
    );
    if (segment != null) {
      final from = projectDevice(segment.$1, intrinsics);
      final to = projectDevice(segment.$2, intrinsics);
      if (from != null && to != null) lines.add(OverlayLine(from, to));
    }
  }

  // Far first: translucent ribbons composited in ring order let a far edge
  // paint over a near one.
  ribbons.sort((x, y) => y.nearestDistanceM.compareTo(x.nearestDistanceM));
  return (ribbons, lines);
}
