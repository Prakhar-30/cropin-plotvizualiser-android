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

/// How tall the vertex posts stand above the ground plane.
const double vertexPostHeightM = 2.5;

/// How tall the boundary wall stands.
///
/// The first field test drew the boundary flat on the ground, and the reviewers'
/// first comment was that it read as a coloured carpet rather than as a fence -
/// a shape lying on the floor gives the eye no cue that it is a *limit*. Standing
/// the edges up fixes that, and it also fixes a subtler problem: a flat overlay
/// disappears entirely when the phone is held level, because the ground plane is
/// then edge-on to the camera.
///
/// Measured from the ground, and tall enough to finish one metre above the
/// agent's eye. Field feedback was that a wall topping out below eye level reads
/// as floating: the eye takes the top rail for the boundary and the bottom edge
/// for a shadow, because nothing visually connects it to the ground. Carrying it
/// past eye level puts the rail against the sky or the far treeline instead, and
/// the panel unmistakably stands on the earth.
const double boundaryWallHeightM = eyeHeightM + 1.0;

enum RenderMode {
  /// Beyond 30 m: a translucent filled shape with a post at each corner. The
  /// *shape* is the point - a pin tells the agent nothing about which of six
  /// identical fields they are looking at, while an outline they can match
  /// against the hedge line confirms it even when heading is a few degrees off.
  far('FAR'),

  /// Inside 30 m: no fill, and each edge becomes a band as wide as the current
  /// GNSS accuracy. A crisp line here would be a false precision claim, and the
  /// first time a farmer disputes a reading it is the line that gets blamed.
  near('NEAR');

  const RenderMode(this.wireName);

  /// The name the telemetry table has always used for this value.
  final String wireName;
}

class OverlayPost {
  const OverlayPost(this.base, this.top);

  final ScreenPoint base;
  final ScreenPoint top;
}

/// One boundary edge, stood up into a vertical panel.
///
/// [nearestDistanceM] exists so the renderer can draw far walls first. Without
/// that ordering the translucent panels composite in ring order, and the far side
/// of a plot paints over the near side - which looks like a fold in the boundary.
class OverlayWall {
  const OverlayWall(this.quad, this.nearestDistanceM, this.opacity);

  final List<ScreenPoint> quad;
  final double nearestDistanceM;

  /// How solidly to draw this panel, 0..1.
  ///
  /// A 2.6 m wall standing 3 m from the camera subtends most of the frame, and
  /// a boundary the agent is standing against is the one they least need drawn
  /// over their view - they can see the fence. Panels fade out as they come
  /// within [wallFadeStartM], so walking up to a boundary opens the camera
  /// back up instead of filling it with colour.
  final double opacity;
}

/// The top edge of a wall, stroked solid so the boundary line stays crisp.
class OverlayRail {
  const OverlayRail(this.from, this.to, this.opacity);

  final ScreenPoint from;
  final ScreenPoint to;
  final double opacity;
}

/// Panels nearer than this begin to fade; the rail stays, the fill goes.
const double wallFadeStartM = 8.0;

/// Below this the panel is gone entirely and only its top rail remains.
const double wallFadeEndM = 1.5;

/// Ramps a surface's opacity in over the last few metres of approach.
///
/// Two surfaces need this and they need different floors, so it is written once
/// with the floor as a parameter rather than twice with one number changed.
/// Below [fadeEndM] the result is [floor]; above [fadeStartM] it is 1; between
/// them it is linear.
///
/// The general problem it solves is the same in both cases: geometry drawn on or
/// near the camera subtends far more of the frame than its importance justifies,
/// because perspective magnifies whatever is close. Fading by distance is the
/// cheapest correction that does not require knowing the projected area.
double linearFade(double distanceM, double fadeEndM, double fadeStartM, {double floor = 0.0}) {
  if (distanceM >= fadeStartM) return 1.0;
  if (distanceM <= fadeEndM) return floor;
  final t = (distanceM - fadeEndM) / (fadeStartM - fadeEndM);
  return floor + (1.0 - floor) * t;
}

/// Fade factor for a panel at [distanceM].
///
/// The rail never fades below [minRailOpacity]: the line is the boundary, and
/// losing it as you step up to the fence would remove the answer at exactly the
/// moment the agent is trying to stand on it. The panel itself goes to nothing,
/// so walking up to a boundary opens the camera back up.
double wallOpacity(double distanceM) => linearFade(distanceM, wallFadeEndM, wallFadeStartM);

