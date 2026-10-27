import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/polygon_geometry.dart';
import 'package:plot_finder/core/math_util.dart';

void main() {
  /// A 100 m square with its south-west corner at the frame origin.
  const square = [
    Enu(0.0, 0.0),
    Enu(100.0, 0.0),
    Enu(100.0, 100.0),
    Enu(0.0, 100.0),
    Enu(0.0, 0.0), // closing repeat, as GeoJSON delivers it
  ];

  test('the closing repeat is dropped', () {
    expect(openRing(square).length, 4);
    expect(openRing(const [Enu(0.0, 0.0), Enu(1.0, 0.0), Enu(0.0, 1.0)]).length, 3);
  });

  test('distance to a segment clamps at the endpoints', () {
    const a = Enu(0.0, 0.0);
    const b = Enu(100.0, 0.0);
    // Perpendicular from above the middle.
    expect(distanceToSegmentM(const Enu(50.0, 20.0), a, b), closeTo(20.0, 1e-9));
    // Past the end, so the answer is the distance to the endpoint itself.
    expect(distanceToSegmentM(const Enu(130.0, 0.0), a, b), closeTo(30.0, 1e-9));
    expect(distanceToSegmentM(const Enu(130.0, 40.0), a, b), closeTo(hypot(30.0, 40.0), 1e-9));
  });

  test('a degenerate edge collapses to a point', () {
    const a = Enu(10.0, 10.0);
    expect(distanceToSegmentM(const Enu(15.0, 10.0), a, a), closeTo(5.0, 1e-9));
  });

  test('nearest edge is measured from outside', () {
    expect(distanceToNearestEdgeM(square, const Enu(50.0, -20.0)), closeTo(20.0, 1e-9));
    expect(distanceToNearestEdgeM(square, const Enu(120.0, 50.0)), closeTo(20.0, 1e-9));
  });

  test('standing on the boundary reads zero', () {
    expect(distanceToNearestEdgeM(square, const Enu(50.0, 0.0)), closeTo(0.0, 1e-9));
    expect(distanceToNearestEdgeM(square, const Enu(0.0, 0.0)), closeTo(0.0, 1e-9));
  });

  test('from inside, the nearest edge is the closest wall', () {
    // 10 m in from the south edge of a 100 m square.
    expect(distanceToNearestEdgeM(square, const Enu(50.0, 10.0)), closeTo(10.0, 1e-9));
    // Dead centre is 50 m from all four.
    expect(distanceToNearestEdgeM(square, const Enu(50.0, 50.0)), closeTo(50.0, 1e-9));
  });

  test('near a corner the distance is the diagonal to the corner', () {
    expect(distanceToNearestEdgeM(square, const Enu(-20.0, -20.0)), closeTo(hypot(20.0, 20.0), 1e-9));
  });

  test('an elongated plot switches on the edge, not the centroid', () {
    // 400 m x 40 m strip. The agent stands 5 m off its long south edge,
    // level with one end - near mode by any honest reading.
    const strip = [
      Enu(0.0, 0.0),
      Enu(400.0, 0.0),
      Enu(400.0, 40.0),
      Enu(0.0, 40.0),
      Enu(0.0, 0.0),
    ];
    const agent = Enu(20.0, -5.0);

    final edgeDistance = distanceToNearestEdgeM(strip, agent);
    const centroid = Enu(200.0, 20.0);
    final centroidDistance = hypot(centroid.east - agent.east, centroid.north - agent.north);

    expect(edgeDistance, closeTo(5.0, 1e-9));
    expect(centroidDistance, greaterThan(30.0),
        reason: 'centroid distance should be far outside near mode, was $centroidDistance');
    expect(edgeDistance, lessThan(30.0));
  });

  test('an empty ring is infinitely far away', () {
    expect(distanceToNearestEdgeM(const [], const Enu(0.0, 0.0)), double.infinity);
  });
}
