import 'dart:math' as math;

import '../math_util.dart';
import 'enu.dart';
import 'linear.dart';
import 'orientation_smoother.dart';
import 'projection.dart';

/// ARCore's camera pose, in this app's frames.
///
/// ARCore's world frame is right-handed with **Y up** (gravity-aligned) and an
/// arbitrary yaw - fixed when the session starts, unrelated to north. Its
/// display-oriented camera pose uses the same device convention as Android's
/// sensors and this app: x right, y up, z towards the viewer, looking along -z.
///
/// So one fixed axis swap takes ARCore's world to a gravity-aligned
/// east-north-up frame whose "north" is the session's arbitrary forward:
///
///     east  =  x
///     north = -z
///     up    =  y
///
/// Its yaw is then exactly as arbitrary as the game rotation vector's, which
/// is why it can be handed to the heading fusion as the carrier: the fusion
/// already knows how to pin an arbitrary-yaw attitude to true north.

/// ARCore world to the yaw-arbitrary ENU frame. Right-handed: x × (−z) = y.
const Mat3 arWorldToEnu = Mat3(
  1.0, 0.0, 0.0, //
  0.0, 0.0, -1.0, //
  0.0, 1.0, 0.0,
);

class ArCoreFrame {
  const ArCoreFrame({
    required this.tracking,
    required this.timestampMs,
    required this.position,
    required this.deviceToArEnu,
    required this.horizontalFovDeg,
    required this.failure,
  });

  /// Decodes the flat array `ArCoreView.emit` sends.
  factory ArCoreFrame.fromList(List<double> v) {
    final q = Quat(v[8], v[5], v[6], v[7]);
    return ArCoreFrame(
      tracking: v[0] > 0.5,
      timestampMs: v[1].toInt(),
      position: Enu(v[2], -v[4], v[3]),
      deviceToArEnu: arWorldToEnu * q.toMat3(),
      horizontalFovDeg: horizontalFovFromProjection(v[9]),
      failure: ArTrackingFailure.values[v[13].toInt().clamp(0, ArTrackingFailure.values.length - 1)],
    );
  }

  final bool tracking;
  final int timestampMs;

  /// The camera's position in the yaw-arbitrary ENU frame, metres.
  final Enu position;

  /// The camera's attitude in the same frame.
  final Mat3 deviceToArEnu;

  /// Across the view's width, as the preview is actually shown.
  final double horizontalFovDeg;
  final ArTrackingFailure failure;

  /// Compass-style heading of the camera in the session's arbitrary frame.
  double get carrierHeadingDeg => cameraHeadingDeg(deviceToArEnu);
}

/// Why ARCore is not tracking, in the order the native side codes them.
enum ArTrackingFailure {
  none,
  badState,
  insufficientLight,
  excessiveMotion,
  insufficientFeatures,
  cameraUnavailable,
}

/// The horizontal FOV an OpenGL projection matrix encodes: `P[0] = 1 / tan(fov/2)`.
///
/// ARCore builds the projection for the view as displayed - after cropping the
/// camera image to fill it - so this is the FOV the overlay must be drawn with,
/// whatever the sensor's own is.
double horizontalFovFromProjection(double p0) => toDegrees(2.0 * math.atan(1.0 / p0));

/// Rotates an ENU displacement measured in the session's arbitrary frame into
/// true ENU, given the yaw that maps the one onto the other.
///
/// [yawOffsetDeg] is true heading minus session heading - the same correction
/// `withHeading` applies to the attitude, applied to the motion.
Enu arEnuToEnu(Enu displacement, double yawOffsetDeg) {
  final v = yawAboutUp(yawOffsetDeg).timesVec(Vec3(displacement.east, displacement.north, displacement.up));
  return Enu(v.x, v.y, v.z);
}
