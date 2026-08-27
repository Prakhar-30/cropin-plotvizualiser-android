package com.fieldar.plotfinder.core.geo

import kotlin.math.atan2
import kotlin.math.tan

/**
 * Pinhole projection of ground points into the camera preview.
 *
 * Frames used here:
 *
 *  - **ENU**: right-handed, x = east, y = north, z = up.
 *  - **Device**: Android's, x = screen right, y = screen top, z = out of the
 *    screen towards the user. The rear camera therefore looks along **-z**.
 *  - **Screen**: pixels, origin top-left, y growing downward.
 *
 * A pose is carried as the device-to-ENU rotation matrix, which is exactly what
 * `SensorManager.getRotationMatrixFromVector` produces. Nothing here decomposes
 * it into Euler angles: heading is corrected by a single yaw rotation about the
 * world up axis, which leaves the sensor's pitch and roll untouched.
 */

/**
 * Camera geometry, read from `CameraCharacteristics` rather than assumed.
 *
 * [horizontalFovDeg] is the field of view across the **viewport width**. On a
 * portrait screen that is the sensor's *short* axis, so the caller reading the
 * characteristics is responsible for the swap - see `CameraIntrinsicsReader`.
 */
data class CameraIntrinsics(
    val horizontalFovDeg: Double,
    val viewportWidthPx: Int,
    val viewportHeightPx: Int,
) {
    /**
     * Focal length in pixels. One value for both axes: preview pixels are
     * square, so a separate vertical focal length would be the same number.
     */
    val focalPx: Double = (viewportWidthPx / 2.0) / tan(Math.toRadians(horizontalFovDeg / 2.0))

    val centreXPx: Double = viewportWidthPx / 2.0
    val centreYPx: Double = viewportHeightPx / 2.0
}

/** A projected point. [distanceM] is the true 3D range, used for labels and depth ordering. */
data class ScreenPoint(val x: Float, val y: Float, val distanceM: Double)

/** Points nearer than this are behind or on top of the lens and cannot be drawn. */
const val NEAR_PLANE_M = 0.5

/**
 * The plane [clipToNearPlane] actually cuts against, a hair in front of the near
 * plane. Cutting exactly on it produces vertices at depth 0.5, which the
 * projector's own cull then throws away - so the clipped corners would vanish
 * and the outline would close across the field anyway, which is the very bug the
 * clipping exists to prevent.
 */
private const val CLIP_PLANE_M = NEAR_PLANE_M + 1e-3

/**
 * Projects a point given in the ENU frame.
 *
 * Returns `null` when the point is behind the camera. **This cull is not
 * optional**: without it a point behind the agent divides by a negative depth
 * and lands mirrored in front of them, which is by far the most common bug in
 * this kind of overlay - the boundary of the field behind you renders on top of
 * the field you are looking at.
 */
fun projectEnu(
    point: Enu,
    camera: Enu,
    enuToDevice: Mat3,
    intrinsics: CameraIntrinsics,
): ScreenPoint? = projectDevice(toDevice(point, camera, enuToDevice), intrinsics)

/**
 * Translates an ENU point into the camera's frame, then rotates it into device
 * coordinates.
 *
 * [camera] is not optional and has no default, deliberately. An earlier version
 * of this function took only the rotation, which silently placed the camera at
 * the ENU origin - the fix the session happened to anchor on. The boundary was
 * therefore welded to that anchor and appeared to travel alongside the agent as
 * they walked towards it, holding a constant apparent distance while the
 * on-screen label counted honestly down. Requiring the camera position here
 * makes that mistake impossible to write.
 */
fun toDevice(point: Enu, camera: Enu, enuToDevice: Mat3): Vec3 = enuToDevice * Vec3(
    point.east - camera.east,
    point.north - camera.north,
    point.up - camera.up,
)

/** Projects a point already in device coordinates. See [projectEnu] for the cull. */
fun projectDevice(d: Vec3, intrinsics: CameraIntrinsics): ScreenPoint? {
    val depth = -d.z
    if (depth <= NEAR_PLANE_M) return null

    return ScreenPoint(
        x = (intrinsics.centreXPx + intrinsics.focalPx * d.x / depth).toFloat(),
        y = (intrinsics.centreYPx - intrinsics.focalPx * d.y / depth).toFloat(),
        // Rotation preserves length, so this is the true range from the camera.
        distanceM = d.length,
    )
}

/**
 * Clips a polygon in device coordinates against the near plane.
 *
 * Dropping culled vertices instead of clipping would silently reshape a plot the
 * agent is standing inside: the two corners behind them would disappear and the
 * remaining outline would close across the middle of the field. Clipping keeps
 * the visible part of the boundary where it belongs and introduces new vertices
 * on the plane instead.
 */
fun clipToNearPlane(polygon: List<Vec3>): List<Vec3> {
    if (polygon.size < 2) return polygon.filter { -it.z > NEAR_PLANE_M }

    val clipped = mutableListOf<Vec3>()
    for (i in polygon.indices) {
        val current = polygon[i]
        val next = polygon[(i + 1) % polygon.size]
        val dCurrent = -current.z - CLIP_PLANE_M
        val dNext = -next.z - CLIP_PLANE_M

        if (dCurrent >= 0.0) clipped += current
        if ((dCurrent >= 0.0) != (dNext >= 0.0)) {
            val t = dCurrent / (dCurrent - dNext)
            clipped += Vec3(
                current.x + t * (next.x - current.x),
                current.y + t * (next.y - current.y),
                current.z + t * (next.z - current.z),
            )
        }
    }
    return clipped
}

