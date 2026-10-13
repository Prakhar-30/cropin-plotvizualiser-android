import 'dart:math' as math;

import '../math_util.dart';
import 'linear.dart';

/// Takes the shimmer out of the device orientation.
///
/// This matters more than the position filter did, and for a reason worth
/// stating: position error moves the overlay by a fixed number of metres, but
/// orientation error moves it by an amount that grows with range. At 50 m, one
/// degree of jitter swings a boundary 0.87 m sideways; at 150 m it is 2.6 m.
/// Android's rotation vector wobbles by a degree or two even on a phone lying on
/// a table, so an unfiltered pose is worth several metres of visible movement -
/// far more than the raw GNSS jitter that was fixed first.
///
/// The filter is speed-adaptive, following the 1-euro filter (Casiez, Roussel and
/// Vogel, CHI 2012): smooth hard when the phone is nearly still, and barely at
/// all when it is being deliberately turned. A fixed low-pass cannot win here -
/// set it heavy enough to kill the shimmer and the overlay lags visibly behind
/// the camera when you pan; set it light enough to keep up and the shimmer comes
/// straight back. Tying the time constant to the measured angular rate gets both,
/// because jitter and intent live at different speeds.
///
/// Interpolation is spherical, on quaternions. Averaging rotation matrices
/// element-wise does not produce a rotation - the result is not orthonormal, and
/// it shears the overlay rather than turning it.

/// Time constant while the phone is held still. Heavy: kills the shimmer.
const double _defaultSteadyTauS = 0.65;

/// Time constant while the phone is being turned. Light: catches up fast.
const double _defaultAgileTauS = 0.05;

/// Deviation from the current estimate that counts as fully deliberate motion.
///
/// Adapting on *deviation* rather than on frame-to-frame angular rate is the
/// whole trick, and getting it wrong the first time is instructive: jitter of a
/// degree and a half arriving every 20 ms is an instantaneous rate of 75 deg/s,
/// which looks exactly like a deliberate pan and defeats the filter completely.
///
/// Deviation separates them cleanly instead. Jitter is bounded by its own
/// amplitude no matter how fast it arrives, because the estimate sits at the
/// middle of it. A genuine turn makes the estimate fall behind, and the gap
/// grows until the filter speeds up to close it.
///
/// Raised from 10 degrees after field testing. Walking is not a still phone with
/// noise on top: each footfall pitches and rolls the handset by several degrees,
/// and an arm swing adds more. At 10 degrees that ordinary gait was reading as
/// deliberate motion, so the filter went agile with every step and passed the
/// bounce straight through to the overlay - the boundary jogging along with the
/// walk. A deliberate pan is 60 degrees or more and still clears this bar
/// immediately, so nothing was given up to buy it.
const double _defaultAgileDeviationDeg = 25.0;

/// Time constant for the deviation measure itself.
///
/// Without it the agility term is driven by a single noisy sample and the filter
/// flickers between smooth and responsive from frame to frame - which is its own
/// kind of visible instability.
///
/// Lengthened to 0.3 s alongside the deviation threshold. A footfall disturbance
/// lasts about 0.2 s; at the old 0.15 s the measure could rise far enough within
/// a single step to unlock the filter. Averaging over longer than one step means
/// a step cannot, while a turn - which lasts a second or more - still can.
const double _deviationTauS = 0.30;

/// Longest gap that is still treated as continuous. Beyond it, re-seed.
const double _maxGapS = 0.5;

/// Unit quaternion. `w` is the scalar part.
class Quat {
  const Quat(this.w, this.x, this.y, this.z);

  final double w;
  final double x;
  final double y;
  final double z;

  static const Quat identity = Quat(1.0, 0.0, 0.0, 0.0);

  Quat normalized() {
    final n = math.sqrt(w * w + x * x + y * y + z * z);
    return n < 1e-12 ? identity : Quat(w / n, x / n, y / n, z / n);
  }

  Quat operator -() => Quat(-w, -x, -y, -z);

  double dot(Quat other) => w * other.w + x * other.x + y * other.y + z * other.z;

  Mat3 toMat3() {
    final q = normalized();
    final w = q.w, x = q.x, y = q.y, z = q.z;
    return Mat3(
      1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y), //
      2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x), //
      2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y),
    );
  }

  @override
  String toString() => 'Quat($w, $x, $y, $z)';
}

