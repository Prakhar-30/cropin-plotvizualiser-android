import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/math_util.dart';
import 'package:plot_finder/core/motion/step_calibrator.dart';
import 'package:plot_finder/core/motion/step_detector.dart';

void main() {
  const start = LatLng(12.7862, 76.7201);
  final metresPerDegLng = math.cos(toRadians(start.lat)) * metresPerDegLngAtEquator;
  LatLng north(double m) => LatLng(start.lat + m / metresPerDegLat, start.lng);
  LatLng east(double m) => LatLng(start.lat, start.lng + m / metresPerDegLng);

  // A swing of 16 m/s² has a Weinberg factor of exactly 2.
  const step = DetectedStep(timestampMs: 0, swingMps2: 16);

  test('a straight walk with good fixes calibrates the step length', () {
    final model = StepLengthModel();
    final calibrator = StepCalibrator(model);
    calibrator.onFix(start, 4);
    for (var i = 0; i < 30; i++) {
      calibrator.onStep(step, 0);
    }
    // 30 steps of factor 2 north, and GNSS says 36 m: K should head for 0.6.
    expect(calibrator.onFix(north(36), 4), isTrue);
    expect(model.k, greaterThan(StepLengthModel.defaultK));
    expect(calibrator.calibrations, 1);
  });

  test('a poor fix abandons the walk instead of calibrating on it', () {
    final model = StepLengthModel();
    final calibrator = StepCalibrator(model);
    calibrator.onFix(start, 4);
    for (var i = 0; i < 30; i++) {
      calibrator.onStep(step, 0);
    }
    expect(calibrator.onFix(north(20), 15), isFalse);
    expect(calibrator.onFix(north(36), 4), isFalse, reason: 'the walk restarted at this fix');
    expect(model.k, StepLengthModel.defaultK);
  });

  test('steps and GNSS disagreeing on direction do not calibrate', () {
    // The heading was wrong: the steps went north, the receiver went east.
    final model = StepLengthModel();
    final calibrator = StepCalibrator(model);
    calibrator.onFix(start, 4);
    for (var i = 0; i < 30; i++) {
      calibrator.onStep(step, 0);
    }
    expect(calibrator.onFix(east(36), 4), isFalse);
    expect(model.k, StepLengthModel.defaultK);
  });
}
