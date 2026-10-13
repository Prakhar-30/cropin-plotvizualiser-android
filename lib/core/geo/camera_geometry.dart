import 'dart:math' as math;

import '../math_util.dart';

/// The camera preview, and the field of view it is actually showing.
///
/// The FOV is read from the camera's physical characteristics rather than
/// assumed. A hardcoded 60 degrees is wrong on most phones - real rear cameras
/// run from roughly 60 to 80 degrees horizontally - and the error goes straight
/// into the projection as a scale factor on every screen position, spreading or
/// squeezing the whole plot outline about the centre of the image.
class CameraGeometry {
  const CameraGeometry({required this.shortFovDeg, required this.aspect});

  /// From the physical sensor, allowing for the preview cropping it.
  ///
  /// The Kotlin app could size its CameraX preview to the sensor's own 4:3. The
  /// Flutter camera plugin hands back whatever preview size the device chose,
  /// often 16:9, and a 16:9 stream from a 4:3 sensor is a centre crop of the
  /// *short* axis - exactly the axis that spans the width of a portrait screen.
  /// Taking the FOV from the full sensor would then overstate it by several
  /// degrees and squeeze every projected point towards the centre. So the crop
  /// is undone here: whichever axis the preview is relatively wider on keeps
  /// its full extent, and the other is cut down to match.
  ///
  /// [previewAspect] is long side over short side of the preview stream.
  factory CameraGeometry.fromSensor({
    required double sensorWidthMm,
    required double sensorHeightMm,
    required double focalMm,
    double? previewAspect,
  }) {
    final long = math.max(sensorWidthMm, sensorHeightMm);
    final short = math.min(sensorWidthMm, sensorHeightMm);
    final sensorAspect = long / short;
    final aspect = previewAspect ?? sensorAspect;
    // A preview wider than the sensor crops the short axis; a narrower one
    // crops the long axis and leaves the short one whole.
    final visibleShort = aspect > sensorAspect ? long / aspect : short;
    return CameraGeometry(shortFovDeg: _fovDeg(visibleShort, focalMm), aspect: aspect);
  }

  /// Field of view of the visible image's short axis, in degrees.
  final double shortFovDeg;

  /// Long side over short side of the visible image, e.g. 4/3 or 16/9.
  final double aspect;

  /// FOV across the width of a portrait viewport.
  ///
  /// The preview is the sensor rotated a quarter turn, so the screen's *width*
  /// shows the sensor's *short* axis. Getting this the wrong way round is a
  /// silent 20-degree error that looks plausible until the overlay is compared
  /// with a real boundary.
  double get portraitHorizontalFovDeg => shortFovDeg;

  /// Width over height of the preview when the phone is held upright.
  double get portraitAspect => 1.0 / aspect;

  /// Fallback when the characteristics are unreadable. Chosen at the wide end of
  /// typical so the overlay errs towards spreading out rather than bunching up,
  /// and flagged rather than silently assumed.
  static const CameraGeometry fallback = CameraGeometry(shortFovDeg: 52.0, aspect: 4.0 / 3.0);

  CameraGeometry withPreviewAspect(double previewAspect) {
    if (previewAspect <= 0) return this;
    // Without the physical sensor this can only be an estimate: hold the FOV
    // per unit of tangent and rescale the short axis to the new crop.
    if (previewAspect <= aspect) return CameraGeometry(shortFovDeg: shortFovDeg, aspect: previewAspect);
    final halfTan = math.tan(toRadians(shortFovDeg / 2.0)) * aspect / previewAspect;
    return CameraGeometry(shortFovDeg: toDegrees(2.0 * math.atan(halfTan)), aspect: previewAspect);
  }

  static double _fovDeg(double extentMm, double focalMm) =>
      toDegrees(2.0 * math.atan2(extentMm / 2.0, focalMm));
}
