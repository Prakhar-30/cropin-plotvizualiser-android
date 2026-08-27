package com.fieldar.plotfinder.pose

import com.fieldar.plotfinder.core.geo.Mat3
import com.fieldar.plotfinder.core.heading.HeadingConfidence
import com.fieldar.plotfinder.core.heading.HeadingSource
import kotlinx.coroutines.flow.StateFlow

/**
 * Where the phone is pointing.
 *
 * [deviceToEnu] is the authoritative value: it is what the projection consumes,
 * and it already carries the fused heading rather than the magnetometer's. The
 * Euler angles are derived from it for the UI and the telemetry row - nothing
 * reconstructs the matrix from them.
 */
data class DevicePose(
    val deviceToEnu: Mat3,
    val headingDeg: Double,
    val pitchDeg: Double,
    val rollDeg: Double,
    val timestampMs: Long,
) {
    companion object {
        val UNKNOWN = DevicePose(Mat3.IDENTITY, 0.0, 0.0, 0.0, 0L)
    }
}

/** How the current heading was arrived at, and how much to trust it. */
data class HeadingStatus(
    val source: HeadingSource,
    val confidence: HeadingConfidence,
    /** Seconds since the last walk lock or landmark snap. */
    val ageSeconds: Int,
    val expectedErrorDeg: Double,
)

/**
 * The seam ARCore would slot into later.
 *
 * v0 is sensor-only on purpose. The far-field identification case needs no plane
 * detection and no visual odometry, and ARCore's Geospatial API is actively
 * wrong here: it depends on Google's Visual Positioning System, which needs
 * Street View coverage that farmland does not have, and it reports confident
 * accuracy figures while silently falling back to raw GPS.
 *
 * An ARCore-backed implementation would satisfy this same interface, so nothing
 * above it has to change.
 */
interface PoseSource {
    val pose: StateFlow<DevicePose>
    val headingStatus: StateFlow<HeadingStatus>

    /** Starts listening. Idempotent. */
    fun start()

    /** Stops listening and releases sensors. */
    fun stop()

    /**
     * Pins the heading to a computed true bearing, as a landmark snap does.
     * [bearingDeg] is the bearing of the camera axis, crosshair offset already
     * subtracted.
     */
    fun applyHeadingFix(bearingDeg: Double, source: HeadingSource)
}
