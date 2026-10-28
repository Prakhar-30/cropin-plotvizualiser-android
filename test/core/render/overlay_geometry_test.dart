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
    LatLng agentAt = agent,
  }) =>
      buildPlotOverlay(
        ring: ring,
        centroid: centroidOf(ring),
        agent: agentAt,
        frame: frame,
        deviceToEnu: deviceToEnuFromOrientation(headingDeg, pitchDeg),
        intrinsics: intrinsics,
      );

  /// Shoelace area of a projected polygon, in square pixels.
  double area(List<ScreenPoint> c) {
    var sum = 0.0;
    for (var i = 0; i < c.length; i++) {
      final n = c[(i + 1) % c.length];
      sum += c[i].x * n.y - n.x * c[i].y;
    }
    return sum.abs() / 2;
  }

  test('a distant plot is far mode: a ribbon and a line on every edge, and a label', () {
    final result = overlay(square(100.0, 80.0));

    expect(result.mode, RenderMode.far);
    expect(result.edgeDistanceM, closeTo(80.0, 0.5));
    expect(result.ribbons.length, 4);
    expect(result.lines.length, 4);
    expect(result.ribbons.every((r) => area(r.corners) > 0.0), isTrue);
    expect(result.label, isNotNull);
  });

  test('the boundary lies flat on the ground: nothing projects above the horizon', () {
    // A level camera puts the horizon on the optical centre; ground below eye
    // height is always under it. A wall would have crossed it.
    final result = overlay(square(100.0, 60.0));
    for (final ribbon in result.ribbons) {
      for (final p in ribbon.corners) {
        expect(p.y, greaterThan(intrinsics.centreYPx));
      }
    }
    for (final line in result.lines) {
      expect(line.from.y, greaterThan(intrinsics.centreYPx));
      expect(line.to.y, greaterThan(intrinsics.centreYPx));
    }
  });

  test('ribbons arrive farthest first', () {
    final distances = overlay(square(100.0, 60.0)).ribbons.map((r) => r.nearestDistanceM).toList();
    final sorted = [...distances]..sort((a, b) => b.compareTo(a));
    expect(distances, sorted);
  });

  test('standing near an edge switches to near mode', () {
    final result = overlay(square(100.0, 10.0));
    expect(result.mode, RenderMode.near);
    expect(result.edgeDistanceM, closeTo(10.0, 0.5));
    expect(result.ribbons, isNotEmpty);
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
    expect(result.ribbons.any((r) => r.corners.any((p) => p.isOnScreen(intrinsics))), isTrue);
  });

  test('the arrow points the shorter way round', () {
    // Plot due north, agent facing 300: the plot is 60 deg to the right.
    final result = overlay(square(40.0, 300.0), headingDeg: 300.0);
    expect(result.offscreenBearingDeg, isNotNull);
    expect(result.offscreenBearingDeg!, closeTo(60.0, 3.0));
  });

  test('standing inside a plot keeps the edges in front, clipped at the near plane', () {
    final sw = offset(agent, -50.0, -50.0);
    final ring = [sw, offset(sw, 100.0, 0.0), offset(sw, 100.0, 100.0), offset(sw, 0.0, 100.0), sw];
    final result = overlay(ring);

    expect(result.mode, RenderMode.far);
    expect(result.edgeDistanceM, closeTo(50.0, 0.5));
    expect(result.ribbons, isNotEmpty, reason: 'the edges in front must still be drawn');
    expect(result.ribbons.every((r) => r.nearestDistanceM > 0.0), isTrue,
        reason: 'nothing behind the camera survives the clip');
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

    // The whole shape must move, not only the label. Lines come in ring order.
    var moved = false;
    for (var i = 0; i < math.min(near.lines.length, far.lines.length); i++) {
      if ((near.lines[i].from.y - far.lines[i].from.y).abs() > 1.0) moved = true;
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
    );

    expect(displaced.centroidDistanceM, closeTo(onAgent.centroidDistanceM, 0.2));
    expect(displaced.label!.at.x, closeTo(onAgent.label!.at.x, 1.0));
    expect(displaced.label!.at.y, closeTo(onAgent.label!.at.y, 1.0));
  });

  test('a plot past the marker range is one marker, its label on top', () {
    final result = buildPlotOverlay(
      ring: square(40.0, 120.0),
      centroid: centroidOf(square(40.0, 120.0)),
      agent: agent,
      frame: frame,
      deviceToEnu: deviceToEnuFromOrientation(0.0, 0.0),
      intrinsics: intrinsics,
      asMarker: true,
    );
    expect(result.ribbons, isEmpty, reason: 'no boundary when drawn as a marker');
    expect(result.lines, isEmpty);
    final marker = result.marker!;
    expect(marker.top.y, lessThan(marker.base.y), reason: 'the marker stands up');
    expect(marker.top.x, closeTo(marker.base.x, 1.0));
    expect(marker.top.y, lessThan(intrinsics.centreYPx), reason: 'its head is above eye level');
    expect(result.label!.at.y, closeTo(marker.top.y, 1e-9), reason: 'the header sits on the marker');
    expect(result.offscreenBearingDeg, isNull);
  });

  test('markers switch at 50 m with a band that stops flicker', () {
    expect(showsAsMarker(80, wasMarker: false), isTrue);
    expect(showsAsMarker(20, wasMarker: true), isFalse);
    // Inside the band the plot keeps the look it had.
    expect(showsAsMarker(plotMarkerBeyondM, wasMarker: true), isTrue);
    expect(showsAsMarker(plotMarkerBeyondM, wasMarker: false), isFalse);
    expect(showsAsMarker(plotMarkerBeyondM + plotMarkerHysteresisM, wasMarker: false), isTrue);
    expect(showsAsMarker(plotMarkerBeyondM - plotMarkerHysteresisM, wasMarker: true), isFalse);
  });

  test('a plot marker stands taller than a drop point', () {
    expect(plotMarkerHeightM, greaterThan(4.5));
  });
}
