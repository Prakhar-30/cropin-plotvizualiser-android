import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/math_util.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/core/render/overlay_geometry.dart';

void main() {
  const agent = LatLng(12.7862, 76.7201);
  final frame = EnuFrame(agent);
  final intrinsics = CameraIntrinsics(horizontalFovDeg: 60.0, viewportWidthPx: 1080, viewportHeightPx: 1920);
  final metresPerDegLng = math.cos(toRadians(agent.lat)) * metresPerDegLngAtEquator;

  LatLng offset(double eastM, double northM) =>
      LatLng(agent.lat + northM / metresPerDegLat, agent.lng + eastM / metresPerDegLng);

  HealthPatch patch(HealthIndex index, double eastM, double northM, {int zone = zoneCritical}) => HealthPatch(
        index: index,
        rank: 1,
        zone: zone,
        centroid: offset(eastM, northM),
        cellCount: 3,
        areaSqM: 27,
      );

  List<DropMarker> markers(List<HealthPatch> patches, {double headingDeg = 0.0}) => buildDropMarkers(
        patches: patches,
        frame: frame,
        eye: frame.toEnu(agent),
        enuToDevice: deviceToEnuFromOrientation(headingDeg, 0.0).transpose(),
        intrinsics: intrinsics,
      );

  test('a drop point stands taller than the boundary wall', () {
    expect(dropPointHeightM, greaterThan(boundaryWallHeightM));
  });

  test('a drop point ahead projects as an upright stem, top above base', () {
    final drops = markers([patch(HealthIndex.ndvi, 0, 20)]);
    expect(drops.length, 1);
    final drop = drops.single;
    expect(drop.top.y, lessThan(drop.base.y), reason: 'the head is above the ground on screen');
    expect(drop.base.x, closeTo(540, 1.0), reason: 'straight ahead is the centre column');
    expect(drop.distanceM, closeTo(20, 0.1));
    expect(drop.zone, zoneCritical);
  });

  test('drop points behind the camera are not drawn; far ones come first', () {
    final drops = markers([
      patch(HealthIndex.ndvi, 0, -15),
      patch(HealthIndex.ndvi, 2, 10),
      patch(HealthIndex.ndvi, -2, 40),
    ]);
    expect(drops.length, 2);
    expect(drops.first.distanceM, greaterThan(drops.last.distanceM), reason: 'painted far to near');
  });

  test('nearby patches keep one index, within range, nearest first', () {
    final patches = [
      patch(HealthIndex.ndvi, 0, 50),
      patch(HealthIndex.lswi, 0, 5),
      patch(HealthIndex.ndvi, 0, 10),
      patch(HealthIndex.ndvi, 0, 900),
    ];
    final near = nearbyPatches(patches, agent, HealthIndex.ndvi);
    expect(near.length, 2, reason: 'the water-stress patch and the 900 m one are left out');
    expect(frame.toEnu(near.first.centroid).north, closeTo(10, 0.1));
    expect(nearbyPatches(patches, agent, HealthIndex.ndvi, limit: 1).length, 1);
  });

  test('indices round-trip through their wire names', () {
    for (final index in HealthIndex.values) {
      expect(HealthIndex.fromWire(index.wireName), index);
    }
    expect(HealthIndex.fromWire('evi'), isNull);
    expect(HealthIndex.ndvi.label, 'Crop greenness');
    expect(HealthIndex.ndre.label, 'Crop vigour');
    expect(HealthIndex.lswi.label, 'Water stress');
  });
}
