import 'dart:math' as math;

import '../math_util.dart';

/// Conversion between WGS84 degrees and a local East-North-Up metric frame.
///
/// Every piece of geometry in this app happens in metres. Degrees are converted
/// once, at the edge, and never used for distance, bearing or projection - a
/// degree of longitude is 108.5 m here and 111.3 m at the equator, so anything
/// computed in raw degrees is wrong by a different amount in each direction.
///
/// The equirectangular approximation below is accurate to well under a metre at
/// the few-hundred-metre ranges this app works over, which is far inside the
/// GNSS error it is drawn against.

const double metresPerDegLat = 110540.0;
const double metresPerDegLngAtEquator = 111320.0;

/// Re-anchor the frame once the agent has walked this far from the origin.
const double reanchorDistanceM = 50.0;

/// Plot geometry is drawn on the ground, this far below the phone.
const double eyeHeightM = 1.6;

class LatLng {
  const LatLng(this.lat, this.lng);

  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) =>
      other is LatLng && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'LatLng($lat, $lng)';
}

/// A point in the local metric frame. `up` is metres above the origin.
class Enu {
  const Enu(this.east, this.north, [this.up = 0.0]);

  final double east;
  final double north;
  final double up;

  /// Straight-line distance from the frame origin.
  double get range => math.sqrt(east * east + north * north + up * up);

  /// Distance ignoring height, which is what "how far do I walk" means.
  double get groundRange => hypot(east, north);

  /// Compass bearing from the origin to this point, degrees clockwise from north.
  double get bearingDeg => normalizeDeg(toDegrees(math.atan2(east, north)));

  @override
  bool operator ==(Object other) =>
      other is Enu && other.east == east && other.north == north && other.up == up;

  @override
  int get hashCode => Object.hash(east, north, up);

  @override
  String toString() => 'Enu($east, $north, $up)';
}

/// A local frame anchored at one GNSS fix.
///
/// The frame is immutable: moving the anchor means building a new one, which
/// makes it impossible to convert two points against different origins by
/// accident.
class EnuFrame {
  EnuFrame(this.origin)
      // Metres per degree of longitude shrinks with the cosine of the latitude.
      : _metresPerDegLng = math.cos(toRadians(origin.lat)) * metresPerDegLngAtEquator;

  final LatLng origin;
  final double _metresPerDegLng;

  Enu toEnu(LatLng point, [double up = 0.0]) => Enu(
        (point.lng - origin.lng) * _metresPerDegLng,
        (point.lat - origin.lat) * metresPerDegLat,
        up,
      );

  LatLng toLatLng(Enu point) => LatLng(
        origin.lat + point.north / metresPerDegLat,
        origin.lng + point.east / _metresPerDegLng,
      );

  /// Ground distance from the anchor, in metres.
  double distanceFromOrigin(LatLng point) => toEnu(point).groundRange;

  /// True once the agent has walked far enough that the approximation, and the
  /// accumulated rounding in it, deserve a fresh anchor.
  bool needsReanchor(LatLng current) => distanceFromOrigin(current) > reanchorDistanceM;
}

/// Compass bearing from one position to another, degrees clockwise from north.
///
/// Computed through the same local metric frame the overlay uses, so a landmark
/// snap and the rendered geometry can never disagree about which way a feature is.
double bearingDeg(LatLng from, LatLng to) => EnuFrame(from).toEnu(to).bearingDeg;

/// Ground distance between two positions, in metres.
double distanceM(LatLng from, LatLng to) => EnuFrame(from).toEnu(to).groundRange;

/// Folds any angle into `[0, 360)`.
///
/// Dart's `%` already returns a non-negative result for a positive divisor,
/// unlike Kotlin's; the explicit fold is kept so the intent does not depend on
/// knowing that.
double normalizeDeg(double deg) {
  final wrapped = deg % 360.0;
  return wrapped < 0 ? wrapped + 360.0 : wrapped;
}

/// Shortest signed turn from `a` to `b`, in `(-180, 180]`.
///
/// Every heading comparison in the app goes through this. Subtracting headings
/// directly makes 359 and 1 look 358 degrees apart instead of 2, which would
/// reject a perfectly straight walk that happens to cross north.
double angleDifferenceDeg(double a, double b) {
  final diff = normalizeDeg(b - a);
  return diff > 180.0 ? diff - 360.0 : diff;
}

class BearingStatistics {
  const BearingStatistics(this.meanDeg, this.spreadDeg);

  final double meanDeg;
  final double spreadDeg;
}

/// Circular mean of a set of bearings, and how tightly they cluster.
///
/// Returned spread is the mean absolute deviation from that mean, in degrees;
/// the straight-segment detector thresholds on it.
BearingStatistics? bearingStatistics(List<double> bearings) {
  if (bearings.isEmpty) return null;
  var sumSin = 0.0;
  var sumCos = 0.0;
  for (final b in bearings) {
    final r = toRadians(b);
    sumSin += math.sin(r);
    sumCos += math.cos(r);
  }
  final mean = normalizeDeg(toDegrees(math.atan2(sumSin, sumCos)));
  var total = 0.0;
  for (final b in bearings) {
    total += angleDifferenceDeg(mean, b).abs();
  }
  return BearingStatistics(mean, total / bearings.length);
}
