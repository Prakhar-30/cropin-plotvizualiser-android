import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/heading/landmark_snap.dart';

void main() {
  const agent = LatLng(12.7862, 76.7201);
  final intrinsics = CameraIntrinsics(horizontalFovDeg: 60.0, viewportWidthPx: 1080, viewportHeightPx: 1920);

  test('aiming dead centre pins the heading to the true bearing', () {
    // 0.002 deg east of the agent is due east, 217 m away.
    final feature = LatLng(agent.lat, agent.lng + 0.002);
    expect(headingFromLandmarkSnap(agent, feature)!, closeTo(90.0, 1e-9));
  });

  test('a crosshair off to the right means the camera points further left', () {
    final feature = LatLng(agent.lat, agent.lng + 0.002);
    // A crosshair 30 deg right of centre sees the feature at bearing 90, so
    // the camera axis itself is aimed at 60.
    expect(headingFromLandmarkSnap(agent, feature, 30.0)!, closeTo(60.0, 1e-9));
  });

  test('the crosshair offset comes from the real focal length', () {
    // Right edge of a 60 deg viewport is exactly half the field of view out.
    expect(horizontalAngleOffsetDeg(1080.0, intrinsics), closeTo(30.0, 1e-6));
    expect(horizontalAngleOffsetDeg(540.0, intrinsics), closeTo(0.0, 1e-9));
    expect(horizontalAngleOffsetDeg(0.0, intrinsics), closeTo(-30.0, 1e-6));
  });

  test('snapping wraps past north rather than going negative', () {
    // Feature due north, crosshair 30 deg right: camera axis is at 330.
    final feature = LatLng(agent.lat + 0.002, agent.lng);
    expect(headingFromLandmarkSnap(agent, feature, 30.0)!, closeTo(330.0, 1e-9));
  });

  test('a feature too close to aim at is refused', () {
    // 5 m away: the agent's own GNSS error would dominate the bearing.
    final close = LatLng(agent.lat + 5.0 / 110540.0, agent.lng);
    expect(headingFromLandmarkSnap(agent, close), isNull);
  });
}
