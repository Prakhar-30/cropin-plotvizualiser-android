import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/linear.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/math_util.dart';
import 'package:plot_finder/core/render/overlay_geometry.dart';

void main() {
  const agent = LatLng(12.7862, 76.7201);
  final frame = EnuFrame(agent);
  final intrinsics = CameraIntrinsics(horizontalFovDeg: 60.0, viewportWidthPx: 1080, viewportHeightPx: 1920);
  final metresPerDegLng = math.cos(toRadians(agent.lat)) * 111320.0;

  /// Offsets a position by metres, using the same model the frame does.
  LatLng offset(LatLng from, double eastM, double northM) =>
      LatLng(from.lat + northM / metresPerDegLat, from.lng + eastM / metresPerDegLng);

  /// A square of `size` metres whose south-west corner is `awayM` north of the agent.
  List<LatLng> square(double size, double awayM) {
    final sw = offset(agent, -size / 2, awayM);
    return [sw, offset(sw, size, 0.0), offset(sw, size, size), offset(sw, 0.0, size), sw];
  }

  LatLng centroidOf(List<LatLng> ring) {
    final open = ring.sublist(0, ring.length - 1);
    return LatLng(
      open.map((p) => p.lat).reduce((a, b) => a + b) / open.length,
      open.map((p) => p.lng).reduce((a, b) => a + b) / open.length,
    );
  }

  PlotOverlay overlay(
    List<LatLng> ring, {
    double headingDeg = 0.0,
    double pitchDeg = 0.0,
    double accuracyM = 6.0,
    LatLng agentAt = agent,
  }) =>
      buildPlotOverlay(
        ring: ring,
        centroid: centroidOf(ring),
        agent: agentAt,
        frame: frame,
        deviceToEnu: deviceToEnuFromOrientation(headingDeg, pitchDeg),
        intrinsics: intrinsics,
        gnssAccuracyM: accuracyM,
      );

  /// Shoelace area of the projected quad, in square pixels.
  double bandArea(OverlayBand band) {
    final c = band.corners;
    var sum = 0.0;
    for (var i = 0; i < c.length; i++) {
      final n = c[(i + 1) % c.length];
      sum += c[i].x * n.y - n.x * c[i].y;
    }
    return sum.abs() / 2;
  }

  test('a distant plot renders in far mode with a filled shape and posts', () {
    final result = overlay(square(100.0, 80.0));

    expect(result.mode, RenderMode.far);
    expect(result.edgeDistanceM, closeTo(80.0, 0.5));
    expect(result.fill.length, greaterThanOrEqualTo(4), reason: 'fill should be a closed shape');
    expect(result.posts.length, 4, reason: 'one post per corner');
    expect(result.bands, isEmpty);
    expect(result.label, isNotNull);
  });

  test('posts stand above their own bases', () {
    final result = overlay(square(100.0, 80.0));
    for (final post in result.posts) {
      expect(post.top.y, lessThan(post.base.y), reason: 'post top must be higher on screen than its base');
      expect(post.top.x, closeTo(post.base.x, 1.0), reason: 'posts are vertical');
    }
  });

  test('standing near an edge switches to near mode and drops the fill', () {
    // Agent 10 m south of the plot's southern edge.
    final result = overlay(square(100.0, 10.0));

    expect(result.mode, RenderMode.near);
    expect(result.edgeDistanceM, closeTo(10.0, 0.5));
    expect(result.fill, isEmpty, reason: 'near mode must not claim a filled area');
    expect(result.posts, isEmpty);
    expect(result.bands, isNotEmpty);
  });

  test('an elongated plot switches on its edge even with a far centroid', () {
    // 400 m long strip whose near edge is 8 m away; its centroid is 200 m off.
    final sw = offset(agent, -20.0, 8.0);
    final strip = [sw, offset(sw, 400.0, 0.0), offset(sw, 400.0, 40.0), offset(sw, 0.0, 40.0), sw];
    final result = overlay(strip);

    expect(result.mode, RenderMode.near);
    expect(result.edgeDistanceM, lessThan(nearModeThresholdM));
    expect(result.centroidDistanceM, greaterThan(100.0),
        reason: 'centroid is far away, which is exactly why it must not drive the switch');
  });

  test('a wider accuracy figure makes a wider band', () {
    // 25 m from the near edge, so even the wide band stays in front of the
    // camera and the comparison is about width alone, not clipping.
    final ring = square(100.0, 25.0);
    final tightArea = bandArea(overlay(ring, accuracyM: 3.0).bands.first);
    final looseArea = bandArea(overlay(ring, accuracyM: 12.0).bands.first);
    expect(looseArea, greaterThan(tightArea * 2), reason: '$looseArea should be well over $tightArea');
  });

  test('an excellent fix still draws a band rather than a hairline', () {
    final result = overlay(square(100.0, 25.0), accuracyM: 0.1);
    expect(bandArea(result.bands.first), greaterThan(0.0));
  });

  test('looking the wrong way reports a bearing for the edge arrow', () {
    // Facing due south while the plot is due north.
    final result = overlay(square(100.0, 120.0), headingDeg: 180.0);

    expect(result.offscreenBearingDeg, isNotNull,
        reason: 'nothing is on screen, so the arrow must have a bearing');
    expect(result.offscreenBearingDeg!.abs(), closeTo(180.0, 2.0));
    expect(result.label, isNull, reason: 'a culled centroid has no label');
  });

  test('facing the plot needs no edge arrow', () {
    final result = overlay(square(100.0, 120.0), headingDeg: 0.0);
    expect(result.offscreenBearingDeg, isNull);
    expect(result.fill.any((p) => p.isOnScreen(intrinsics)), isTrue);
  });

  test('the arrow points the shorter way round', () {
    // Plot due north, agent facing 300: the plot is 60 deg to the right.
    final result = overlay(square(40.0, 300.0), headingDeg: 300.0);
    expect(result.offscreenBearingDeg, isNotNull);
    expect(result.offscreenBearingDeg!, closeTo(60.0, 3.0));
  });

  test('standing inside a large plot clips the outline instead of reshaping it', () {
    // Centre of a 100 m square: every edge is 50 m off, so this is still far
    // mode, and the two corners behind the agent must be clipped rather than
    // dropped - dropping them would close the outline across the field.
    final sw = offset(agent, -50.0, -50.0);
    final ring = [sw, offset(sw, 100.0, 0.0), offset(sw, 100.0, 100.0), offset(sw, 0.0, 100.0), sw];
    final result = overlay(ring);

    expect(result.mode, RenderMode.far);
    expect(result.edgeDistanceM, closeTo(50.0, 0.5));
    expect(result.fill.length, 4, reason: 'two corners in front plus two new points on the clip plane');
    expect(result.posts.length, 2, reason: 'only the two corners in front can carry posts');
  });

  test('standing inside a small plot is near mode', () {
    // Centre of a 40 m square: 20 m to every edge.
    final sw = offset(agent, -20.0, -20.0);
    final ring = [sw, offset(sw, 40.0, 0.0), offset(sw, 40.0, 40.0), offset(sw, 0.0, 40.0), sw];
    final result = overlay(ring);

    expect(result.mode, RenderMode.near);
    expect(result.edgeDistanceM, closeTo(20.0, 0.5));
    expect(result.bands, isNotEmpty, reason: 'some edge must still be drawable');
  });

  test('clipping keeps the visible part of a polygon crossing the near plane', () {
    // A square straddling the camera: two corners in front, two behind.
    const polygon = [
      Vec3(-10.0, 0.0, -50.0), // 50 m in front
      Vec3(10.0, 0.0, -50.0),
      Vec3(10.0, 0.0, 50.0), // 50 m behind
      Vec3(-10.0, 0.0, 50.0),
    ];
    final clipped = clipToNearPlane(polygon);

    expect(clipped.length, 4, reason: 'two originals plus two new points on the plane');
    expect(clipped.every((v) => -v.z >= 0.499), isTrue, reason: 'nothing may survive behind the near plane');
  });

  test('a polygon entirely behind the camera clips to nothing', () {
    const behind = [Vec3(-10.0, 0.0, 50.0), Vec3(10.0, 0.0, 50.0), Vec3(0.0, 0.0, 80.0)];
    expect(clipToNearPlane(behind), isEmpty);
  });

  // Regression test for the bug the partners saw in the field.
  //
  // The frame stays anchored where the session started while the agent walks
  // 50 m towards the plot. The drawing must respond: the camera is at the
  // agent, not at the anchor. Before this was fixed the boundary held a
  // constant apparent distance and appeared to walk along with the agent,
  // while the label counted honestly down.
  test('walking towards a plot moves the drawing, not just the label', () {
    final ring = square(100.0, 100.0);

    final far = overlay(ring);
    final near = overlay(ring, agentAt: offset(agent, 0.0, 50.0));

    // The label numbers were always right; they are the control.
    expect(far.centroidDistanceM, closeTo(150.0, 0.5));
    expect(near.centroidDistanceM, closeTo(100.0, 0.5));

    // Ground below eye height projects below the optical centre, and the
    // drop grows as the inverse of range: 1/100 against 1/150 is a factor
    // of exactly 1.5.
    final farDrop = far.label!.at.y - intrinsics.centreYPx;
    final nearDrop = near.label!.at.y - intrinsics.centreYPx;
    expect(farDrop, greaterThan(0), reason: 'ground should project below the optical centre');
    expect(nearDrop / farDrop, closeTo(1.5, 0.02));

    // The whole shape must move, not only the label.
    var moved = false;
    for (var i = 0; i < math.min(near.fill.length, far.fill.length); i++) {
      if ((near.fill[i].y - far.fill[i].y).abs() > 1.0) moved = true;
    }
    expect(moved, isTrue, reason: 'the boundary must not hold a constant apparent position as the agent walks');
  });

  test('standing still with the frame anchored elsewhere still projects correctly', () {
    // A frame anchored 40 m away from the agent must give the same drawing
    // as one anchored on them: the anchor is bookkeeping, not a viewpoint.
    final ring = square(100.0, 100.0);
    final displacedFrame = EnuFrame(offset(agent, 40.0, -25.0));

    final onAgent = overlay(ring);
    final displaced = buildPlotOverlay(
      ring: ring,
      centroid: centroidOf(ring),
      agent: agent,
      frame: displacedFrame,
      deviceToEnu: deviceToEnuFromOrientation(0.0, 0.0),
      intrinsics: intrinsics,
      gnssAccuracyM: 6.0,
    );

    expect(displaced.centroidDistanceM, closeTo(onAgent.centroidDistanceM, 0.2));
    expect(displaced.label!.at.x, closeTo(onAgent.label!.at.x, 1.0));
    expect(displaced.label!.at.y, closeTo(onAgent.label!.at.y, 1.0));
  });

  // --- vertical boundary walls --------------------------------------------

  test('every boundary edge becomes a standing panel with a top rail', () {
    final result = overlay(square(100.0, 60.0));

    // A square has four edges; all four are in front of a camera 60 m south.
    expect(result.walls.length, 4);
    expect(result.rails.length, 4);
    expect(result.walls.every((w) => w.quad.length >= 3), isTrue, reason: 'panels need at least three corners');
  });

  test('walls stand up on screen rather than lying flat', () {
    final result = overlay(square(100.0, 60.0));

    // The rail is boundaryWallHeightM above the ground, so for a level
    // camera it must project above every point of the panel it caps.
    // Walls are sorted far-to-near and rails are in ring order, so compare
    // every rail against the lowest point of every panel.
    final lowestFoot = result.walls.expand((w) => w.quad).map((p) => p.y).reduce(math.max);
    for (final rail in result.rails) {
      final railY = math.max(rail.from.y, rail.to.y);
      expect(railY, lessThan(lowestFoot), reason: 'rail at $railY should sit above the panel foot at $lowestFoot');
    }
  });

  test('panels are ordered far to near so translucency composites correctly', () {
    final distances = overlay(square(100.0, 60.0)).walls.map((w) => w.nearestDistanceM).toList();
    final sorted = [...distances]..sort((a, b) => b.compareTo(a));
    expect(distances, sorted, reason: 'walls must arrive sorted farthest first');
  });

  test('walls are drawn in near mode too, where the ground fill is suppressed', () {
    final result = overlay(square(100.0, 5.0));

    expect(result.mode, RenderMode.near);
    expect(result.fill, isEmpty, reason: 'near mode drops the ground fill');
    expect(result.walls, isNotEmpty, reason: 'near mode keeps the standing boundary');
  });

  test('a wall the agent is standing inside is clipped, not dropped', () {
    // Standing in the middle of the plot puts two edges behind the camera.
    // Those must still contribute clipped panels rather than vanishing, or
    // the boundary appears to open up behind the agent.
    final result = overlay(square(40.0, -20.0));

    expect(result.mode, RenderMode.near);
    expect(result.walls, isNotEmpty, reason: 'some boundary must remain visible from inside');
    expect(result.walls.every((w) => w.nearestDistanceM > 0.0), isTrue,
        reason: 'clipped panels must stay in front of the camera');
  });

  test('accuracy bands are suppressed when they would engulf the camera', () {
    // Standing 6 m from an edge with a 10 m fix: the band is a 10 m-wide
    // slab lying on the ground, so its near side is 4 m BEHIND the camera.
    final engulfing = overlay(square(60.0, 6.0), accuracyM: 10.0);
    expect(engulfing.mode, RenderMode.near);
    expect(engulfing.bands, isEmpty, reason: 'bands must not be drawn from inside them');
    expect(engulfing.walls, isNotEmpty, reason: 'the boundary itself must still be drawn');

    // Comfortably inside near mode but clear of the band: still drawn.
    final usable = overlay(square(60.0, 25.0), accuracyM: 4.0);
    expect(usable.mode, RenderMode.near);
    expect(usable.bands, isNotEmpty, reason: 'a band that fits in front of the agent is useful');
  });

  test('walls finish above eye level so they read as standing on the ground', () {
    // The rail must project ABOVE the optical centre for a level camera:
    // that is what puts it against the sky rather than lying on the floor,
    // and it is the difference between a fence and a shadow.
    final result = overlay(square(100.0, 40.0));
    final rail = result.rails.reduce(
        (a, b) => math.min(a.from.y, a.to.y) <= math.min(b.from.y, b.to.y) ? a : b);
    expect(rail.from.y, lessThan(intrinsics.centreYPx),
        reason: 'wall tops should sit above the horizon, got y=${rail.from.y}');
  });

  test('a panel fades as the agent walks up to it but its rail never drops below the floor', () {
    expect(wallOpacity(20.0), 1.0);
    expect(wallOpacity(1.0), 0.0);
    expect(wallOpacity(4.75), closeTo(0.5, 1e-9));
    expect(math.max(wallOpacity(1.0), minRailOpacity), minRailOpacity);
  });
}
