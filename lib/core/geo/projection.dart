import 'dart:math' as math;

import '../math_util.dart';
import 'enu.dart';
import 'linear.dart';

/// Pinhole projection of ground points into the camera preview.
///
/// Frames used here:
///
///  - **ENU**: right-handed, x = east, y = north, z = up.
///  - **Device**: Android's, x = screen right, y = screen top, z = out of the
///    screen towards the user. The rear camera therefore looks along **-z**.
///  - **Screen**: pixels, origin top-left, y growing downward.
///
/// A pose is carried as the device-to-ENU rotation matrix, which is exactly what
/// `SensorManager.getRotationMatrixFromVector` produces. Nothing here decomposes
/// it into Euler angles: heading is corrected by a single yaw rotation about the
/// world up axis, which leaves the sensor's pitch and roll untouched.

/// Camera geometry, read from the platform rather than assumed.
///
/// [horizontalFovDeg] is the field of view across the **viewport width**. On a
/// portrait screen that is the sensor's *short* axis, so the caller reading the
/// characteristics is responsible for the swap - see `CameraGeometry`.
class CameraIntrinsics {
  CameraIntrinsics({
    required this.horizontalFovDeg,
    required this.viewportWidthPx,
    required this.viewportHeightPx,
  })  : focalPx = (viewportWidthPx / 2.0) / math.tan(toRadians(horizontalFovDeg / 2.0)),
        centreXPx = viewportWidthPx / 2.0,
        centreYPx = viewportHeightPx / 2.0;

  final double horizontalFovDeg;
  final int viewportWidthPx;
  final int viewportHeightPx;

  /// Focal length in pixels. One value for both axes: preview pixels are
  /// square, so a separate vertical focal length would be the same number.
  final double focalPx;

  final double centreXPx;
  final double centreYPx;

  @override
  bool operator ==(Object other) =>
      other is CameraIntrinsics &&
      other.horizontalFovDeg == horizontalFovDeg &&
      other.viewportWidthPx == viewportWidthPx &&
      other.viewportHeightPx == viewportHeightPx;

  @override
  int get hashCode => Object.hash(horizontalFovDeg, viewportWidthPx, viewportHeightPx);
}

/// A projected point. [distanceM] is the true 3D range, used for labels and depth ordering.
class ScreenPoint {
  const ScreenPoint(this.x, this.y, this.distanceM);

  final double x;
  final double y;
  final double distanceM;

  /// True when a projected point actually falls inside the preview.
  bool isOnScreen(CameraIntrinsics intrinsics) =>
      x >= 0 && y >= 0 && x <= intrinsics.viewportWidthPx && y <= intrinsics.viewportHeightPx;

  @override
  String toString() => 'ScreenPoint($x, $y, ${distanceM}m)';
}

/// Points nearer than this are behind or on top of the lens and cannot be drawn.
const double nearPlaneM = 0.5;

/// The plane [clipToNearPlane] actually cuts against, a hair in front of the near
/// plane. Cutting exactly on it produces vertices at depth 0.5, which the
/// projector's own cull then throws away - so the clipped corners would vanish
/// and the outline would close across the field anyway, which is the very bug the
/// clipping exists to prevent.
const double _clipPlaneM = nearPlaneM + 1e-3;

/// Projects a point given in the ENU frame.
///
/// Returns `null` when the point is behind the camera. **This cull is not
/// optional**: without it a point behind the agent divides by a negative depth
/// and lands mirrored in front of them, which is by far the most common bug in
/// this kind of overlay - the boundary of the field behind you renders on top of
/// the field you are looking at.
ScreenPoint? projectEnu(
  Enu point,
  Enu camera,
  Mat3 enuToDevice,
  CameraIntrinsics intrinsics,
) =>
    projectDevice(toDevice(point, camera, enuToDevice), intrinsics);

/// Translates an ENU point into the camera's frame, then rotates it into device
/// coordinates.
///
/// [camera] is not optional and has no default, deliberately. An earlier version
/// of this function took only the rotation, which silently placed the camera at
/// the ENU origin - the fix the session happened to anchor on. The boundary was
/// therefore welded to that anchor and appeared to travel alongside the agent as
/// they walked towards it, holding a constant apparent distance while the
/// on-screen label counted honestly down. Requiring the camera position here
/// makes that mistake impossible to write.
Vec3 toDevice(Enu point, Enu camera, Mat3 enuToDevice) => enuToDevice.timesVec(Vec3(
      point.east - camera.east,
      point.north - camera.north,
      point.up - camera.up,
    ));

/// Projects a point already in device coordinates. See [projectEnu] for the cull.
ScreenPoint? projectDevice(Vec3 d, CameraIntrinsics intrinsics) {
  final depth = -d.z;
  if (depth <= nearPlaneM) return null;

  return ScreenPoint(
    intrinsics.centreXPx + intrinsics.focalPx * d.x / depth,
    intrinsics.centreYPx - intrinsics.focalPx * d.y / depth,
    // Rotation preserves length, so this is the true range from the camera.
    d.length,
  );
}