const double minRailOpacity = 0.75;

/// Four projected corners of an accuracy band around one boundary edge.
class OverlayBand {
  const OverlayBand(this.corners);

  final List<ScreenPoint> corners;
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
    required this.fill,
    required this.walls,
    required this.rails,
    required this.bands,
    required this.posts,
    required this.label,
    required this.offscreenBearingDeg,
  });

  final RenderMode mode;
  final double edgeDistanceM;
  final double centroidDistanceM;

  /// Closed ground outline. Kept faint - the walls carry the boundary now.
  final List<ScreenPoint> fill;

  /// The standing boundary panels, ordered far to near for correct blending.
  final List<OverlayWall> walls;

  /// Top edge of each wall.
  final List<OverlayRail> rails;

  /// Accuracy bands in near mode, empty in far mode.
  final List<OverlayBand> bands;
  final List<OverlayPost> posts;
  final OverlayLabel? label;

  /// Relative bearing to the plot when nothing of it is on screen, so the UI can
  /// put an arrow at the edge. Negative is left, positive is right.
  final double? offscreenBearingDeg;
}

/// Even a perfect fix does not justify a hairline: below this the band stops
/// shrinking, so the drawing never implies centimetre certainty.
const double minBandHalfWidthM = 1.5;

/// Projects every point that survives the behind-camera cull, in order.
List<ScreenPoint> projectVisible(List<Vec3> points, CameraIntrinsics intrinsics) => [
      for (final p in points)
        if (projectDevice(p, intrinsics) case final projected?) projected,
    ];

/// Builds the overlay for one plot.
///
/// All geometry sits on the ground plane, taken as the device's own altitude
/// minus a fixed eye height. There is no terrain model and no attempt at one: a
/// wrong elevation would tilt the whole shape, and on the flat farmland this is
/// built for, assuming level ground is both simpler and closer to true.
PlotOverlay buildPlotOverlay({
  required List<LatLng> ring,
  required LatLng centroid,
  required LatLng agent,
  required EnuFrame frame,
  required Mat3 deviceToEnu,
  required CameraIntrinsics intrinsics,
  required double gnssAccuracyM,
}) {
  final enuToDevice = deviceToEnu.transpose();
  const groundUp = -eyeHeightM;

  final ringGround = openRing([for (final p in ring) frame.toEnu(p, groundUp)]);

  // The camera. It sits at the agent's own position, at up = 0, which puts it
  // eyeHeightM above the ground plane the boundary is drawn on. Everything
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

  final fill = mode == RenderMode.far
      ? projectVisible(
          clipToNearPlane([for (final p in ringGround) toDevice(p, eye, enuToDevice)]),
          intrinsics,
        )
      : const <ScreenPoint>[];

  // Walls are drawn in both modes. They are the boundary now; the ground fill
  // has been demoted to a faint hint of which side of the line the crop is on.
  final (walls, rails) = _buildWalls(ringGround, eye, enuToDevice, intrinsics);

  // Accuracy bands are suppressed once the agent is closer to the edge than
  // the accuracy itself. A band is a slab `gnssAccuracyM` wide lying on the
  // ground; standing 6 m from an edge with an 8 m fix puts its near side
  // *behind* the camera, so it wraps around the viewer and floods the whole
  // frame with translucent colour. The honest statement at that range is not
  // a shape at all - it is the number already printed on the label, and the
  // walls still show where the boundary is believed to run.
  final bandHalfWidth = math.max(gnssAccuracyM, minBandHalfWidthM);
  final bands = mode == RenderMode.near && edgeDistanceM > bandHalfWidth
      ? _buildBands(ringGround, eye, enuToDevice, intrinsics, gnssAccuracyM)
      : const <OverlayBand>[];

  final posts = <OverlayPost>[];
  if (mode == RenderMode.far) {
    for (final vertex in ringGround) {
      final base = projectDevice(toDevice(vertex, eye, enuToDevice), intrinsics);
      final top = projectDevice(
        toDevice(Enu(vertex.east, vertex.north, vertex.up + vertexPostHeightM), eye, enuToDevice),
        intrinsics,
      );
      if (base != null && top != null) posts.add(OverlayPost(base, top));
    }
  }

  final labelPoint = projectDevice(toDevice(centroidEnu, eye, enuToDevice), intrinsics);
  final label = labelPoint == null ? null : OverlayLabel(labelPoint, centroidDistanceM);

  final anythingVisible = [
    ...fill,
    for (final w in walls) ...w.quad,
    for (final b in bands) ...b.corners,
    for (final p in posts) p.base,
  ].any((it) => it.isOnScreen(intrinsics));

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
    fill: fill,
    walls: walls,
    rails: rails,
    bands: bands,
    posts: posts,
    label: label,
    offscreenBearingDeg: offscreenBearingDeg,
  );
}

