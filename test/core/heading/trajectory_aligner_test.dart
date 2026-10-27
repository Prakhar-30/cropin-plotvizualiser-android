import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/arcore_pose.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/heading/trajectory_aligner.dart';

void main() {
  const origin = LatLng(12.7862, 76.7201);
  final frame = EnuFrame(origin);

  /// Where a session-frame point really is, for a session whose north is
  /// [yaw] degrees anticlockwise of true north - the same convention the pose
  /// source uses to rotate ARCore motion into true ENU.
  LatLng truthOf(Enu session, double yaw, {double dE = 0, double dN = 0}) {
    final t = arEnuToEnu(session, yaw);
    return frame.toLatLng(Enu(t.east + 40 + dE, t.north - 25 + dN));
  }

  /// A winding approach between bunds: about 1 m/s, one fix a second.
  List<Enu> walk(int seconds) => [
        for (var t = 0; t < seconds; t++) Enu(8 * math.sin(t / 9.0), t * 0.9),
      ];

  double noise(math.Random r, double half) => (r.nextDouble() - 0.5) * 2 * half;

  test('a perfect walk gives the yaw exactly', () {
    final aligner = TrajectoryAligner();
    for (final p in walk(30)) {
      aligner.addFix(p, truthOf(p, 37), 4);
    }
    // Not to 1e-6: the fixes pass through two metric frames 25 m apart, whose
    // east-west scales differ in the seventh digit.
    expect(aligner.solve()!.yawOffsetDeg, closeTo(37.0, 1e-3));
  });

  test('a winding 60 m approach with 5 m fixes sets the direction without a tap', () {
    final r = math.Random(11);
    final aligner = TrajectoryAligner();
    for (final p in walk(70)) {
      aligner.addFix(p, truthOf(p, 37, dE: noise(r, 5), dN: noise(r, 5)), 5);
    }
    final fit = aligner.solve()!;
    expect(angleDifferenceDeg(fit.yawOffsetDeg, 37).abs(), lessThan(6.0));
    expect(fit.errorDeg, lessThan(maxAlignmentErrorDeg));
  });

  test('indoor fixes are ignored rather than trusted', () {
    final aligner = TrajectoryAligner();
    for (final p in walk(70)) {
      aligner.addFix(p, truthOf(p, 37, dE: 60), 95);
    }
    expect(aligner.solve(), isNull);
  });

  test('standing still says nothing, however many fixes', () {
    final aligner = TrajectoryAligner();
    for (var i = 0; i < 60; i++) {
      aligner.addFix(const Enu(0, 0), truthOf(const Enu(0, 0), 37, dE: i.isEven ? 3 : -3), 5);
    }
    expect(aligner.solve(), isNull);
  });

  test('from a pinned access point, walking into the plot sets the direction', () {
    final r = math.Random(5);
    final aligner = TrajectoryAligner();
    aligner.anchor(const Enu(0, 0), truthOf(const Enu(0, 0), -120));
    // About 35 m, a fix a second: the length of walking in to inspect.
    for (var t = 1; t <= 45; t++) {
      final p = Enu(t * 0.6, t * 0.5);
      aligner.addFix(p, truthOf(p, -120, dE: noise(r, 4), dN: noise(r, 4)), 4);
    }
    final fit = aligner.solve()!;
    expect(angleDifferenceDeg(fit.yawOffsetDeg, -120).abs(), lessThan(fit.errorDeg * 2));
    expect(fit.errorDeg, lessThan(maxAlignmentErrorDeg));
  });

  test('losing tracking forgets everything measured before', () {
    final aligner = TrajectoryAligner();
    for (final p in walk(30)) {
      aligner.addFix(p, truthOf(p, 37), 4);
    }
    aligner.reset();
    expect(aligner.solve(), isNull);
  });
}
