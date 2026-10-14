import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/position_stabilizer.dart';
import 'package:plot_finder/core/math_util.dart';

/// The stabiliser's contract, stated as the two things the partners asked for:
/// standing still must hold the overlay still, and walking must still work.
void main() {
  const origin = LatLng(12.7862, 76.7201);
  final metresPerDegLng = math.cos(toRadians(origin.lat)) * metresPerDegLngAtEquator;

  LatLng offset(LatLng from, double eastM, double northM) => LatLng(
        from.lat + northM / metresPerDegLat,
        from.lng + eastM / metresPerDegLng,
      );

  /// A fixed seed keeps the noise identical run to run: no flaky thresholds.
  double noise(math.Random random, double metres) => (random.nextDouble() - 0.5) * 2.0 * metres;

  double maxStep(List<LatLng> track) {
    var worst = 0.0;
    for (var i = 1; i < track.length; i++) {
      worst = math.max(worst, distanceM(track[i - 1], track[i]));
    }
    return worst;
  }

  test('a stationary agent under noisy fixes barely moves', () {
    final stabilizer = PositionStabilizer();
    final random = math.Random(7);
    var t = 1000;

    // 90 seconds of 1 Hz fixes, each scattered up to 5 m from the truth -
    // a realistic phone standing on a wall in the open.
    final converging = <LatLng>[];
    final locked = <LatLng>[];
    for (var i = 0; i < 90; i++) {
      final fix = offset(origin, noise(random, 5.0), noise(random, 5.0));
      final out = stabilizer.update(position: fix, accuracyM: 5.0, speedMps: 0.0, timestampMs: t);
      t += 1000;
      // The filter is seeded with the first fix's own accuracy as its
      // variance, which is the honest prior but means the gain starts near
      // 0.5 and takes about half a minute to collapse. That is deliberate:
      // locking instantly would mean locking onto whatever the first fix
      // happened to be. The two phases are asserted separately.
      if (i >= 5 && i <= 29) {
        converging.add(out.position);
      } else if (i >= 30) {
        locked.add(out.position);
      }
    }

    final worstFromTruth = locked.map((p) => distanceM(origin, p)).reduce(math.max);
    // A boundary sitting half a metre off but perfectly still reads as
    // correct; one that is unbiased and twitching reads as broken. The slew
    // limiter trades the first for the second on purpose.
    expect(worstFromTruth, lessThan(3.0), reason: 'stationary estimate drifted $worstFromTruth m from truth');

    // The number that matters on screen is frame-to-frame movement, not
    // absolute error: a boundary 1 m off but rock steady looks correct,
    // one that is perfectly centred but twitching looks broken.
    final convergingStep = maxStep(converging);
    expect(convergingStep, lessThan(0.7), reason: 'still settling: stepped $convergingStep m between fixes');

    // Standing still, the drawn position may move at most the stationary slew
    // rate per second whatever the receiver reports, so this is a guarantee
    // rather than an observation about one random seed. At 50 m that is 0.09
    // deg per second, or under 2 px - below what an eye reads as motion at all.
    final lockedStep = maxStep(locked);
    expect(lockedStep, lessThanOrEqualTo(0.09), reason: 'locked overlay stepped $lockedStep m between fixes');
  });

  test('the stationary detector reports standing still', () {
    final stabilizer = PositionStabilizer();
    final random = math.Random(11);
    var t = 1000;
    var last = stabilizer.update(position: origin, accuracyM: 5.0, speedMps: 0.0, timestampMs: t);
    for (var i = 0; i < 20; i++) {
      t += 1000;
      last = stabilizer.update(
        position: offset(origin, noise(random, 4.0), noise(random, 4.0)),
        accuracyM: 5.0,
        speedMps: 0.05,
        timestampMs: t,
      );
    }
    expect(last.stationary, isTrue);
  });

  test('a walking agent is tracked, not held back', () {
    final stabilizer = PositionStabilizer();
    final random = math.Random(13);
    var t = 1000;
    stabilizer.update(position: origin, accuracyM: 5.0, speedMps: 0.0, timestampMs: t);

    // 40 seconds due north at 1.4 m/s, a normal walking pace.
    var truth = origin;
    var out = const LatLng(0.0, 0.0);
    for (var i = 0; i < 40; i++) {
      t += 1000;
      truth = offset(truth, 0.0, 1.4);
      out = stabilizer
          .update(
            position: offset(truth, noise(random, 4.0), noise(random, 4.0)),
            accuracyM: 5.0,
            speedMps: 1.4,
            timestampMs: t,
          )
          .position;
    }

    // Lag is acceptable; being stuck is not. At 1.4 m/s a filter that
    // refused to move would be 56 m behind by now.
    final error = distanceM(truth, out);
    expect(error, lessThan(5.0), reason: 'walking agent tracked to within $error m');
    expect(stabilizer.stationary, isFalse);
  });

  test('a single wild fix is rejected', () {
    final stabilizer = PositionStabilizer();
    var t = 1000;
    for (var i = 0; i < 15; i++) {
      stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
      t += 1000;
    }

    final wild = offset(origin, 0.0, 400.0);
    final out = stabilizer.update(position: wild, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);

    expect(out.rejectedOutlier, isTrue, reason: 'a 400 m jump should be gated');
    expect(distanceM(origin, out.position), lessThan(2.0),
        reason: 'the estimate must not follow the outlier');
  });

  test('a genuine relocation is accepted once it persists', () {
    final stabilizer = PositionStabilizer();
    var t = 1000;
    for (var i = 0; i < 15; i++) {
      stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
      t += 1000;
    }

    // The same "impossible" position, over and over. After a few rejections
    // the filter must conclude that its own estimate is the wrong one -
    // otherwise an agent who steps out from behind a shed is stranded.
    final elsewhere = offset(origin, 0.0, 400.0);
    var out = stabilizer.update(position: elsewhere, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
    for (var i = 0; i < 6; i++) {
      t += 1000;
      out = stabilizer.update(position: elsewhere, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
    }

    expect(distanceM(elsewhere, out.position), lessThan(5.0),
        reason: 'the filter must eventually believe a persistent relocation');
  });

  test('a fix claiming implausible accuracy is not blindly trusted', () {
    // A receiver reporting 0.1 m accuracy while 8 m off must not be allowed
    // to yank the estimate onto itself in one step.
    final stabilizer = PositionStabilizer();
    var t = 1000;
    for (var i = 0; i < 15; i++) {
      stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
      t += 1000;
    }

    final overconfident = offset(origin, 8.0, 0.0);
    final out = stabilizer.update(position: overconfident, accuracyM: 0.1, speedMps: 0.0, timestampMs: t);
    expect(distanceM(origin, out.position), lessThan(1.0),
        reason: 'an over-confident fix moved the estimate ${distanceM(origin, out.position)} m in one step');
  });

  test('re-anchoring the internal frame does not move the estimate', () {
    final stabilizer = PositionStabilizer();
    var t = 1000;
    stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);

    // Walk 120 m, well past the re-anchor distance, in steady steps.
    var truth = origin;
    var out = const LatLng(0.0, 0.0);
    final steps = <double>[];
    for (var i = 0; i < 80; i++) {
      t += 1000;
      truth = offset(truth, 0.0, 1.5);
      final next = stabilizer.update(position: truth, accuracyM: 4.0, speedMps: 1.5, timestampMs: t);
      if (i > 5) steps.add(next.shiftM);
      out = next.position;
    }

    // If a re-anchor leaked, one step would be far bigger than its neighbours.
    final worst = steps.reduce(math.max);
    expect(worst, lessThan(4.0), reason: 're-anchor produced a $worst m jump');
    expect(distanceM(truth, out), closeTo(0.0, 6.0));
  });

  // Regression test for an overlay stranded 97 km from the plot.
  //
  // The rejection hold used to be bounded only by a count of fixes. That is
  // not a bound at all: four samples is four seconds at 1 Hz and *forever* at
  // 0 Hz. The simulator publishes a fix only when something happens, so one
  // wild fix was rejected and no second fix ever arrived to break the hold -
  // and the same thing would happen to a real receiver that dropped out right
  // after a bad fix.
  test('a rejection cannot hold longer than its wall-clock cap', () {
    final stabilizer = PositionStabilizer();
    var t = 1000;
    stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);

    final elsewhere = offset(origin, 0.0, 400.0);

    // One outlier, held.
    t += 1000;
    final held = stabilizer.update(position: elsewhere, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
    expect(held.rejectedOutlier, isTrue);

    // The receiver then goes quiet for a while. The very next fix, however
    // long it took to arrive, must not still be gated against a stale
    // estimate: no count of fixes will ever be reached.
    t += 30000;
    final resumed = stabilizer.update(position: elsewhere, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
    expect(distanceM(elsewhere, resumed.position), lessThan(5.0),
        reason: 'estimate stranded ${distanceM(elsewhere, resumed.position)} m from the fix');
  });

  test('reset makes the next fix a fresh start rather than an outlier', () {
    // A teleport is not a GNSS observation. Filtering one against an estimate
    // anchored somewhere else gates it as a wild outlier, which is how the
    // simulator ended up 97 km from the plot it was supposed to be showing.
    final stabilizer = PositionStabilizer();
    var t = 1000;
    for (var i = 0; i < 10; i++) {
      stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
      t += 1000;
    }

    final farAway = offset(origin, 0.0, 90000.0);
    stabilizer.reset();
    final out = stabilizer.update(position: farAway, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);

    expect(out.rejectedOutlier, isFalse, reason: 'a fix after reset must not be gated');
    expect(distanceM(farAway, out.position), closeTo(0.0, 1.0));
  });

  // Regression test for the field report that prompted step counting.
  //
  // Indoors the receiver barely moves and reports ~13 m accuracy and zero
  // Doppler speed while the agent walks. The filter used to read that as
  // standing still and hold the drawn position, so as the agent walked nine
  // metres towards a plot the boundary receded with them.
  test('walking indoors moves the drawn position with the steps', () {
    final stabilizer = PositionStabilizer();
    var t = 1000;
    for (var i = 0; i < 10; i++) {
      stabilizer.update(position: origin, accuracyM: 13.0, speedMps: 0.0, timestampMs: t);
      t += 1000;
    }

    // Twelve 0.7 m steps due north, two a second, with the receiver still
    // insisting nothing has changed.
    late StabilizedPosition out;
    for (var i = 0; i < 12; i++) {
      t += 500;
      out = stabilizer.onStep(lengthM: 0.7, headingDeg: 0.0, timestampMs: t)!;
      if (i.isOdd) out = stabilizer.update(position: origin, accuracyM: 13.0, speedMps: 0.0, timestampMs: t);
    }

    final walked = offset(origin, 0.0, 8.4);
    expect(distanceM(walked, out.position), lessThan(1.5),
        reason: 'drawn ${distanceM(origin, out.position)} m from the start after an 8.4 m walk');
    expect(stabilizer.stationary, isFalse);
  });

  test('a step moves the drawn position at once, with no slew lag', () {
    final stabilizer = PositionStabilizer();
    stabilizer.update(position: origin, accuracyM: 5.0, speedMps: 0.0, timestampMs: 1000);
    final out = stabilizer.onStep(lengthM: 0.7, headingDeg: 90.0, timestampMs: 1100)!;
    expect(distanceM(origin, out.position), closeTo(0.7, 0.01));
    expect(bearingDeg(origin, out.position), closeTo(90.0, 0.5));
  });

  test('with steps being counted, stillness comes from the steps, not Doppler', () {
    final stabilizer = PositionStabilizer();
    stabilizer.update(position: origin, accuracyM: 5.0, speedMps: 0.0, timestampMs: 1000);
    stabilizer.onStep(lengthM: 0.7, headingDeg: 0.0, timestampMs: 1500);
    // Doppler says stopped; the last step was half a second ago - walking.
    stabilizer.update(position: origin, accuracyM: 5.0, speedMps: 0.0, timestampMs: 2000);
    expect(stabilizer.stationary, isFalse);
    // Three seconds with no step - standing, whatever Doppler says.
    stabilizer.update(position: origin, accuracyM: 5.0, speedMps: 1.2, timestampMs: 4500);
    expect(stabilizer.stationary, isTrue);
  });

  test('outdoors, good fixes still pull a wrong step length back to the truth', () {
    // Steps sized 30% too short against a receiver accurate to 4 m: GNSS must
    // keep the drawn position from falling behind for good.
    final stabilizer = PositionStabilizer();
    var t = 1000;
    stabilizer.update(position: origin, accuracyM: 4.0, speedMps: 0.0, timestampMs: t);
    var truth = origin;
    late StabilizedPosition out;
    for (var i = 0; i < 60; i++) {
      t += 500;
      truth = offset(truth, 0.0, 0.7);
      stabilizer.onStep(lengthM: 0.49, headingDeg: 0.0, timestampMs: t);
      if (i.isOdd) out = stabilizer.update(position: truth, accuracyM: 4.0, speedMps: 1.4, timestampMs: t);
    }
    expect(distanceM(truth, out.position), lessThan(4.0));
  });

  test('a step before the first fix has nowhere to step from', () {
    expect(PositionStabilizer().onStep(lengthM: 0.7, headingDeg: 0.0, timestampMs: 1000), isNull);
  });
}