/// Stands each boundary edge up into a vertical panel.
///
/// Each edge becomes a quad wound up-across-down, so the polygon stays simple and
/// the near-plane clipper produces a sensible result when the agent walks through
/// a boundary. The top edge is emitted separately as a rail: clipping a closed
/// quad loses which of its sides was the top, and a solid line along the top is
/// what makes a translucent panel read as a fence rather than as haze.
(List<OverlayWall>, List<OverlayRail>) _buildWalls(
  List<Enu> ringGround,
  Enu eye,
  Mat3 enuToDevice,
  CameraIntrinsics intrinsics,
) {
  if (ringGround.length < 2) return (const <OverlayWall>[], const <OverlayRail>[]);

  final walls = <OverlayWall>[];
  final rails = <OverlayRail>[];

  for (var i = 0; i < ringGround.length; i++) {
    final a = ringGround[i];
    final b = ringGround[(i + 1) % ringGround.length];
    final aTop = Enu(a.east, a.north, a.up + boundaryWallHeightM);
    final bTop = Enu(b.east, b.north, b.up + boundaryWallHeightM);

    final quad = [for (final p in [a, b, bTop, aTop]) toDevice(p, eye, enuToDevice)];
    final projected = projectVisible(clipToNearPlane(quad), intrinsics);
    if (projected.length >= 3) {
      final nearest = projected.map((p) => p.distanceM).reduce(math.min);
      final opacity = wallOpacity(nearest);
      if (opacity > 0.0) walls.add(OverlayWall(projected, nearest, opacity));
    }

    final rail = clipSegmentToNearPlane(
      toDevice(aTop, eye, enuToDevice),
      toDevice(bTop, eye, enuToDevice),
    );
    if (rail != null) {
      final from = projectDevice(rail.$1, intrinsics);
      final to = projectDevice(rail.$2, intrinsics);
      if (from != null && to != null) {
        final nearest = math.min(from.distanceM, to.distanceM);
        rails.add(OverlayRail(from, to, math.max(wallOpacity(nearest), minRailOpacity)));
      }
    }
  }

  // Painter's algorithm. Translucent panels composited in ring order let the
  // far side of a plot paint over the near side, which looks like a crease.
  walls.sort((x, y) => y.nearestDistanceM.compareTo(x.nearestDistanceM));
  return (walls, rails);
}

/// Widens each boundary edge into a rectangle whose half-width is the live GNSS
/// accuracy, then projects it. Building the band in metres rather than pixels
/// means perspective narrows it with distance on its own, which is what an
/// uncertainty of a fixed number of metres actually looks like.
List<OverlayBand> _buildBands(
  List<Enu> ringGround,
  Enu eye,
  Mat3 enuToDevice,
  CameraIntrinsics intrinsics,
  double accuracyM,
) {
  if (ringGround.length < 2) return const [];
  final halfWidth = math.max(accuracyM, minBandHalfWidthM);

  final bands = <OverlayBand>[];
  for (var i = 0; i < ringGround.length; i++) {
    final a = ringGround[i];
    final b = ringGround[(i + 1) % ringGround.length];
    final dEast = b.east - a.east;
    final dNorth = b.north - a.north;
    final length = hypot(dEast, dNorth);
    if (length < 1e-6) continue;

    // Unit normal to the edge, in the ground plane.
    final nEast = dNorth / length * halfWidth;
    final nNorth = -dEast / length * halfWidth;

    final quad = [
      Enu(a.east + nEast, a.north + nNorth, a.up),
      Enu(b.east + nEast, b.north + nNorth, b.up),
      Enu(b.east - nEast, b.north - nNorth, b.up),
      Enu(a.east - nEast, a.north - nNorth, a.up),
    ];
    final projected = projectVisible(
      clipToNearPlane([for (final p in quad) toDevice(p, eye, enuToDevice)]),
      intrinsics,
    );
    if (projected.length >= 3) bands.add(OverlayBand(projected));
  }
  return bands;
}
