import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/math_util.dart';
import 'package:plot_finder/ui/ar/ar_controller.dart';

void main() {
  test('no zoom keeps the field of view', () {
    expect(zoomedFovDeg(65.0, 1.0), closeTo(65.0, 1e-9));
  });

  test('a 2x zoom halves the tangent of the half-angle, as a crop of the centre does', () {
    final zoomed = zoomedFovDeg(65.0, 2.0);
    expect(math.tan(toRadians(zoomed) / 2), closeTo(math.tan(toRadians(65.0) / 2) / 2, 1e-12));
    expect(zoomed, inInclusiveRange(65.0 / 2, 36.0), reason: 'a little more than half the angle');
  });

  test('the pinch range tops out at a sensible magnification', () {
    expect(maxZoom, inInclusiveRange(3.0, 8.0));
  });
}
