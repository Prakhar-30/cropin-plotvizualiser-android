import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/linear.dart';
import 'package:plot_finder/core/geo/orientation_smoother.dart';
import 'package:plot_finder/core/geo/projection.dart';

/// The smoother's contract: kill the shimmer, keep up with a deliberate turn.
/// Those two pull against each other, which is why it is speed-adaptive.
void main() {
  Mat3 pose(double headingDeg, [double pitchDeg = 0.0]) => deviceToEnuFromOrientation(headingDeg, pitchDeg);

  double between(math.Random r, double from, double until) => from + r.nextDouble() * (until - from);

  test('two interleaved sensor streams switch the filter off', () {
    // The field bug, reproduced.
    //
    // The pose source used to run both rotation vectors through one
    // smoother. The two disagree in yaw - the game vector's origin is
    // arbitrary at boot - so the filter saw a stream alternating between two
    // attitudes tens of degrees apart at the combined sample rate.
    //
    // It does *not* corrupt the drawn pitch and roll directly: two attitudes
    // differing by a yaw interpolate through yaw, and `withHeading` overwrites
    // yaw downstream anyway. What it does is saturate the deviation measure,
    // pin the time constant at its most agile, and stop the smoothing - with
    // every number downstream still looking entirely plausible.
    final random = math.Random(3);
    Mat3 noisyCarrier() => pose(90.0 + between(random, -1.5, 1.5), -12.0 + between(random, -1.5, 1.5));

    final shared = OrientationSmoother();
    final carrierOnly = OrientationSmoother();
    var t = 0;
    var sharedWorst = 0.0;
    var cleanWorst = 0.0;

    for (var i = 0; i < 300; i++) {
      t += 20;
      final sample = noisyCarrier();
      // Shared filter: the magnetic sample lands between every carrier one.
      shared.update(pose(150.0, -12.0), t);
      final sharedOut = shared.update(sample, t + 10);
      final cleanOut = carrierOnly.update(sample, t);
      if (i > 80) {
        sharedWorst = math.max(sharedWorst, (cameraPitchDeg(sharedOut) + 12.0).abs());
        cleanWorst = math.max(cleanWorst, (cameraPitchDeg(cleanOut) + 12.0).abs());
      }
    }

    expect(shared.trackingErrorDeg, greaterThan(20.0),
        reason: 'interleaving must saturate the deviation measure, saw ${shared.trackingErrorDeg}');
    expect(cleanWorst, lessThan(sharedWorst / 2.0),
        reason: 'and the carrier-only filter must attenuate far better: $cleanWorst vs $sharedWorst');
  });

  test('walking bounce is smoothed, a deliberate pan is not', () {
    // Each footfall pitches and rolls the handset by several degrees. That
    // used to clear the agility threshold, so the filter went wide open on
    // every step and passed the gait straight through to the overlay.
    final smoother = OrientationSmoother();
    final random = math.Random(7);
    var t = 0;
    var worst = 0.0;
    for (var i = 0; i < 200; i++) {
      t += 20;
      // A 5 degree gait wobble at roughly two steps per second.
      final phase = math.sin(i * 0.25) * 5.0;
      final sample = pose(90.0 + phase + between(random, -0.6, 0.6), -12.0 + phase * 0.4);
      final out = smoother.update(sample, t);
      if (i > 60) worst = math.max(worst, angleDifferenceDeg(cameraHeadingDeg(out), 90.0).abs());
    }
    expect(worst, lessThan(2.5), reason: 'gait should be attenuated well below its 5 deg amplitude, saw $worst');

    // The same filter still has to follow a real turn. Ninety degrees is
    // what looking from one boundary to the next actually costs.
    var settled = 0.0;
    for (var i = 0; i < 50; i++) {
      t += 20;
      settled = cameraHeadingDeg(smoother.update(pose(180.0, -12.0), t));
    }
    expect(angleDifferenceDeg(settled, 180.0).abs(), lessThan(3.0),
        reason: 'a 90 deg pan must be essentially complete within a second, reached $settled');
  });

  test('quaternion round trip preserves the rotation', () {
    for (final heading in [0.0, 37.0, 179.0, 181.0, 270.0, 359.5]) {
      for (final pitch in [-80.0, -20.0, 0.0, 45.0]) {
        final m = pose(heading, pitch);
        final back = m.toQuat().toMat3();
        expect(cameraHeadingDeg(back), closeTo(heading, 0.01));
        expect(cameraPitchDeg(back), closeTo(pitch, 0.01));
      }
    }
  });

  test('a rotation near 180 degrees survives the conversion', () {
    // The naive sqrt(trace + 1) form divides by nearly zero here, which is
    // why toQuat branches on the largest diagonal term.
    final m = pose(180.0, 0.0);
    expect(cameraHeadingDeg(m.toQuat().toMat3()), closeTo(180.0, 0.01));
  });

  test('slerp takes the short way round the wrap', () {
    // 359 to 1 degrees is a 2 degree turn, not a 358 degree one.
    final mid = slerp(pose(359.0).toQuat(), pose(1.0).toQuat(), 0.5);
    final heading = cameraHeadingDeg(mid.toMat3());
    final fromZero = angleDifferenceDeg(0.0, heading);
    expect(fromZero.abs(), lessThan(1.0), reason: 'halfway should be near 0 deg, got $heading');
  });

  test('a still phone stops shimmering', () {
    final smoother = OrientationSmoother();
    final random = math.Random(5);
    var t = 0;

    // 4 seconds at 50 Hz of a phone held still, with the +/- 1.5 deg of
    // jitter Android's rotation vector actually produces.
    final settled = <double>[];
    for (var i = 0; i < 200; i++) {
      final jitterH = (random.nextDouble() - 0.5) * 3.0;
      final jitterP = (random.nextDouble() - 0.5) * 3.0;
      final out = smoother.update(pose(90.0 + jitterH, jitterP), t);
      t += 20;
      if (i >= 50) settled.add(cameraHeadingDeg(out));
    }

    final swing = settled.reduce(math.max) - settled.reduce(math.min);
    // At 50 m, 0.5 deg is 44 cm of lateral movement - below what the eye
    // picks out against a hand-held camera. The raw input swings 3 deg,
    // or 2.6 m, which is what the field test showed.
    expect(swing, lessThan(0.5), reason: 'smoothed heading still swings $swing deg');
  });

  test('a pan is tracked, and settles quickly once it stops', () {
    final smoother = OrientationSmoother();
    var t = 0;
    var heading = 0.0;

    // Turning at 60 deg/s for one second, sampled at 50 Hz.
    var out = 0.0;
    for (var i = 0; i < 50; i++) {
      heading += 60.0 / 50.0;
      out = cameraHeadingDeg(smoother.update(pose(heading), t));
      t += 20;
    }

    // Some lag while turning is the price of killing the shimmer. 17 deg at
    // 60 deg/s is 0.28 s of lag: steadiness while still is worth a quarter
    // second while turning.
    final lagWhileTurning = angleDifferenceDeg(out, heading).abs();
    expect(lagWhileTurning, lessThan(20.0), reason: 'lagged $lagWhileTurning deg behind a 60 deg/s pan');

    // Now stop and watch it settle. Both horizons are asserted so the shape
    // of that settling curve is pinned rather than assumed.
    for (var i = 0; i < 25; i++) {
      out = cameraHeadingDeg(smoother.update(pose(heading), t));
      t += 20;
    }
    final afterHalfSecond = angleDifferenceDeg(out, heading).abs();
    expect(afterHalfSecond, lessThan(5.0), reason: '$afterHalfSecond deg off half a second after stopping');

    for (var i = 0; i < 50; i++) {
      out = cameraHeadingDeg(smoother.update(pose(heading), t));
      t += 20;
    }
    final afterAnotherSecond = angleDifferenceDeg(out, heading).abs();
    expect(afterAnotherSecond, lessThan(1.0), reason: '$afterAnotherSecond deg off 1.5 s after stopping');
  });

  test('a long gap re-seeds instead of sweeping through every angle', () {
    final smoother = OrientationSmoother();
    smoother.update(pose(0.0), 0);
    // Backgrounded for two seconds while the agent turned round.
    // Interpolating across that would drag the overlay through 180 degrees
    // of orientations the phone never held.
    final out = smoother.update(pose(180.0), 2000);
    expect(cameraHeadingDeg(out), closeTo(180.0, 0.5));
  });
}
