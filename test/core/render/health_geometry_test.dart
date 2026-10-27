import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/math_util.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/core/render/plot_palette.dart';

void main() {
  const agent = LatLng(12.7862, 76.7201);
  final frame = EnuFrame(agent);
  final intrinsics = CameraIntrinsics(horizontalFovDeg: 60.0, viewportWidthPx: 1080, viewportHeightPx: 1920);
  final metresPerDegLng = math.cos(toRadians(agent.lat)) * 111320.0;

  LatLng offset(LatLng from, double eastM, double northM) =>
      LatLng(from.lat + northM / metresPerDegLat, from.lng + eastM / metresPerDegLng);

  /// A [sizeM] square cell whose centre sits [eastM]/[northM] from the agent.
  HealthCell cell(int severity, double eastM, double northM, {double sizeM = 10.0}) {
    final half = sizeM / 2;
    final centre = offset(agent, eastM, northM);
    return HealthCell(
      severity: severity,
      centroid: centre,
      ring: [
        offset(centre, -half, -half),
        offset(centre, half, -half),
        offset(centre, half, half),
        offset(centre, -half, half),
        offset(centre, -half, -half),
      ],
    );
  }

  HealthHotspot hotspot(int rank, double eastM, double northM, {int severity = 3}) =>
      HealthHotspot(rank: rank, severity: severity, centroid: offset(agent, eastM, northM));

  HealthField field(List<HealthCell> cells, [List<HealthHotspot> hotspots = const []]) =>
      HealthField(cells, hotspots, frame);

  HealthOverlay overlayFor(
    List<HealthCell> cells, {
    List<HealthHotspot> hotspots = const [],
    HealthLayer layer = HealthLayer.all,
    double headingDeg = 0.0,
    double pitchDeg = 0.0,
    double maxRangeM = healthMaxRangeM,
    int maxPatches = maxHealthPatches,
  }) =>
      buildHealthOverlay(
        field: field(cells, hotspots),
        eye: frame.toEnu(agent),
        enuToDevice: deviceToEnuFromOrientation(headingDeg, pitchDeg).transpose(),
        intrinsics: intrinsics,
        layer: layer,
        maxRangeM: maxRangeM,
        maxPatches: maxPatches,
      );

  test('a cell ahead of the agent projects onto the screen', () {
    // Pitched down: the ground 40 m out is below the horizon, so a level
    // phone would put it near the top edge and a test that only checked for
    // "some points" would pass on geometry that is actually behind the eye.
    final result = overlayFor([cell(3, 0.0, 40.0)], pitchDeg: -15.0);

    expect(result.patches.length, 1);
    final patch = result.patches.first;
    expect(patch.corners.length, greaterThanOrEqualTo(3), reason: 'a square cell keeps at least three corners');
    expect(patch.corners.any((p) => p.isOnScreen(intrinsics)), isTrue, reason: 'the cell should be visible');
    expect(patch.severity, 3);
  });

  test('the ground is below the horizon, never above it', () {
    // The single most visible failure mode: a sign error on the ground plane
    // puts the crop health in the sky. Held level, the ground can only ever
    // project below the centre line.
    final result = overlayFor([cell(2, 0.0, 30.0)]);
    final centreY = intrinsics.centreYPx;
    for (final corner in result.patches.first.corners) {
      expect(corner.y, greaterThan(centreY),
          reason: 'ground corner at y=${corner.y} must be below the horizon at $centreY');
    }
  });

  test('the stress layer hides healthy cells and counts them', () {
    final cells = [cell(0, -12.0, 40.0), cell(0, 0.0, 40.0), cell(2, 12.0, 40.0)];

    final all = overlayFor(cells, layer: HealthLayer.all, pitchDeg: -15.0);
    expect(all.patches.length, 3);
    expect(all.hiddenCellCount, 0);

    final stress = overlayFor(cells, layer: HealthLayer.stress, pitchDeg: -15.0);
    expect(stress.patches.length, 1, reason: 'only the stressed cell survives');
    expect(stress.patches.first.severity, 2);
    // The count is what lets the UI say "2 healthy cells hidden" rather than
    // leaving a gap the agent reads as missing data.
    expect(stress.hiddenCellCount, 2);
  });

  test('the off layer draws nothing at all', () {
    final result = overlayFor(
      [cell(3, 0.0, 20.0)],
      hotspots: [hotspot(1, 0.0, 20.0)],
      layer: HealthLayer.off,
    );
    expect(result.patches, isEmpty);
    expect(result.markers, isEmpty, reason: 'markers must go too, not just the fill');
  });

  test('cells beyond the range limit are dropped', () {
    final near = cell(3, 0.0, 50.0);
    final far = cell(3, 0.0, 400.0);

    expect(overlayFor([near, far], pitchDeg: -15.0).patches.length, 1,
        reason: 'the 400 m cell is past the 150 m limit');
    // And the drop is by distance, not by list order.
    expect(overlayFor([far, near], pitchDeg: -15.0).patches.length, 1);
  });

  test('a range-culled cell is not counted as hidden by the layer', () {
    // hiddenCellCount drives a "n cells hidden" readout. If range culling
    // fed into it, standing at one end of a large plot would report hundreds
    // of hidden cells that the toggle cannot bring back.
    final result = overlayFor([cell(0, 0.0, 400.0)], layer: HealthLayer.stress);
    expect(result.hiddenCellCount, 0);
    expect(result.patches, isEmpty);
  });

  test('patches are ordered far to near so near cells paint last', () {
    final cells = [for (var i = 1; i <= 6; i++) cell(2, 0.0, i * 12.0)];
    final result = overlayFor(cells, pitchDeg: -20.0);

    expect(result.patches.length, greaterThanOrEqualTo(4), reason: 'expected several patches');
    final distances = result.patches.map((p) => p.nearestDistanceM).toList();
    final sorted = [...distances]..sort((a, b) => b.compareTo(a));
    expect(distances, sorted, reason: "painter's algorithm: farthest first");
  });

  test('the patch cap keeps the nearest cells, not the first ones', () {
    // Listed farthest-first on purpose: a cap that just took the head of the
    // list would keep the cells the agent cannot reach and drop the ones
    // under their feet.
    final cells = [for (var i = 1; i <= 12; i++) cell(2, 0.0, (13 - i) * 10.0)];
    final result = overlayFor(cells, pitchDeg: -20.0, maxPatches: 3);

    expect(result.patches.length, 3);
    expect(result.patches.every((p) => p.nearestDistanceM < 45.0), isTrue,
        reason: 'kept patches should all be close, not 100 m out');
  });

  test('foreground cells fade but never vanish', () {
    final underfoot = overlayFor([cell(3, 0.0, 2.0)], pitchDeg: -45.0).patches.first;
    final ahead = overlayFor([cell(3, 0.0, 60.0)], pitchDeg: -10.0).patches.first;

    expect(underfoot.opacity, lessThan(ahead.opacity), reason: 'a cell underfoot must be faded');
    expect(underfoot.opacity, greaterThanOrEqualTo(minPatchOpacity),
        reason: 'but standing on a critical patch is worth knowing');
    expect(ahead.opacity, closeTo(1.0, 1e-4), reason: 'a distant cell is drawn at full strength');
  });

  test('hotspot markers stand up from the ground', () {
    final result = overlayFor(
      [cell(3, 0.0, 45.0)],
      hotspots: [hotspot(1, 0.0, 45.0)],
      pitchDeg: -10.0,
    );

    expect(result.markers.length, 1);
    final marker = result.markers.first;
    expect(marker.top.y, lessThan(marker.base.y), reason: 'the stem must rise on screen');
    expect(marker.rank, 1);
    expect(marker.distanceM, closeTo(45.0, 0.5));
  });

  test('markers survive the stress layer regardless of banding', () {
    // A hotspot is the walk-to target. It must not disappear because the
    // layer happens to be filtering the cells around it.
    final result = overlayFor(
      [cell(0, 0.0, 45.0)],
      hotspots: [hotspot(1, 0.0, 45.0)],
      layer: HealthLayer.stress,
      pitchDeg: -10.0,
    );
    expect(result.patches, isEmpty, reason: 'the healthy cell is hidden');
    expect(result.markers.length, 1, reason: 'the marker is not');
  });

  test('a cell behind the agent is culled rather than mirrored', () {
    // Without near-plane clipping, a point behind the camera projects to a
    // mirrored position in front of it - a stress patch that appears in
    // exactly the wrong direction.
    final behind = overlayFor([cell(3, 0.0, -40.0)], pitchDeg: -15.0);
    expect(
      behind.patches.every((patch) => !patch.corners.any((p) => p.isOnScreen(intrinsics))),
      isTrue,
      reason: 'nothing behind the agent may be drawn',
    );
  });

  test('a cell straddling the camera keeps its front half', () {
    // The agent standing inside a cell: the ground you are standing on is
    // the ground you most want graded.
    final result = overlayFor([cell(3, 0.0, 0.0, sizeM: 20.0)], pitchDeg: -40.0);
    expect(result.patches.length, 1);
    expect(result.patches.first.corners.length, greaterThanOrEqualTo(3));
  });

  test('the field is reusable only for the frame it was built against', () {
    final built = field([cell(1, 0.0, 30.0)]);
    expect(built.matches(frame), isTrue);
    // A re-anchor produces a new frame with a new origin. Reusing the old
    // metres against it would offset the raster by the whole walk.
    expect(built.matches(EnuFrame(offset(agent, 500.0, 0.0))), isFalse);
  });

  test('a degenerate cell is dropped rather than drawn as a sliver', () {
    final degenerate = HealthCell(
      severity: 3,
      centroid: offset(agent, 0.0, 30.0),
      ring: [offset(agent, 0.0, 30.0), offset(agent, 1.0, 30.0)],
    );
    expect(field([degenerate]).cells, isEmpty);
  });

  test('severity colours cover every band the classifier can emit', () {
    // The renderer indexes this list by a value that arrives over the wire.
    expect(severityColours.length, 4);
    for (var i = 0; i < severityColours.length; i++) {
      expect(severityColours[i].level, i);
    }

    // Clamped, not wrapped: a corrupt band must not read as "healthy".
    expect(severityColour(9).level, 3);
    expect(severityColour(-2).level, 0);

    // And the ramp must actually rise, or the fade encodes nothing.
    final alphas = severityColours.map((s) => s.fillAlpha).toList();
    expect(alphas, [...alphas]..sort());
  });

  test('the layer button cycles off, problem areas, all cells', () {
    expect(HealthLayer.off.next(), HealthLayer.stress);
    expect(HealthLayer.stress.next(), HealthLayer.all);
    expect(HealthLayer.all.next(), HealthLayer.off);
    expect(HealthLayer.stress.minSeverity, 1);
    expect(HealthLayer.all.minSeverity, 0);
  });
}