/// Clips a polygon in device coordinates against the near plane.
///
/// Dropping culled vertices instead of clipping would silently reshape a plot the
/// agent is standing inside: the two corners behind them would disappear and the
/// remaining outline would close across the middle of the field. Clipping keeps
/// the visible part of the boundary where it belongs and introduces new vertices
/// on the plane instead.
List<Vec3> clipToNearPlane(List<Vec3> polygon) {
  if (polygon.length < 2) return polygon.where((it) => -it.z > nearPlaneM).toList();

  final clipped = <Vec3>[];
  for (var i = 0; i < polygon.length; i++) {
    final current = polygon[i];
    final next = polygon[(i + 1) % polygon.length];
    final dCurrent = -current.z - _clipPlaneM;
    final dNext = -next.z - _clipPlaneM;

    if (dCurrent >= 0.0) clipped.add(current);
    if ((dCurrent >= 0.0) != (dNext >= 0.0)) {
      final t = dCurrent / (dCurrent - dNext);
      clipped.add(Vec3(
        current.x + t * (next.x - current.x),
        current.y + t * (next.y - current.y),
        current.z + t * (next.z - current.z),
      ));
    }
  }
  return clipped;
}

/// Clips a single open segment against the near plane.
///
/// [clipToNearPlane] treats its input as a closed ring and wraps the last vertex
/// back to the first, which turns a two-point line into a degenerate there-and-
/// back polygon. The top rail of a boundary wall is an open segment, so it needs
/// this instead. Returns `null` when the whole segment is behind the camera.
(Vec3, Vec3)? clipSegmentToNearPlane(Vec3 a, Vec3 b) {
  final dA = -a.z - _clipPlaneM;
  final dB = -b.z - _clipPlaneM;

  if (dA >= 0.0 && dB >= 0.0) return (a, b);
  if (dA < 0.0 && dB < 0.0) return null;

  final t = dA / (dA - dB);
  final crossing = Vec3(
    a.x + t * (b.x - a.x),
    a.y + t * (b.y - a.y),
    a.z + t * (b.z - a.z),
  );
  return dA >= 0.0 ? (a, crossing) : (crossing, b);
}

/// Horizontal angle of a screen column from the optical centre, positive right.
///
/// The landmark snap subtracts this so the heading is pinned to where the
/// crosshair actually is rather than to the middle of the image.
double horizontalAngleOffsetDeg(double xPx, CameraIntrinsics intrinsics) =>
    toDegrees(math.atan2(xPx - intrinsics.centreXPx, intrinsics.focalPx));

/// The compass bearing the camera is pointing along.
///
/// Taken from the camera axis rather than the top of the screen: a phone held
/// upright to look through it has its screen-top axis pointing at the sky, where
/// heading is undefined.
double cameraHeadingDeg(Mat3 deviceToEnu) {
  final forward = deviceToEnu.timesVec(const Vec3(0.0, 0.0, -1.0));
  return normalizeDeg(toDegrees(math.atan2(forward.x, forward.y)));
}

/// Elevation of the camera axis above the horizon, in degrees.
///
/// Reported for the UI and the telemetry row; the projection itself never needs
/// it, because it works from the rotation matrix directly.
double cameraPitchDeg(Mat3 deviceToEnu) {
  final forward = deviceToEnu.timesVec(const Vec3(0.0, 0.0, -1.0));
  return toDegrees(math.asin(clampDouble(forward.z, -1.0, 1.0)));
}

/// Rotation of the device about the camera axis, in degrees, positive clockwise
/// seen from behind the phone. Zero when the screen's top edge points at the sky.
double cameraRollDeg(Mat3 deviceToEnu) {
  final right = deviceToEnu.timesVec(const Vec3(1.0, 0.0, 0.0));
  final cosPitch = math.cos(toRadians(cameraPitchDeg(deviceToEnu)));
  // Straight up or straight down: roll and heading collapse onto each other.
  if (cosPitch.abs() < 1e-9) return 0.0;
  return toDegrees(-math.asin(clampDouble(right.z / cosPitch, -1.0, 1.0)));
}

/// Rotation that increases a world vector's compass bearing by [deltaDeg].
///
/// Bearings grow clockwise from north, which is a *negative* rotation about up in
/// a right-handed east-north-up frame - hence the sign arrangement below.
Mat3 yawAboutUp(double deltaDeg) {
  final t = toRadians(deltaDeg);
  final c = math.cos(t);
  final s = math.sin(t);
  return Mat3(
    c, s, 0.0, //
    -s, c, 0.0, //
    0.0, 0.0, 1.0,
  );
}

/// Re-aims a sensor pose at [desiredHeadingDeg], keeping its pitch and roll.
///
/// This is how a heading from a walked segment or a landmark snap replaces the
/// magnetometer's: one yaw correction about world up, applied to the rotation
/// matrix the sensors already produced.
Mat3 withHeading(Mat3 deviceToEnu, double desiredHeadingDeg) {
  final delta = angleDifferenceDeg(cameraHeadingDeg(deviceToEnu), desiredHeadingDeg);
  return yawAboutUp(delta) * deviceToEnu;
}

/// Builds a device-to-ENU rotation from Euler angles.
///
/// Used by simulation mode and by the tests. The live sensor path does **not**
/// go through here - it uses the rotation matrix directly, so this function's
/// conventions only have to be self-consistent:
///
///  - [headingDeg] compass bearing the camera points along, clockwise from north
///  - [pitchDeg] positive tilts the camera up towards the sky
///  - [rollDeg] positive rotates the device clockwise about the camera axis, seen
///    from behind the phone; the scene therefore appears to counter-rotate
Mat3 deviceToEnuFromOrientation(double headingDeg, double pitchDeg, [double rollDeg = 0.0]) {
  // Device axes when the phone is held upright facing due north:
  // x -> east, y -> up, z -> south.
  const upright = Mat3(
    1.0, 0.0, 0.0, //
    0.0, 0.0, -1.0, //
    0.0, 1.0, 0.0,
  );
  final pitch = Mat3.rotationX(toRadians(pitchDeg));
  final roll = Mat3.rotationZ(toRadians(-rollDeg));
  return yawAboutUp(headingDeg) * upright * pitch * roll;
}
