import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/heading/course_over_ground_detector.dart';
import 'package:plot_finder/core/math_util.dart';

void main() {
  const start = LatLng(12.7862, 76.7201);
  final metresPerDegLng = math.cos(toRadians(start.lat)) * 111320.0;

  /// Walks `count` fixes of `stepM` each along `bearing`, one per second.
  (double?, LatLng) walk(
    CourseOverGroundDetector detector, {
    required double bearingDeg,
    required int count,
    double stepM = 5.0,
    int startAtMs = 0,
    LatLng from = start,
    double speedMps = 1.3,
    double accuracyM = 6.0,
    double Function(int)? bearingNoise,
  }) {
    var position = from;
    double? result;
    for (var i = 0; i < count; i++) {
      final r = toRadians(bearingDeg);
      position = LatLng(
        position.lat + (stepM * math.cos(r)) / metresPerDegLat,
        position.lng + (stepM * math.sin(r)) / metresPerDegLng,
      );
      final emitted = detector.add(LocationSample(
        position: position,
        bearingDeg: normalizeDeg(bearingDeg + (bearingNoise?.call(i) ?? 0.0)),
        speedMps: speedMps,
        accuracyM: accuracyM,
        timestampMs: startAtMs + (i + 1) * 1000,
      ));
      if (emitted != null) result = emitted;
    }
    return (result, position);
  }

  test('a straight walk past twenty metres locks a heading', () {
    final detector = CourseOverGroundDetector();
    // Six fixes 5 m apart: 25 m of ground, clear of both the distance and
    // the sample-count bars.
    final (heading, _) = walk(detector, bearingDeg: 42.0, count: 6);
    expect(heading, isNotNull);
    expect(heading!, closeTo(42.0, 0.001));
  });

  test('fifteen metres is not yet enough ground', () {
    final detector = CourseOverGroundDetector();
    // Four fixes 5 m apart is 15 m of travel - three gaps, not four.
    expect(walk(detector, bearingDeg: 42.0, count: 4).$1, isNull);
    expect(detector.segmentDistanceM, closeTo(15.0, 0.05));
  });

  test('a short walk locks nothing', () {
    final detector = CourseOverGroundDetector();
    expect(walk(detector, bearingDeg: 42.0, count: 3).$1, isNull);
  });

  test('standing still discards the segment', () {
    final detector = CourseOverGroundDetector();
    walk(detector, bearingDeg: 42.0, count: 3);
    // A stationary fix: no bearing, no speed.
    expect(
      detector.add(const LocationSample(
        position: start,
        bearingDeg: null,
        speedMps: 0.0,
        accuracyM: 6.0,
        timestampMs: 4000,
      )),
      isNull,
    );
    expect(detector.sampleCount, 0);
    expect(detector.segmentDistanceM, closeTo(0.0, 1e-9));
  });

  test('a slow shuffle is not a walk', () {
    final detector = CourseOverGroundDetector();
    expect(walk(detector, bearingDeg: 42.0, count: 8, speedMps: 0.4).$1, isNull);
  });

  test('a poor fix is dropped rather than averaged in', () {
    final detector = CourseOverGroundDetector();
    expect(walk(detector, bearingDeg: 42.0, count: 8, accuracyM: 40.0).$1, isNull);
  });

  test('turning mid-window throws the window away', () {
    final detector = CourseOverGroundDetector();
    // Three steps north, then three steps east: 20 m covered, but the mean
    // of those bearings points north-east, at neither leg of the walk.
    final (_, corner) = walk(detector, bearingDeg: 0.0, count: 3);
    final (heading, _) = walk(detector, bearingDeg: 90.0, count: 3, startAtMs: 3000, from: corner);
    expect(heading, isNull, reason: 'a turn must not produce a confident heading');
  });

  test('small wobble in a straight walk is tolerated', () {
    final detector = CourseOverGroundDetector();
    // Plus or minus 4 deg of GNSS bearing noise: mean deviation ~4 deg, under
    // the 8 deg bar, so this is still a straight line.
    final (heading, _) = walk(detector,
        bearingDeg: 300.0, count: 6, bearingNoise: (i) => i.isEven ? 4.0 : -4.0);
    expect(heading, isNotNull);
    expect(heading!, closeTo(300.0, 1.0));
  });

  test('a walk across north averages correctly instead of through south', () {
    final detector = CourseOverGroundDetector();
    // Bearings alternating 358 and 2 must average to 0, not to 180.
    final (heading, _) = walk(detector,
        bearingDeg: 0.0, count: 6, bearingNoise: (i) => i.isEven ? -2.0 : 2.0);
    expect(heading, isNotNull);
    expect(angleDifferenceDeg(0.0, heading!), closeTo(0.0, 0.5));
  });

  test('a long gap between fixes breaks the segment', () {
    final detector = CourseOverGroundDetector();
    walk(detector, bearingDeg: 42.0, count: 3);
    final far = LatLng(start.lat + 0.0005, start.lng);
    final emitted = detector.add(LocationSample(
      position: far,
      bearingDeg: 42.0,
      speedMps: 1.3,
      accuracyM: 6.0,
      timestampMs: 60000,
    ));
    expect(emitted, isNull);
    expect(detector.sampleCount, 1, reason: 'window restarts from the newest fix');
  });

  test('the detector resets after emitting so the next segment starts clean', () {
    final detector = CourseOverGroundDetector();
    final (heading, _) = walk(detector, bearingDeg: 42.0, count: 6);
    expect(heading, isNotNull);
    expect(detector.sampleCount, 0);
    expect(detector.segmentDistanceM, closeTo(0.0, 1e-9));
  });
}
