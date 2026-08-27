package com.fieldar.plotfinder.core.heading

import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.bearingDeg
import com.fieldar.plotfinder.core.geo.distanceM
import com.fieldar.plotfinder.core.geo.normalizeDeg

/**
 * Heading from one tap.
 *
 * The agent aims the crosshair at a physical feature whose coordinates are
 * already cached - the plot's access point, or whatever the landmark note
 * describes - and taps. Both endpoints are known, so the true bearing is simply
 * computable; the only correction needed is for the crosshair not sitting on the
 * optical centre.
 *
 * The one way this goes wrong is snapping to something too close: at 3 m, a 2 m
 * error in the agent's own fix is a 34 degree bearing error, which would pin the
 * heading to something worse than the compass.
 */
const val MIN_SNAP_DISTANCE_M = 10.0

/**
 * True heading for the camera, or null when the feature is too close to aim at.
 *
 * [crosshairOffsetDeg] is the crosshair's horizontal angle from the optical
 * centre, positive to the right - see `horizontalAngleOffsetDeg`.
 */
fun headingFromLandmarkSnap(
    agent: LatLng,
    feature: LatLng,
    crosshairOffsetDeg: Double = 0.0,
): Double? {
    if (distanceM(agent, feature) < MIN_SNAP_DISTANCE_M) return null
    return normalizeDeg(bearingDeg(agent, feature) - crosshairOffsetDeg)
}
