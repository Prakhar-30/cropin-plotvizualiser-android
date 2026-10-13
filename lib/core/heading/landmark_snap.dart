import '../geo/enu.dart';

/// Heading from one tap.
///
/// The agent aims the crosshair at a physical feature whose coordinates are
/// already cached - the plot's access point, or whatever the landmark note
/// describes - and taps. Both endpoints are known, so the true bearing is simply
/// computable; the only correction needed is for the crosshair not sitting on the
/// optical centre.
///
/// The one way this goes wrong is snapping to something too close: at 3 m, a 2 m
/// error in the agent's own fix is a 34 degree bearing error, which would pin the
/// heading to something worse than the compass.
const double minSnapDistanceM = 10.0;

/// True heading for the camera, or null when the feature is too close to aim at.
///
/// [crosshairOffsetDeg] is the crosshair's horizontal angle from the optical
/// centre, positive to the right - see `horizontalAngleOffsetDeg`.
double? headingFromLandmarkSnap(LatLng agent, LatLng feature, [double crosshairOffsetDeg = 0.0]) {
  if (distanceM(agent, feature) < minSnapDistanceM) return null;
  return normalizeDeg(bearingDeg(agent, feature) - crosshairOffsetDeg);
}
