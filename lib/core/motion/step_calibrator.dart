import 'dart:math' as math;

import '../geo/enu.dart';
import '../math_util.dart';
import 'step_detector.dart';

/// Learns the agent's step length from GNSS, while GNSS is good.
///
/// Outdoors in open fields the receiver is accurate to a few metres, which is
/// poor for a single step and excellent over thirty. So the steps of a walk are
/// added up as a vector - each step's Weinberg factor along the heading it was
/// taken on - and compared with the straight-line distance GNSS measured
/// between the walk's two ends. The ratio is the K that would have made the
/// steps add up, and [StepLengthModel.calibrate] moves towards it.
///
/// Calibrated outdoors, the step length then carries the agent through exactly
/// the places GNSS cannot: under a roof, under trees, beside a wall.
///
/// A walk is abandoned rather than used when:
///  - any fix in it is worse than [maxAccuracyM], because the endpoints are the
///    measurement;
///  - the steps and GNSS disagree on direction by more than
///    [maxBearingDisagreementDeg], because then the heading was wrong and the
///    lengths would be compared along different lines.
class StepCalibrator {
  StepCalibrator(
    this.model, {
    this.maxAccuracyM = 6.0,
    this.minDistanceM = 30.0,
    this.minSteps = 25,
    this.maxBearingDisagreementDeg = 25.0,
  });

  final StepLengthModel model;
  final double maxAccuracyM;
  final double minDistanceM;
  final int minSteps;
  final double maxBearingDisagreementDeg;

  LatLng? _start;
  double _east = 0.0;
  double _north = 0.0;
  int _steps = 0;

  /// How many walks have adjusted the model, for telemetry.
  int calibrations = 0;

  void onStep(DetectedStep step, double headingDeg) {
    if (_start == null) return;
    final f = StepLengthModel.factor(step.swingMps2);
    final h = toRadians(headingDeg);
    _east += f * math.sin(h);
    _north += f * math.cos(h);
    _steps++;
  }

  /// Offers a raw GNSS fix. Returns true when it completed a walk and the
  /// model was adjusted.
  bool onFix(LatLng position, double accuracyM) {
    if (!accuracyM.isFinite || accuracyM > maxAccuracyM) {
      _start = null;
      return false;
    }
    final start = _start;
    if (start == null) {
      _restart(position);
      return false;
    }
    final gnss = distanceM(start, position);
    if (gnss < minDistanceM || _steps < minSteps) return false;

    final stepFactors = hypot(_east, _north);
    final stepBearing = normalizeDeg(toDegrees(math.atan2(_east, _north)));
    final agree = angleDifferenceDeg(bearingDeg(start, position), stepBearing).abs() <= maxBearingDisagreementDeg;
    if (agree) {
      model.calibrate(gnssDisplacementM: gnss, stepDisplacementFactors: stepFactors);
      calibrations++;
    }
    _restart(position);
    return agree;
  }

  void _restart(LatLng at) {
    _start = at;
    _east = 0.0;
    _north = 0.0;
    _steps = 0;
  }
}
