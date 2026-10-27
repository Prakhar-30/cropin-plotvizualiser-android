import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';

/// Every expected value below is computed by hand from the documented model, not
/// by calling the code under test back on itself.
///
/// Working latitude is 12.7862 N (the seeded plots in Mandya district), where
/// cos(12.7862 deg) = 0.9752027, so one degree of longitude is
/// 0.9752027 * 111320 = 108559.6 m and one degree of latitude is 110540 m.
void main() {
  const origin = LatLng(12.7862, 76.7201);
  final frame = EnuFrame(origin);

  test('a thousandth of a degree north is 110.54 metres', () {
    final enu = frame.toEnu(LatLng(origin.lat + 0.001, origin.lng));
    expect(enu.north, closeTo(110.540, 0.001));
    expect(enu.east, closeTo(0.0, 1e-9));
  });

  test('a thousandth of a degree east is shortened by the cosine of the latitude', () {
    final enu = frame.toEnu(LatLng(origin.lat, origin.lng + 0.001));
    // 0.001 * 0.9752027 * 111320 = 108.5596 m, not the equatorial 111.32 m.
    expect(enu.east, closeTo(108.5596, 0.002));
    expect(enu.north, closeTo(0.0, 1e-9));
  });

  test('south and west come out negative', () {
    final enu = frame.toEnu(LatLng(origin.lat - 0.002, origin.lng - 0.002));
    expect(enu.north, closeTo(-221.080, 0.002));
    expect(enu.east, closeTo(-217.1191, 0.004));
  });

  test('converting to metres and back returns the original degrees', () {
    const point = LatLng(12.78931, 76.72447);
    final roundTripped = frame.toLatLng(frame.toEnu(point));
    expect(roundTripped.lat, closeTo(point.lat, 1e-12));
    expect(roundTripped.lng, closeTo(point.lng, 1e-12));
  });

  test('the origin is at the origin', () {
    final enu = frame.toEnu(origin);
    expect(enu.east, closeTo(0.0, 1e-12));
    expect(enu.north, closeTo(0.0, 1e-12));
    expect(enu.up, closeTo(0.0, 1e-12));
  });

  test('re-anchors only after fifty metres of walking', () {
    // 0.0004 deg of latitude is 44.2 m; 0.0006 deg is 66.3 m.
    expect(frame.needsReanchor(LatLng(origin.lat + 0.0004, origin.lng)), isFalse);
    expect(frame.needsReanchor(LatLng(origin.lat + 0.0006, origin.lng)), isTrue);
  });

  test('ground range ignores height but range does not', () {
    const point = Enu(3.0, 4.0, 12.0);
    expect(point.groundRange, closeTo(5.0, 1e-12));
    expect(point.range, closeTo(13.0, 1e-12));
  });

  test('bearings are compass bearings, clockwise from north', () {
    expect(const Enu(0.0, 100.0).bearingDeg, closeTo(0.0, 1e-9));
    expect(const Enu(100.0, 0.0).bearingDeg, closeTo(90.0, 1e-9));
    expect(const Enu(0.0, -100.0).bearingDeg, closeTo(180.0, 1e-9));
    expect(const Enu(-100.0, 0.0).bearingDeg, closeTo(270.0, 1e-9));
    expect(const Enu(100.0, 100.0).bearingDeg, closeTo(45.0, 1e-9));
    expect(const Enu(-100.0, 100.0).bearingDeg, closeTo(315.0, 1e-9));
  });

  test('bearing between two positions goes through the metric frame', () {
    // Due east of the origin must read 90 deg even though the degree deltas
    // differ in size - this is exactly what computing in raw degrees breaks.
    final east = LatLng(origin.lat, origin.lng + 0.002);
    expect(bearingDeg(origin, east), closeTo(90.0, 1e-9));
    expect(distanceM(origin, east), closeTo(217.1191, 0.01));

    final north = LatLng(origin.lat + 0.002, origin.lng);
    expect(bearingDeg(origin, north), closeTo(0.0, 1e-9));
    expect(distanceM(origin, north), closeTo(221.080, 0.01));
  });

  test('equal metric offsets give a true forty five degrees', () {
    // 0.001 deg north is 110.540 m; the matching easting is 110.540 m, which
    // is 110.540 / 108559.6 = 0.00101824 deg of longitude.
    final target = LatLng(origin.lat + 0.001, origin.lng + 0.00101824);
    expect(bearingDeg(origin, target), closeTo(45.0, 0.001));
  });

  test('angle difference takes the short way across north', () {
    expect(angleDifferenceDeg(359.0, 1.0), closeTo(2.0, 1e-9));
    expect(angleDifferenceDeg(1.0, 359.0), closeTo(-2.0, 1e-9));
    expect(normalizeDeg(-10.0), closeTo(350.0, 1e-9));
    expect(normalizeDeg(725.0), closeTo(5.0, 1e-9));
  });
}
