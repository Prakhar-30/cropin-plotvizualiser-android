import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/camera_geometry.dart';
import 'package:plot_finder/core/math_util.dart';

/// A 6.4 x 4.8 mm (4:3) sensor behind a 4.8 mm lens. Its short axis spans
/// 2 * atan(2.4 / 4.8) = 53.130 deg; a 16:9 crop keeps 6.4 / (16/9) = 3.6 mm of
/// it, which spans 2 * atan(1.8 / 4.8) = 41.112 deg.
void main() {
  CameraGeometry geometry([double? previewAspect]) => CameraGeometry.fromSensor(
        sensorWidthMm: 6.4,
        sensorHeightMm: 4.8,
        focalMm: 4.8,
        previewAspect: previewAspect,
      );

  test('the portrait width shows the short axis of the sensor', () {
    final g = geometry();
    expect(g.portraitHorizontalFovDeg, closeTo(53.130, 0.001));
    expect(g.portraitAspect, closeTo(0.75, 1e-9));
  });

  test('a preview matching the sensor is not cropped', () {
    expect(geometry(4.0 / 3.0).portraitHorizontalFovDeg, closeTo(53.130, 0.001));
  });

  test('a 16:9 preview crops the short axis, and the FOV with it', () {
    // Taking the full-sensor 53 deg here would squeeze every projected point
    // about 25% towards the centre of the screen.
    final g = geometry(16.0 / 9.0);
    expect(g.portraitHorizontalFovDeg, closeTo(41.112, 0.001));
    expect(g.portraitAspect, closeTo(9.0 / 16.0, 1e-9));
  });

  test('a preview narrower than the sensor crops the long axis instead', () {
    expect(geometry(1.0).portraitHorizontalFovDeg, closeTo(53.130, 0.001));
  });

  test('the fallback rescales to a cropped preview the same way', () {
    final cropped = CameraGeometry.fallback.withPreviewAspect(16.0 / 9.0);
    final expected = toDegrees(2.0 * math.atan(math.tan(toRadians(26.0)) * (4.0 / 3.0) / (16.0 / 9.0)));
    expect(cropped.portraitHorizontalFovDeg, closeTo(expected, 1e-9));
    expect(cropped.portraitHorizontalFovDeg, lessThan(CameraGeometry.fallback.portraitHorizontalFovDeg));
  });
}
