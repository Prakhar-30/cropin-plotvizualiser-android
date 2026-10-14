import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/arcore_pose.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/math_util.dart';

/// [state, t, tx, ty, tz, qx, qy, qz, qw, p0, p5, w, h, failure]
List<double> frame({
  double tx = 0,
  double ty = 0,
  double tz = 0,
  double qx = 0,
  double qy = 0,
  double qz = 0,
  double qw = 1,
  double p0 = 1.0,
}) =>
    [1, 1000, tx, ty, tz, qx, qy, qz, qw, p0, 1.8, 1080, 2000, 0];

void main() {
  test('the identity pose looks along the session forward, level', () {
    // ARCore's identity camera looks down its world -z, which this frame calls
    // north: heading 0, pitch 0, roll 0.
    final f = ArCoreFrame.fromList(frame());
    expect(f.tracking, isTrue);
    expect(f.carrierHeadingDeg, closeTo(0.0, 1e-9));
    expect(cameraPitchDeg(f.deviceToArEnu), closeTo(0.0, 1e-9));
    expect(cameraRollDeg(f.deviceToArEnu), closeTo(0.0, 1e-9));
  });

  test('a turn to the right is a clockwise heading', () {
    // A 90 degree yaw about ARCore's up (y) is counter-clockwise seen from
    // above, so the camera now looks along world -x: west, heading 270.
    final s = math.sin(math.pi / 4);
    final f = ArCoreFrame.fromList(frame(qy: s, qw: s));
    expect(f.carrierHeadingDeg, closeTo(270.0, 1e-6));
  });

  test('tilting the camera up reads as positive pitch', () {
    // +20 degrees about the device x axis raises the camera's line of sight.
    final a = toRadians(20.0) / 2;
    final f = ArCoreFrame.fromList(frame(qx: math.sin(a), qw: math.cos(a)));
    expect(cameraPitchDeg(f.deviceToArEnu), closeTo(20.0, 1e-6));
  });

  test('positions map x to east, -z to north, y to up', () {
    final f = ArCoreFrame.fromList(frame(tx: 2, ty: 1.5, tz: -3));
    expect(f.position.east, closeTo(2.0, 1e-12));
    expect(f.position.north, closeTo(3.0, 1e-12));
    expect(f.position.up, closeTo(1.5, 1e-12));
  });

  test('the field of view comes from the projection the preview uses', () {
    // P[0] = 1 / tan(30 deg) is a 60 degree horizontal FOV.
    final f = ArCoreFrame.fromList(frame(p0: 1 / math.tan(toRadians(30))));
    expect(f.horizontalFovDeg, closeTo(60.0, 1e-9));
  });

  test('session motion is rotated into true ENU by the heading offset', () {
    // Walking 1 m along the session's "north" when the session's north is
    // really east (offset +90) is walking 1 m east.
    final d = arEnuToEnu(const Enu(0, 1, 0), 90.0);
    expect(d.east, closeTo(1.0, 1e-12));
    expect(d.north, closeTo(0.0, 1e-12));
    // The same offset turns the attitude the same way, so motion and view agree.
    final f = ArCoreFrame.fromList(frame());
    expect(cameraHeadingDeg(withHeading(f.deviceToArEnu, 90.0)), closeTo(90.0, 1e-9));
  });
}
