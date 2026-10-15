import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/heading/heading_fusion.dart';
import 'package:plot_finder/core/heading/heading_model.dart';

void main() {
  const config = HeadingConfig();

  test('with no fix at all the compass is used and flagged unreliable', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(10.0, 0);
    fusion.onMagneticHeading(95.0, 0);

    final estimate = fusion.estimate(0);
    expect(estimate.headingDeg, closeTo(95.0, 1e-9));
    expect(estimate.source, HeadingSource.magnetometer);
    expect(estimate.confidence, HeadingConfidence.unreliable);
    expect(estimate.expectedErrorDeg, closeTo(20.0, 1e-9));
  });

  test('a walk lock overrides a badly wrong compass', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(200.0, 0);
    fusion.onMagneticHeading(78.0, 0); // 30 deg out, standing by a tractor
    fusion.onFix(48.0, HeadingSource.courseOverGround, 0);

    final estimate = fusion.estimate(0);
    expect(estimate.headingDeg, closeTo(48.0, 1e-9));
    expect(estimate.source, HeadingSource.courseOverGround);
    expect(estimate.confidence, HeadingConfidence.locked);
  });

  test('the gyro carries the locked heading as the phone turns', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(200.0, 0);
    fusion.onFix(48.0, HeadingSource.landmarkSnap, 0);

    // The agent swings the phone 90 deg right; the carrier follows.
    fusion.onCarrierHeading(290.0, 2000);
    expect(fusion.estimate(2000).headingDeg, closeTo(138.0, 1e-9));

    // And back past the wrap point.
    fusion.onCarrierHeading(150.0, 4000);
    expect(fusion.estimate(4000).headingDeg, closeTo(358.0, 1e-9));
  });

  test('a fresh lock is green and an older one is amber', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(0.0, 0);
    fusion.onFix(90.0, HeadingSource.courseOverGround, 0);

    expect(fusion.estimate(29000).confidence, HeadingConfidence.locked);

    final holding = fusion.estimate(75000);
    expect(holding.confidence, HeadingConfidence.holding);
    expect(holding.source, HeadingSource.courseOverGround);
    expect(holding.ageSeconds, 75);
    expect(holding.headingDeg, closeTo(90.0, 1e-9));
  });

  test('the lock expires after three minutes and drops to the compass', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(0.0, 0);
    fusion.onMagneticHeading(140.0, 0);
    fusion.onFix(90.0, HeadingSource.courseOverGround, 0);

    expect(fusion.estimate(179000).confidence, HeadingConfidence.holding);

    final expired = fusion.estimate(181000);
    expect(expired.confidence, HeadingConfidence.unreliable);
    expect(expired.source, HeadingSource.magnetometer);
    expect(expired.headingDeg, closeTo(140.0, 1e-9));
  });

  test('a new fix restarts the clock', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(0.0, 0);
    fusion.onFix(90.0, HeadingSource.courseOverGround, 0);
    expect(fusion.estimate(100000).confidence, HeadingConfidence.holding);

    fusion.onFix(93.0, HeadingSource.landmarkSnap, 100000);
    final refreshed = fusion.estimate(100000);
    expect(refreshed.confidence, HeadingConfidence.locked);
    expect(refreshed.source, HeadingSource.landmarkSnap);
    expect(refreshed.headingDeg, closeTo(93.0, 1e-9));
  });

  test('the compass trims drift only slowly', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(0.0, 0);
    fusion.onMagneticHeading(0.0, 0);
    fusion.onFix(90.0, HeadingSource.courseOverGround, 0);

    // The compass now insists the heading is 8 deg further round. Ten
    // seconds of that, against a 300 s time constant, must move the answer
    // by well under a degree.
    for (var t = 1; t <= 10; t++) {
      fusion.onCarrierHeading(0.0, t * 1000);
      fusion.onMagneticHeading(98.0, t * 1000);
    }
    final nudged = fusion.estimate(10000);
    final moved = angleDifferenceDeg(90.0, nudged.headingDeg).abs();
    expect(moved, lessThan(1.0), reason: 'moved $moved deg in 10 s, expected well under 1');
    expect(moved, greaterThan(0.0), reason: 'but it should have moved a little');
  });

  test('the compass can never drag a lock further than the ceiling', () {
    final fresh = HeadingFusion(config);
    fresh.onCarrierHeading(0.0, 0);
    fresh.onMagneticHeading(0.0, 0);
    fresh.onFix(90.0, HeadingSource.courseOverGround, 0);
    // Three minutes of the compass being 40 deg wrong - a badly disturbed site.
    for (var t = 1; t <= 179; t++) {
      fresh.onCarrierHeading(0.0, t * 1000);
      fresh.onMagneticHeading(130.0, t * 1000);
    }
    final pulled = angleDifferenceDeg(90.0, fresh.estimate(179000).headingDeg).abs();
    expect(pulled, lessThanOrEqualTo(10.0001), reason: 'compass pulled the lock $pulled deg, ceiling is 10');
  });

  test('carried error grows with the drift the compass introduced', () {
    final fusion = HeadingFusion(config);
    fusion.onCarrierHeading(0.0, 0);
    fusion.onMagneticHeading(0.0, 0);
    fusion.onFix(90.0, HeadingSource.landmarkSnap, 0);
    expect(fusion.estimate(0).expectedErrorDeg, closeTo(2.5, 1e-9));

    for (var t = 1; t <= 120; t++) {
      fusion.onCarrierHeading(0.0, t * 1000);
      fusion.onMagneticHeading(130.0, t * 1000);
    }
    expect(fusion.estimate(120000).expectedErrorDeg, greaterThan(2.5));
  });

  test('a fix arriving before any attitude reading still holds', () {
    final fusion = HeadingFusion(config);
    fusion.onFix(137.0, HeadingSource.courseOverGround, 0);
    expect(fusion.estimate(0).headingDeg, closeTo(137.0, 1e-9));
  });
}
