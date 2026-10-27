import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/boundary_snap.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/math_util.dart';

void main() {
  const origin = LatLng(12.7862, 76.7201);
  final metresPerDegLng = math.cos(toRadians(origin.lat)) * metresPerDegLngAtEquator;
  LatLng offset(double eastM, double northM) =>
      LatLng(origin.lat + northM / metresPerDegLat, origin.lng + eastM / metresPerDegLng);

  // A 40 m square with its south-west corner at the origin.
  final square = [offset(0, 0), offset(40, 0), offset(40, 40), offset(0, 40), offset(0, 0)];

  test('beside an edge, the snap point is computed between two corners', () {
    final hit = nearestBoundaryPoint([square], offset(20, -6))!;
    expect(hit.distanceM, closeTo(6.0, 0.01));
    final back = EnuFrame(origin).toEnu(hit.point);
    expect(back.east, closeTo(20.0, 0.01), reason: 'the perpendicular foot on the south edge');
    expect(back.north, closeTo(0.0, 0.01));
  });

  test('off a corner, the corner itself is the snap point', () {
    final hit = nearestBoundaryPoint([square], offset(-3, -4))!;
    expect(hit.distanceM, closeTo(5.0, 0.01));
    final back = EnuFrame(origin).toEnu(hit.point);
    expect(back.east, closeTo(0.0, 0.01));
    expect(back.north, closeTo(0.0, 0.01));
  });

  test('inside a plot, the nearest edge is still found', () {
    final hit = nearestBoundaryPoint([square], offset(35, 20))!;
    expect(hit.distanceM, closeTo(5.0, 0.01));
    expect(insideRing(square, offset(35, 20)), isTrue);
    expect(insideRing(square, offset(45, 20)), isFalse);
  });

  test('among several plots, the closest boundary wins and says which plot', () {
    final east = [offset(60, 0), offset(100, 0), offset(100, 40), offset(60, 40), offset(60, 0)];
    final hit = nearestBoundaryPoint([square, east], offset(55, 20))!;
    expect(hit.ringIndex, 1, reason: '5 m from the second plot, 15 m from the first');
    expect(hit.distanceM, closeTo(5.0, 0.01));
  });

  test('the snap radius is the 5-10 m the field flow asked for', () {
    expect(autoSnapDistanceM, 10.0);
    expect(nearestBoundaryPoint([], origin), isNull);
  });
}
