import 'dart:math' as math;

import '../geo/enu.dart';
import '../math_util.dart';

/// Finds true north from the agent's own walk, with no button to press.
///
/// ARCore tracks the shape of the walk exactly but in a frame with an arbitrary
/// yaw; GNSS knows where north is but places each point metres out. Fitting the
/// one onto the other - the rotation that best lays the tracked path over the
/// GNSS fixes taken along it - recovers the yaw. This is the standard
/// initialisation step of visual-inertial-GNSS systems (GVINS, VINS-Fusion's
/// global fusion), here as the closed-form weighted 2-D Procrustes solution.
///
/// Unlike a course-over-ground lock it needs no straight walk: the tracked path
/// supplies the shape, so a winding approach between bunds counts in full. And
/// it improves the further the agent walks, because the lever arm grows while
/// each fix's error stays the same.
///
/// Standing on the access point and saying so adds an [anchor]: one point
/// whose true position is known to a metre. It pins the fit's centre, so every
/// later step away from it - in any direction - refines the yaw.

/// Fixes worse than this are left out: under a roof they are tens of metres
/// out and correlated, and add nothing but bias.
const double maxAlignmentFixAccuracyM = 15.0;

/// A fit worse than this is not offered as a lock.
const double maxAlignmentErrorDeg = 10.0;

/// GNSS errors are correlated over many seconds, so successive 1 Hz fixes are
/// worth far less than independent ones. The variance is inflated by this
/// factor - roughly, five fixes count as one.
const double _fixCorrelation = 5.0;

/// The fit needs the walk to have some extent before it says anything.
const double _minExtentM = 8.0;
const int _minPairs = 6;

/// Floor on the reported error: ARCore's own yaw drift and scale error.
const double _floorErrorDeg = 1.5;

class TrajectoryAlignment {
  const TrajectoryAlignment({required this.yawOffsetDeg, required this.errorDeg, required this.pairs});

  /// True heading minus session heading.
  final double yawOffsetDeg;

  /// One-sigma error of [yawOffsetDeg], degrees.
  final double errorDeg;
  final int pairs;
}

class _Pair {
  const _Pair(this.session, this.truth, this.weight);

  final Enu session;
  final Enu truth;
  final double weight;
}

class TrajectoryAligner {
  TrajectoryAligner({this.maxPairs = 240});

  /// Older pairs are dropped beyond this: the fit then follows the most recent
  /// few minutes, which is also the stretch ARCore's drift has least affected.
  final int maxPairs;

  EnuFrame? _frame;
  final List<_Pair> _pairs = [];
  _Pair? _anchor;

  int get pairCount => _pairs.length + (_anchor == null ? 0 : 1);

  /// One GNSS fix and where ARCore had the camera at that moment.
  void addFix(Enu session, LatLng fix, double accuracyM) {
    if (!accuracyM.isFinite || accuracyM > maxAlignmentFixAccuracyM) return;
    final sigma = math.max(accuracyM, 3.0);
    _pairs.add(_Pair(session, _toTruth(fix), 1.0 / (sigma * sigma)));
    if (_pairs.length > maxPairs) _pairs.removeAt(0);
  }

  /// A point whose true position is known: the agent is standing on it.
  void anchor(Enu session, LatLng point, {double accuracyM = 1.0}) {
    _anchor = _Pair(session, _toTruth(point), 1.0 / (accuracyM * accuracyM));
  }

  /// ARCore lost tracking and may resume in a shifted frame: nothing measured
  /// before can be laid against anything measured after.
  void reset() {
    _pairs.clear();
    _anchor = null;
  }

  Enu _toTruth(LatLng p) => (_frame ??= EnuFrame(p)).toEnu(p);

  TrajectoryAlignment? solve() {
    final all = [..._pairs, if (_anchor case final a?) a];
    if (all.length < _minPairs) return null;

    var weightSum = 0.0;
    var sE = 0.0, sN = 0.0, tE = 0.0, tN = 0.0;
    for (final p in all) {
      weightSum += p.weight;
      sE += p.weight * p.session.east;
      sN += p.weight * p.session.north;
      tE += p.weight * p.truth.east;
      tN += p.weight * p.truth.north;
    }
    sE /= weightSum;
    sN /= weightSum;
    tE /= weightSum;
    tN /= weightSum;

    // Sum of w · truth' · conj(session'), as complex numbers e + i·n. Its
    // argument is the anticlockwise rotation taking session onto truth.
    var re = 0.0, im = 0.0, leverSq = 0.0, extent = 0.0;
    for (final p in all) {
      final pe = p.session.east - sE;
      final pn = p.session.north - sN;
      final ge = p.truth.east - tE;
      final gn = p.truth.north - tN;
      re += p.weight * (ge * pe + gn * pn);
      im += p.weight * (gn * pe - ge * pn);
      leverSq += p.weight * (pe * pe + pn * pn);
      extent = math.max(extent, hypot(pe, pn));
    }
    if (extent < _minExtentM || leverSq <= 0) return null;
    final phi = math.atan2(im, re);

    // How well the fitted rotation explains the fixes, in units of their own
    // claimed accuracy. Fixes that lie about their accuracy widen the error.
    final c = math.cos(phi);
    final s = math.sin(phi);
    var chi = 0.0;
    for (final p in all) {
      final pe = p.session.east - sE;
      final pn = p.session.north - sN;
      final re2 = p.truth.east - tE - (c * pe - s * pn);
      final rn2 = p.truth.north - tN - (s * pe + c * pn);
      chi += p.weight * (re2 * re2 + rn2 * rn2);
    }
    final dof = math.max(1, 2 * all.length - 3);
    final misfit = math.max(1.0, math.sqrt(chi / dof));

    final sigmaRad = math.sqrt(_fixCorrelation / leverSq) * misfit;
    final errorDeg = toDegrees(sigmaRad) + _floorErrorDeg;

    // Anticlockwise by phi is a bearing change of -phi.
    return TrajectoryAlignment(
      yawOffsetDeg: normalizeDeg(-toDegrees(phi)),
      errorDeg: errorDeg,
      pairs: all.length,
    );
  }
}