/**
 * Clips a single open segment against the near plane.
 *
 * [clipToNearPlane] treats its input as a closed ring and wraps the last vertex
 * back to the first, which turns a two-point line into a degenerate there-and-
 * back polygon. The top rail of a boundary wall is an open segment, so it needs
 * this instead. Returns `null` when the whole segment is behind the camera.
 */
fun clipSegmentToNearPlane(a: Vec3, b: Vec3): Pair<Vec3, Vec3>? {
    val dA = -a.z - CLIP_PLANE_M
    val dB = -b.z - CLIP_PLANE_M

    if (dA >= 0.0 && dB >= 0.0) return a to b
    if (dA < 0.0 && dB < 0.0) return null

    val t = dA / (dA - dB)
    val crossing = Vec3(
        a.x + t * (b.x - a.x),
        a.y + t * (b.y - a.y),
        a.z + t * (b.z - a.z),
    )
    return if (dA >= 0.0) a to crossing else crossing to b
}

/** True when a projected point actually falls inside the preview. */
fun ScreenPoint.isOnScreen(intrinsics: CameraIntrinsics): Boolean =
    x >= 0f && y >= 0f && x <= intrinsics.viewportWidthPx && y <= intrinsics.viewportHeightPx

/**
 * Horizontal angle of a screen column from the optical centre, positive right.
 *
 * The landmark snap subtracts this so the heading is pinned to where the
 * crosshair actually is rather than to the middle of the image.
 */
fun horizontalAngleOffsetDeg(xPx: Double, intrinsics: CameraIntrinsics): Double =
    Math.toDegrees(atan2(xPx - intrinsics.centreXPx, intrinsics.focalPx))

/**
 * The compass bearing the camera is pointing along.
 *
 * Taken from the camera axis rather than the top of the screen: a phone held
 * upright to look through it has its screen-top axis pointing at the sky, where
 * heading is undefined.
 */
fun cameraHeadingDeg(deviceToEnu: Mat3): Double {
    val forward = deviceToEnu * Vec3(0.0, 0.0, -1.0)
    return normalizeDeg(Math.toDegrees(atan2(forward.x, forward.y)))
}

/**
 * Elevation of the camera axis above the horizon, in degrees.
 *
 * Reported for the UI and the telemetry row; the projection itself never needs
 * it, because it works from the rotation matrix directly.
 */
fun cameraPitchDeg(deviceToEnu: Mat3): Double {
    val forward = deviceToEnu * Vec3(0.0, 0.0, -1.0)
    return Math.toDegrees(kotlin.math.asin(forward.z.coerceIn(-1.0, 1.0)))
}

/**
 * Rotation of the device about the camera axis, in degrees, positive clockwise
 * seen from behind the phone. Zero when the screen's top edge points at the sky.
 */
fun cameraRollDeg(deviceToEnu: Mat3): Double {
    val right = deviceToEnu * Vec3(1.0, 0.0, 0.0)
    val cosPitch = kotlin.math.cos(Math.toRadians(cameraPitchDeg(deviceToEnu)))
    // Straight up or straight down: roll and heading collapse onto each other.
    if (kotlin.math.abs(cosPitch) < 1e-9) return 0.0
    return Math.toDegrees(-kotlin.math.asin((right.z / cosPitch).coerceIn(-1.0, 1.0)))
}

/**
 * Rotation that increases a world vector's compass bearing by [deltaDeg].
 *
 * Bearings grow clockwise from north, which is a *negative* rotation about up in
 * a right-handed east-north-up frame - hence the sign arrangement below.
 */
fun yawAboutUp(deltaDeg: Double): Mat3 {
    val t = Math.toRadians(deltaDeg)
    val c = kotlin.math.cos(t)
    val s = kotlin.math.sin(t)
    return Mat3(
        c, s, 0.0,
        -s, c, 0.0,
        0.0, 0.0, 1.0,
    )
}

/**
 * Re-aims a sensor pose at [desiredHeadingDeg], keeping its pitch and roll.
 *
 * This is how a heading from a walked segment or a landmark snap replaces the
 * magnetometer's: one yaw correction about world up, applied to the rotation
 * matrix the sensors already produced.
 */
fun withHeading(deviceToEnu: Mat3, desiredHeadingDeg: Double): Mat3 {
    val delta = angleDifferenceDeg(cameraHeadingDeg(deviceToEnu), desiredHeadingDeg)
    return yawAboutUp(delta) * deviceToEnu
}

/**
 * Builds a device-to-ENU rotation from Euler angles.
 *
 * Used by simulation mode and by the tests. The live sensor path does **not**
 * go through here - it uses the rotation matrix directly, so this function's
 * conventions only have to be self-consistent:
 *
 *  - [headingDeg] compass bearing the camera points along, clockwise from north
 *  - [pitchDeg] positive tilts the camera up towards the sky
 *  - [rollDeg] positive rotates the device clockwise about the camera axis, seen
 *    from behind the phone; the scene therefore appears to counter-rotate
 */
fun deviceToEnuFromOrientation(
    headingDeg: Double,
    pitchDeg: Double,
    rollDeg: Double = 0.0,
): Mat3 {
    // Device axes when the phone is held upright facing due north:
    // x -> east, y -> up, z -> south.
    val upright = Mat3(
        1.0, 0.0, 0.0,
        0.0, 0.0, -1.0,
        0.0, 1.0, 0.0,
    )
    val pitch = Mat3.rotationX(Math.toRadians(pitchDeg))
    val roll = Mat3.rotationZ(Math.toRadians(-rollDeg))
    return yawAboutUp(headingDeg) * upright * pitch * roll
}
