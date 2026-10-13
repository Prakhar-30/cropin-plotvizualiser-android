import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/linear.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/math_util.dart';

/// A 1080 x 1920 viewport with a 60 degree horizontal field of view gives a focal
/// length of (1080 / 2) / tan(30 deg) = 540 / 0.57735027 = 935.307 px, and a
/// principal point at (540, 960). Every expectation below follows from those
/// three numbers.
void main() {
  final intrinsics = CameraIntrinsics(
    horizontalFovDeg: 60.0,
    viewportWidthPx: 1080,
    viewportHeightPx: 1920,
  );

  /// These tests place the camera at the frame origin, which keeps the expected
  /// numbers hand-checkable. That the camera must be *stated* rather than
  /// assumed is the point of the parameter - see the overlay geometry tests for
  /// the case where it sits somewhere else.
  const originEye = Enu(0.0, 0.0, 0.0);

  /// Level camera, pointing due north.
  final facingNorth = deviceToEnuFromOrientation(0.0, 0.0);

  ScreenPoint? project(Enu point, [Mat3? deviceToEnu]) =>
      projectEnu(point, originEye, (deviceToEnu ?? facingNorth).transpose(), intrinsics);

  test('focal length and principal point come from the declared field of view', () {
    expect(intrinsics.focalPx, closeTo(935.307, 0.01));
    expect(intrinsics.centreXPx, closeTo(540.0, 1e-9));
    expect(intrinsics.centreYPx, closeTo(960.0, 1e-9));
  });

  test('a hundred metres dead ahead lands on the principal point', () {
    final p = project(const Enu(0.0, 100.0))!;
    expect(p.x, closeTo(540.0, 0.01));
    expect(p.y, closeTo(960.0, 0.01));
    expect(p.distanceM, closeTo(100.0, 1e-9));
  });

  test('a point at half the field of view lands exactly on the right edge', () {
    // 100 * tan(30 deg) = 57.735 m east of straight ahead.
    final east = 100.0 * math.tan(toRadians(30.0));
    final p = project(Enu(east, 100.0))!;
    expect(p.x, closeTo(1080.0, 0.02));
    expect(p.y, closeTo(960.0, 0.02));
    // The edge is inclusive; allow for the last ulp of floating point.
    expect(ScreenPoint(math.min(p.x, 1080.0), p.y, p.distanceM).isOnScreen(intrinsics), isTrue);
  });

  test('the mirror image lands on the left edge', () {
    final east = -100.0 * math.tan(toRadians(30.0));
    final p = project(Enu(east, 100.0))!;
    expect(p.x, closeTo(0.0, 0.02));
  });

  test('beyond the field of view the point projects off screen rather than vanishing', () {
    // 45 deg to the right: x = 540 + 935.307 * 1 = 1475.3, past the 1080 edge.
    final p = project(const Enu(100.0, 100.0))!;
    expect(p.x, closeTo(1475.307, 0.02));
    expect(p.isOnScreen(intrinsics), isFalse);
  });

  test('ground points sit below the horizon by the eye height', () {
    // The ground is 1.6 m below the phone, 100 m away:
    // y = 960 + 935.307 * 1.6 / 100 = 974.965
    final p = project(const Enu(0.0, 100.0, -eyeHeightM))!;
    expect(p.y, closeTo(974.965, 0.02));
    expect(p.x, closeTo(540.0, 0.02));
  });

  test('points behind the camera are culled, not mirrored', () {
    // This is the whole reason the near-plane test exists: without it the
    // negative depth flips the sign and the field behind the agent draws on
    // top of the one in front.
    expect(project(const Enu(0.0, -100.0)), isNull);
    expect(project(const Enu(30.0, -100.0)), isNull);
    expect(project(const Enu(-30.0, -100.0)), isNull);
    // Straight up is also behind a level camera's image plane.
    expect(project(const Enu(0.0, 0.0, 100.0)), isNull);
  });

  test('a point on the lens is culled by the near plane', () {
    expect(project(const Enu(0.0, 0.2)), isNull);
    expect(project(const Enu(0.0, 0.6)), isNotNull);
  });

  test('turning the camera east moves a northern point to the left', () {
    final facingEast = deviceToEnuFromOrientation(90.0, 0.0);
    // Facing east, a point due north is 90 deg to the left: behind the image
    // plane edge-on, so it culls.
    expect(project(const Enu(0.0, 100.0), facingEast), isNull);

    // 30 deg left of east is bearing 60: north = 100*cos60 = 50, east = 100*sin60 = 86.603
    final p = project(const Enu(86.603, 50.0), facingEast)!;
    expect(p.x, closeTo(0.0, 0.05));
  });

  test('pitching the camera up pushes the target down the screen', () {
    final pitchedUp = deviceToEnuFromOrientation(0.0, 10.0);
    // y = 960 + 935.307 * tan(10 deg) = 960 + 164.925 = 1124.925
    final p = project(const Enu(0.0, 100.0), pitchedUp)!;
    expect(p.y, closeTo(1124.925, 0.05));
    expect(p.x, closeTo(540.0, 0.05));
  });

  test('pitching the camera down pulls the target up the screen', () {
    final pitchedDown = deviceToEnuFromOrientation(0.0, -10.0);
    final p = project(const Enu(0.0, 100.0), pitchedDown)!;
    expect(p.y, closeTo(795.075, 0.05));
  });

  test('camera heading is recovered from the rotation matrix', () {
    for (final heading in [0.0, 37.0, 90.0, 180.0, 271.5, 359.0]) {
      for (final pitch in [-20.0, 0.0, 15.0]) {
        final r = deviceToEnuFromOrientation(heading, pitch);
        expect(cameraHeadingDeg(r), closeTo(heading, 1e-6));
      }
    }
  });

  test('pitch and roll are recovered from the rotation matrix', () {
    for (final heading in [0.0, 115.0, 300.0]) {
      for (final pitch in [-35.0, -5.0, 0.0, 22.0]) {
        for (final roll in [-40.0, 0.0, 18.0]) {
          final r = deviceToEnuFromOrientation(heading, pitch, roll);
          expect(cameraPitchDeg(r), closeTo(pitch, 1e-6), reason: 'pitch at h=$heading p=$pitch r=$roll');
          expect(cameraRollDeg(r), closeTo(roll, 1e-6), reason: 'roll at h=$heading p=$pitch r=$roll');
        }
      }
    }
  });

  test('roll does not change where the camera is aimed', () {
    final upright = deviceToEnuFromOrientation(50.0, 5.0, 0.0);
    final rolled = deviceToEnuFromOrientation(50.0, 5.0, 25.0);
    expect(cameraHeadingDeg(rolled), closeTo(cameraHeadingDeg(upright), 1e-6));
  });

  test('roll rotates the scene about the camera axis', () {
    final rolled = deviceToEnuFromOrientation(0.0, 0.0, 90.0);
    // A point 30 deg right of a level camera sits on the right edge, 540 px
    // from centre. Roll the *device* 90 deg clockwise and the scene
    // counter-rotates, carrying that point to 540 px above centre.
    final east = 100.0 * math.tan(toRadians(30.0));
    final p = project(Enu(east, 100.0), rolled)!;
    expect(p.x, closeTo(540.0, 0.05));
    expect(p.y, closeTo(420.0, 0.05));
  });

  test('substituting a heading keeps pitch and roll intact', () {
    final sensorPose = deviceToEnuFromOrientation(200.0, 12.0, 8.0);
    final corrected = withHeading(sensorPose, 65.0);

    expect(cameraHeadingDeg(corrected), closeTo(65.0, 1e-6));

    // Pitch survives: a point 100 m along the new heading must land at the
    // same height on screen as it did under the old one.
    final before = projectEnu(const Enu(0.0, 100.0), originEye, sensorPose.transpose(), intrinsics);
    final rebuilt = deviceToEnuFromOrientation(65.0, 12.0, 8.0);
    final afterCorrected =
        projectEnu(const Enu(0.0, 100.0), originEye, corrected.transpose(), intrinsics);
    final afterRebuilt = projectEnu(const Enu(0.0, 100.0), originEye, rebuilt.transpose(), intrinsics);
    expect(before, isNull); // heading 200 means north is behind the camera
    expect(afterCorrected!.x, closeTo(afterRebuilt!.x, 0.05));
    expect(afterCorrected.y, closeTo(afterRebuilt.y, 0.05));
  });

  test('a twenty degree heading error shifts an eighty metre target by twenty nine metres', () {
    // The reason the heading architecture exists, as an assertion.
    const truth = Enu(0.0, 80.0);
    final wrongPose = deviceToEnuFromOrientation(20.0, 0.0);
    final p = project(truth, wrongPose)!;

    // Off by 20 deg, so the target appears 20 deg left of centre:
    // x = 540 - 935.307 * tan(20 deg) = 540 - 340.44 = 199.56
    expect(p.x, closeTo(199.56, 0.1));

    // On the ground that is 80 * tan(20 deg) = 29.1 m of lateral error -
    // comfortably into the neighbour's field.
    expect(80.0 * math.tan(toRadians(20.0)), closeTo(29.12, 0.01));
  });

  test('clipping a polygon that straddles the camera keeps the visible part', () {
    // A square on the ground plane around the camera, in device coordinates
    // for a level north-facing phone: device z = -north.
    final ring = [
      const Enu(-10.0, -10.0, -1.6),
      const Enu(10.0, -10.0, -1.6),
      const Enu(10.0, 10.0, -1.6),
      const Enu(-10.0, 10.0, -1.6),
    ].map((p) => toDevice(p, originEye, facingNorth.transpose())).toList();

    final clipped = clipToNearPlane(ring);
    // Two corners in front survive and two crossings are added on the plane.
    expect(clipped.length, 4);
    for (final v in clipped) {
      expect(-v.z, greaterThan(nearPlaneM));
    }
  });

  test('an open segment is clipped at the crossing, not wrapped', () {
    const a = Vec3(0.0, 0.0, -10.0); // 10 m in front
    const b = Vec3(0.0, 0.0, 10.0); // 10 m behind
    final clipped = clipSegmentToNearPlane(a, b)!;
    expect(clipped.$1, a);
    expect(-clipped.$2.z, closeTo(nearPlaneM + 1e-3, 1e-9));
    expect(clipSegmentToNearPlane(const Vec3(0, 0, 5), const Vec3(1, 0, 6)), isNull);
  });
}
