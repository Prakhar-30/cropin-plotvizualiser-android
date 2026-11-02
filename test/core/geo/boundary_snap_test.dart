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

  test('the snap radius is 5 m, as the vineyard test asked for', () {
    expect(autoSnapDistanceM, 5.0);
    expect(nearestBoundaryPoint([], origin), isNull);
  });

  group('steadyFix', () {
    AnchorFix fix(double east, double north, int atMs, {double accuracyM = 5.0}) =>
        AnchorFix(offset(east, north), accuracyM, atMs);

    test('averages a few seconds of agreeing fixes', () {
      final steady = steadyFix([fix(0, 0, 0), fix(2, 0, 1000), fix(0, 2, 2000), fix(2, 2, 3000)], 3000)!;
      final at = EnuFrame(origin).toEnu(steady);
      expect(at.east, closeTo(1.0, 0.01));
      expect(at.north, closeTo(1.0, 0.01));
    });

    test('waits for enough fixes', () {
      expect(steadyFix([fix(0, 0, 0), fix(1, 0, 1000)], 1000), isNull);
    });

    test('waits while any fix claims worse than 10 m', () {
      expect(
        steadyFix([fix(0, 0, 0), fix(1, 0, 1000), fix(0, 1, 2000), fix(1, 1, 3000, accuracyM: 12)], 3000),
        isNull,
      );
    });

    test('waits while the fixes disagree - one reflection 9 m out', () {
      expect(steadyFix([fix(0, 0, 0), fix(1, 0, 1000), fix(0, 1, 2000), fix(9, 0, 3000)], 3000), isNull);
    });

    test('only the last four seconds count', () {
      final fixes = [fix(30, 30, 0), fix(0, 0, 6000), fix(1, 0, 7000), fix(0, 1, 8000), fix(1, 1, 9000)];
      final at = EnuFrame(origin).toEnu(steadyFix(fixes, 9000)!);
      expect(at.east, closeTo(0.5, 0.01), reason: 'the old fix 30 m away is out of the window');
    });
  });

  group('confirmedInside', () {
    // Two 20 m plots side by side, sharing the edge at east = 20.
    final west = [offset(0, 0), offset(20, 0), offset(20, 20), offset(0, 20), offset(0, 0)];
    final east = [offset(20, 0), offset(40, 0), offset(40, 20), offset(20, 20), offset(20, 0)];
    final rings = {'W': west, 'E': east};

    test('enters a plot only once well inside it', () {
      expect(confirmedInside(rings, offset(19.5, 10), null), isNull, reason: 'half a metre in is not yet inside');
      expect(confirmedInside(rings, offset(17, 10), null), 'W');
    });

    test('keeps the plot across the shared edge until clearly in the next', () {
      expect(confirmedInside(rings, offset(21, 10), 'W'), 'W', reason: '1 m over the line: still W');
      expect(confirmedInside(rings, offset(23, 10), 'W'), 'E', reason: '3 m into E: now E');
      expect(confirmedInside(rings, offset(19, 10), 'E'), 'E', reason: 'and back 1 m: still E');
    });

    test('leaves when outside every plot', () {
      expect(confirmedInside(rings, offset(10, 25), 'W'), isNull);
    });
  });

  test('a concave plot puts its marker on its own ground, not on the gap', () {
    // An L: 30 x 30 with the north-east 20 x 20 cut away. Its vertex average
    // lies in the cut-out.
    final l = [offset(0, 0), offset(30, 0), offset(30, 10), offset(10, 10), offset(10, 30), offset(0, 30), offset(0, 0)];
    final average = offset(13.3, 13.3);
    expect(insideRing(l, average), isFalse);
    final p = interiorPoint(l, average);
    expect(insideRing(l, p), isTrue);
    expect(distanceToRingM(l, p), greaterThan(3.0), reason: 'well inside, not on the edge');
    // A convex plot keeps its centroid.
    expect(interiorPoint(square, offset(20, 20)), offset(20, 20));
  });
}
