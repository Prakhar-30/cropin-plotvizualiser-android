import 'dart:math' as math;

/// Steps, from the accelerometer, as they happen.
///
/// This exists because of a field observation: walking towards a plot indoors,
/// the boundary receded in front of the agent and finished metres from where
/// it belonged. Under a roof - or under trees, or between buildings - GNSS
/// Doppler speed reads near zero whatever the agent is doing, so the position
/// filter took them for standing still, held its estimate, and let the drawn
/// position creep at its stationary slew rate. The camera was moving through
/// the room; the app believed it was not; the geometry was redrawn as if the
/// whole plot had walked away.
///
/// Counting steps is the standard remedy (pedestrian dead reckoning: step
/// detection, step length, heading). Steps are a motion cue the receiver
/// cannot give indoors, and they arrive within a fraction of a second rather
/// than at the next 1 Hz fix.
///
/// Peak-valley detection on the low-passed magnitude of the accelerometer,
/// because the magnitude does not depend on how the phone is held. One stride
/// of a hand-held phone is a peak above gravity at heel strike followed by a
/// valley below it; a step is counted when the valley completes it, about a
/// quarter of a stride after the footfall.
///
/// Implemented here rather than read from Android's step detector sensor: that
/// sensor needs the ACTIVITY_RECOGNITION runtime permission - one more prompt
/// for the agent and one more line in a host app's manifest - and it batches
/// and delays its events on many handsets, which defeats the point.
class StepDetector {
  StepDetector({
    this.peakThresholdMps2 = 1.0,
    this.valleyThresholdMps2 = 0.6,
    this.minAmplitudeMps2 = 1.8,
    this.minStepIntervalMs = 260,
    this.cutoffHz = 3.0,
    this.gravityTauS = 2.0,
  });

  /// How far above the gravity estimate a peak must rise.
  final double peakThresholdMps2;

  /// How far below it the valley must fall.
  final double valleyThresholdMps2;

  /// Peak-to-valley swing below which a candidate is a hand movement, not a step.
  final double minAmplitudeMps2;

  /// Faster than this is running or shaking, not walking - roughly 3.8 steps a
  /// second.
  final int minStepIntervalMs;

  /// The low-pass. Walking cadence is 1.5-2.5 Hz; above 3 Hz is hand tremor and
  /// sensor noise.
  final double cutoffHz;

  /// Time constant of the gravity estimate. Long against a stride so steps do
  /// not drag it, short enough to absorb a sensor's bias within seconds.
  final double gravityTauS;

  double? _filtered;
  double? _gravity;
  int _lastSampleMs = 0;
  bool _abovePeak = false;
  double _peak = 0.0;
  bool _seekingValley = false;
  double _valley = 0.0;
  int _lastStepMs = 0;

  /// Folds in one accelerometer sample - the magnitude, gravity included, in
  /// m/s² - and returns the step it completed, or null.
  DetectedStep? add(double magnitudeMps2, int timestampMs) {
    final previous = _filtered;
    final dtS = (timestampMs - _lastSampleMs) / 1000.0;
    _lastSampleMs = timestampMs;
    if (previous == null || dtS <= 0 || dtS > 0.5) {
      // First sample, or a gap long enough that the stride state is stale.
      _filtered = magnitudeMps2;
      _gravity ??= magnitudeMps2;
      _abovePeak = false;
      _seekingValley = false;
      return null;
    }

    final alpha = 1.0 - math.exp(-2.0 * math.pi * cutoffHz * dtS);
    final y = previous + alpha * (magnitudeMps2 - previous);
    _filtered = y;
    final g = _gravity! + (1.0 - math.exp(-dtS / gravityTauS)) * (y - _gravity!);
    _gravity = g;

    if (y > g + peakThresholdMps2) {
      // Rising into, or riding, a peak. A new peak abandons any valley search:
      // two peaks without a valley between them were one bumpy step.
      if (!_abovePeak) {
        _abovePeak = true;
        _peak = y;
        _seekingValley = false;
      } else if (y > _peak) {
        _peak = y;
      }
      return null;
    }

    if (_abovePeak && y < g) {
      _abovePeak = false;
      _seekingValley = true;
      _valley = y;
      return null;
    }

    if (_seekingValley) {
      if (y < _valley) _valley = y;
      // The valley completes once the signal climbs back to gravity.
      if (y >= g) {
        _seekingValley = false;
        final deepEnough = _valley < g - valleyThresholdMps2;
        final swing = _peak - _valley;
        final spaced = _lastStepMs == 0 || timestampMs - _lastStepMs >= minStepIntervalMs;
        if (deepEnough && swing >= minAmplitudeMps2 && spaced) {
          _lastStepMs = timestampMs;
          return DetectedStep(timestampMs: timestampMs, swingMps2: swing);
        }
      }
    }
    return null;
  }

  /// When the last step was counted, or 0 if none has been.
  int get lastStepMs => _lastStepMs;

  void reset() {
    _filtered = null;
    _gravity = null;
    _lastSampleMs = 0;
    _abovePeak = false;
    _seekingValley = false;
    _lastStepMs = 0;
  }
}

class DetectedStep {
  const DetectedStep({required this.timestampMs, required this.swingMps2});

  final int timestampMs;

  /// Peak-to-valley acceleration of the stride, which the step length model
  /// reads: longer, faster strides hit harder.
  final double swingMps2;
}

/// Step length by Weinberg's model, `L = K · (a_max − a_min)^¼`, with K
/// calibrated against GNSS whenever GNSS is good enough to calibrate against.
///
/// Weinberg (Analog Devices AN-602, 2002) is the usual choice for hand-held
/// phones: one parameter, and in published comparisons of step length models it
/// is among the most accurate and the least scattered. Its weakness is that K
/// is personal - leg length, gait, how the phone is held - so a fixed K is
/// wrong for most people by ten to twenty percent. That error is a scale error
/// on every step, so it is what calibration targets.
class StepLengthModel {
  StepLengthModel({this.k = defaultK});

  /// Gives 0.65-0.75 m for an ordinary walk, whose swing is 4-7 m/s².
  static const double defaultK = 0.45;

  /// K is held inside this band whatever a calibration says, so one bad GNSS
  /// segment cannot turn every step into a stride of a metre and a half.
  static const double minK = 0.30;
  static const double maxK = 0.65;

  /// Weight of each new calibration. A third: a few walks converge it, one
  /// misleading walk cannot flip it.
  static const double _learningRate = 0.3;

  double k;

  double lengthM(double swingMps2) => k * math.pow(math.max(swingMps2, 0.0), 0.25).toDouble();

  /// The Weinberg factor of one step - its length divided by K.
  static double factor(double swingMps2) => math.pow(math.max(swingMps2, 0.0), 0.25).toDouble();

  /// Pulls K towards the value that makes the steps of a walk add up to the
  /// distance GNSS measured over it.
  ///
  /// [gnssDisplacementM] is the straight-line distance between the walk's end
  /// fixes; [stepDisplacementFactors] is the length of the vector sum of each
  /// step's Weinberg factor along its heading. Comparing the two as vectors
  /// rather than as path lengths is what lets a walk with a turn in it still
  /// calibrate: both sides shrink by the same geometry.
  void calibrate({required double gnssDisplacementM, required double stepDisplacementFactors}) {
    if (stepDisplacementFactors <= 0) return;
    final observed = (gnssDisplacementM / stepDisplacementFactors).clamp(minK, maxK).toDouble();
    k += _learningRate * (observed - k);
  }
}
