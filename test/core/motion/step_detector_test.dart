import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/motion/step_detector.dart';

/// Synthetic accelerometer magnitude at 50 Hz: gravity plus a walking stride
/// (one cycle per step) of the given amplitude, plus seeded noise.
List<(double, int)> walk({
  required double seconds,
  double cadenceHz = 1.8,
  double amplitude = 2.5,
  double noise = 0.2,
  int seed = 1,
  int startMs = 1000,
}) {
  final random = math.Random(seed);
  final samples = <(double, int)>[];
  for (var i = 0; i < (seconds * 50).round(); i++) {
    final t = i / 50.0;
    final a = 9.81 + amplitude * math.sin(2 * math.pi * cadenceHz * t) + (random.nextDouble() - 0.5) * 2 * noise;
    samples.add((a, startMs + i * 20));
  }
  return samples;
}

List<DetectedStep> run(StepDetector detector, List<(double, int)> samples) => [
      for (final (a, t) in samples)
        if (detector.add(a, t) case final step?) step,
    ];

void main() {
  test('a steady walk is counted step for step', () {
    // 10 s at 1.8 steps a second is 18 steps. The first stride is spent
    // settling the filter, so one fewer is acceptable; more is not.
    final steps = run(StepDetector(), walk(seconds: 10));
    expect(steps.length, inInclusiveRange(16, 18));
  });

  test('a phone held still counts nothing', () {
    final steps = run(StepDetector(), walk(seconds: 20, amplitude: 0.0, noise: 0.35));
    expect(steps, isEmpty);
  });

  test('a gentle hand sway is not a walk', () {
    // Swinging the phone while looking around: real motion, but well under a
    // footfall's swing.
    final steps = run(StepDetector(), walk(seconds: 10, cadenceHz: 1.0, amplitude: 0.7));
    expect(steps, isEmpty);
  });

  test('steps are never closer together than the minimum interval', () {
    final steps = run(StepDetector(), walk(seconds: 10, cadenceHz: 2.4));
    for (var i = 1; i < steps.length; i++) {
      expect(steps[i].timestampMs - steps[i - 1].timestampMs, greaterThanOrEqualTo(260));
    }
  });

  test('a harder stride reports a bigger swing, and so a longer step', () {
    final soft = run(StepDetector(), walk(seconds: 6, amplitude: 1.8, noise: 0)).last;
    final hard = run(StepDetector(), walk(seconds: 6, amplitude: 3.5, noise: 0)).last;
    final model = StepLengthModel();
    expect(model.lengthM(hard.swingMps2), greaterThan(model.lengthM(soft.swingMps2)));
  });

  test('an ordinary walk comes out at an ordinary step length', () {
    final step = run(StepDetector(), walk(seconds: 6, noise: 0)).last;
    expect(StepLengthModel().lengthM(step.swingMps2), inInclusiveRange(0.55, 0.85));
  });

  test('calibration moves K towards the observed value, and stays in bounds', () {
    final model = StepLengthModel();
    // Steps whose factors add to 50 over a 30 m walk imply K = 0.6.
    model.calibrate(gnssDisplacementM: 30, stepDisplacementFactors: 50);
    expect(model.k, closeTo(0.45 + 0.3 * (0.6 - 0.45), 1e-9));

    // A wildly wrong walk is clamped, not believed.
    for (var i = 0; i < 20; i++) {
      model.calibrate(gnssDisplacementM: 300, stepDisplacementFactors: 50);
    }
    expect(model.k, lessThanOrEqualTo(StepLengthModel.maxK));
  });
}