/// Rotation matrix to quaternion, by Shepperd's method.
///
/// The branch on the largest diagonal term is not an optimisation: the naive
/// `sqrt(trace + 1)` form divides by a value that approaches zero for rotations
/// near 180 degrees, and a phone turned to face behind the agent is exactly that
/// case.
Quat mat3ToQuat(Mat3 m) {
  final trace = m.m00 + m.m11 + m.m22;
  final Quat q;
  if (trace > 0.0) {
    final s = math.sqrt(trace + 1.0) * 2.0;
    q = Quat(0.25 * s, (m.m21 - m.m12) / s, (m.m02 - m.m20) / s, (m.m10 - m.m01) / s);
  } else if (m.m00 > m.m11 && m.m00 > m.m22) {
    final s = math.sqrt(1.0 + m.m00 - m.m11 - m.m22) * 2.0;
    q = Quat((m.m21 - m.m12) / s, 0.25 * s, (m.m01 + m.m10) / s, (m.m02 + m.m20) / s);
  } else if (m.m11 > m.m22) {
    final s = math.sqrt(1.0 + m.m11 - m.m00 - m.m22) * 2.0;
    q = Quat((m.m02 - m.m20) / s, (m.m01 + m.m10) / s, 0.25 * s, (m.m12 + m.m21) / s);
  } else {
    final s = math.sqrt(1.0 + m.m22 - m.m00 - m.m11) * 2.0;
    q = Quat((m.m10 - m.m01) / s, (m.m02 + m.m20) / s, (m.m12 + m.m21) / s, 0.25 * s);
  }
  return q.normalized();
}

extension Mat3ToQuat on Mat3 {
  Quat toQuat() => mat3ToQuat(this);
}

/// Angle between two orientations, in degrees.
double angleBetweenDeg(Quat a, Quat b) {
  final d = clampDouble(a.normalized().dot(b.normalized()).abs(), -1.0, 1.0);
  return toDegrees(2.0 * math.acos(d));
}

/// Spherical linear interpolation, taking the shorter arc.
///
/// `q` and `-q` are the same rotation, so without the sign flip an interpolation
/// can take the long way round and spin the overlay through most of a circle to
/// reach an orientation a fraction of a degree away.
Quat slerp(Quat from, Quat to, double t) {
  final a = from.normalized();
  var b = to.normalized();
  var cosine = a.dot(b);
  if (cosine < 0.0) {
    b = -b;
    cosine = -cosine;
  }

  // Nearly parallel: sin(theta) underflows, so interpolate linearly instead.
  if (cosine > 0.9995) {
    return Quat(
      a.w + t * (b.w - a.w),
      a.x + t * (b.x - a.x),
      a.y + t * (b.y - a.y),
      a.z + t * (b.z - a.z),
    ).normalized();
  }

  final theta = math.acos(clampDouble(cosine, -1.0, 1.0));
  final sinTheta = math.sin(theta);
  final wa = math.sin((1.0 - t) * theta) / sinTheta;
  final wb = math.sin(t * theta) / sinTheta;
  return Quat(
    wa * a.w + wb * b.w,
    wa * a.x + wb * b.x,
    wa * a.y + wb * b.y,
    wa * a.z + wb * b.z,
  ).normalized();
}

class OrientationSmoother {
  OrientationSmoother({
    double steadyTauS = _defaultSteadyTauS,
    double agileTauS = _defaultAgileTauS,
    double agileDeviationDeg = _defaultAgileDeviationDeg,
  })  : _steadyTauS = steadyTauS,
        _agileTauS = agileTauS,
        _agileDeviationDeg = agileDeviationDeg;

  final double _steadyTauS;
  final double _agileTauS;
  final double _agileDeviationDeg;

  Quat? _smoothed;
  int _lastSampleMs = 0;
  double _deviationDeg = 0.0;

  /// How far the raw sample currently sits from the estimate. For telemetry.
  double get trackingErrorDeg => _deviationDeg;

  /// Folds one sensor sample in and returns the orientation to draw with.
  ///
  /// [timestampMs] is monotonic; only differences are used.
  Mat3 update(Mat3 sample, int timestampMs) {
    final target = mat3ToQuat(sample);
    final previous = _smoothed;
    final dtS = (timestampMs - _lastSampleMs) / 1000.0;
    _lastSampleMs = timestampMs;

    // First sample, or a gap long enough that the phone could be anywhere:
    // interpolating across it would drag the overlay through every
    // orientation in between.
    if (previous == null || dtS <= 0.0 || dtS > _maxGapS) {
      _smoothed = target;
      _deviationDeg = 0.0;
      return target.toMat3();
    }

    // Low-pass the deviation before it steers anything, so one noisy sample
    // cannot flip the filter between smooth and responsive.
    final instant = angleBetweenDeg(previous, target);
    final deviationAlpha = 1.0 - math.exp(-dtS / _deviationTauS);
    _deviationDeg += deviationAlpha * (instant - _deviationDeg);

    // Slide between the two time constants by how far behind the estimate is.
    final agility = clampDouble(_deviationDeg / _agileDeviationDeg, 0.0, 1.0);
    final tau = _steadyTauS + (_agileTauS - _steadyTauS) * agility;

    // Exponential smoothing expressed against elapsed time rather than a
    // fixed per-sample weight, so the behaviour does not change when the
    // sensor delivers at a different rate on a different handset.
    final alpha = 1.0 - math.exp(-dtS / tau);

    final next = slerp(previous, target, clampDouble(alpha, 0.0, 1.0));
    _smoothed = next;
    return next.toMat3();
  }

  /// Forgets the current estimate; the next sample is taken as-is.
  void reset() {
    _smoothed = null;
    _lastSampleMs = 0;
    _deviationDeg = 0.0;
  }
}
