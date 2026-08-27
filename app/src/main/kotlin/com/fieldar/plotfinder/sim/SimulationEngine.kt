package com.fieldar.plotfinder.sim

import android.os.SystemClock
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.Enu
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.cameraPitchDeg
import com.fieldar.plotfinder.core.geo.cameraRollDeg
import com.fieldar.plotfinder.core.geo.deviceToEnuFromOrientation
import com.fieldar.plotfinder.core.geo.normalizeDeg
import com.fieldar.plotfinder.core.heading.HeadingFusion
import com.fieldar.plotfinder.core.heading.HeadingSource
import com.fieldar.plotfinder.core.heading.LocationSample
import com.fieldar.plotfinder.location.LocationSource
import com.fieldar.plotfinder.pose.DevicePose
import com.fieldar.plotfinder.pose.HeadingStatus
import com.fieldar.plotfinder.pose.PoseSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Debug-only stand-in for the GNSS receiver and the attitude sensors.
 *
 * Drives the AR overlay around a synthetic plot from a desk, which is worth
 * days: the failure modes this app exists to handle only appear in a field, and
 * "walk 20 m north to see whether the lock works" is not a debug cycle.
 *
 * It implements both [LocationSource] and [PoseSource] from one piece of state,
 * because they are two views of the same simulated agent - splitting them would
 * mean keeping a position in two places and letting them disagree.
 *
 * Two deliberate error injections:
 *
 *  - [gnssErrorM] displaces the *reported* position from the true one, which
 *    shifts the whole overlay by a few metres. Barely visible at 80 m, which is
 *    the point.
 *  - [headingErrorDeg] is added to the reported heading after fusion, standing
 *    in for residual error whatever the source. At 80 m, 20 degrees puts the
 *    boundary 29 m sideways - on the neighbour's field. That is the slide that
 *    explains why the heading architecture exists.
 */
class SimulationEngine(
    startAt: LatLng,
    private val fusion: HeadingFusion = HeadingFusion(),
    private val clockMs: () -> Long = SystemClock::elapsedRealtime,
) : LocationSource, PoseSource {

    /** Where the agent really is, before any injected error. */
    var truePosition: LatLng = startAt
        private set

    /** Where the phone is really aimed, before any injected error. */
    var trueHeadingDeg: Double = 0.0
        private set

    var pitchDeg: Double = 0.0
        private set

    /** Injected horizontal position error, in metres. */
    var gnssErrorM: Double = 0.0
    /** Accuracy the simulated receiver claims, which sets the near-mode band width. */
    var reportedAccuracyM: Double = 6.0
    /** Injected heading error, in degrees. The demo dial. */
    var headingErrorDeg: Double = 0.0

    private val _location = MutableStateFlow<LocationSample?>(null)
    override val location: StateFlow<LocationSample?> = _location.asStateFlow()

    private val _pose = MutableStateFlow(DevicePose.UNKNOWN)
    override val pose: StateFlow<DevicePose> = _pose.asStateFlow()

    private val _headingStatus = MutableStateFlow(statusFrom(clockMs()))
    override val headingStatus: StateFlow<HeadingStatus> = _headingStatus.asStateFlow()

    private var lastMoveAtMs: Long = 0

    override fun start() {
        publishLocation(bearingDeg = null, speedMps = 0.0)
        publishPose()
    }

    override fun stop() = Unit

    override fun applyHeadingFix(bearingDeg: Double, source: HeadingSource) {
        fusion.onFix(bearingDeg, source, clockMs())
        publishPose()
    }

    /**
     * Steps the agent by a ground velocity, as an on-screen joystick would.
     *
     * A real walk is what produces a course-over-ground lock, so the simulated
     * fix carries a bearing and a speed derived from the movement itself - the
     * detector upstream cannot tell this apart from a real walk, which is the
     * whole point.
     */
    fun move(eastMps: Double, northMps: Double) {
        val now = clockMs()
        val previous = lastMoveAtMs
        lastMoveAtMs = now
        val dt = if (previous == 0L) 0.0 else ((now - previous) / 1000.0).coerceAtMost(0.5)

        val speed = hypot(eastMps, northMps)
        if (dt <= 0.0 || speed <= 0.0) {
            publishLocation(bearingDeg = null, speedMps = 0.0)
            return
        }

        val frame = EnuFrame(truePosition)
        truePosition = frame.toLatLng(Enu(east = eastMps * dt, north = northMps * dt))
        publishLocation(
            bearingDeg = normalizeDeg(Math.toDegrees(atan2(eastMps, northMps))),
            speedMps = speed,
        )
    }

    /** Aims the phone. The joystick's rotation axis, or the heading slider. */
    fun aim(headingDeg: Double, pitchDeg: Double = this.pitchDeg) {
        trueHeadingDeg = normalizeDeg(headingDeg)
        this.pitchDeg = pitchDeg
        val now = clockMs()
        // The simulated attitude sensors see the true aim; injected error is
        // applied on the way out, so fusion behaves exactly as it does in the field.
        fusion.onCarrierHeading(trueHeadingDeg, now)
        fusion.onMagneticHeading(trueHeadingDeg, now)
        publishPose()
    }

    /** Teleports the agent, for jumping to a plot without walking there. */
    fun teleport(to: LatLng) {
        truePosition = to
        lastMoveAtMs = 0
        publishLocation(bearingDeg = null, speedMps = 0.0)
    }

    /** Re-publishes with the current error settings, after a slider moves. */
    fun refresh() {
        publishLocation(_location.value?.bearingDeg, _location.value?.speedMps ?: 0.0)
        publishPose()
    }

    private fun publishLocation(bearingDeg: Double?, speedMps: Double) {
        // The injected error is applied along a fixed north-east bearing so the
        // overlay shifts in a repeatable direction rather than jittering.
        val displaced = EnuFrame(truePosition).toLatLng(
            Enu(
                east = gnssErrorM * cos(Math.toRadians(45.0)),
                north = gnssErrorM * sin(Math.toRadians(45.0)),
            ),
        )
        _location.value = LocationSample(
            position = displaced,
            bearingDeg = bearingDeg,
            speedMps = speedMps,
            accuracyM = reportedAccuracyM,
            timestampMs = clockMs(),
        )
    }

    private fun publishPose() {
        val now = clockMs()
        val estimate = fusion.estimate(now)
        val reportedHeading = normalizeDeg(estimate.headingDeg + headingErrorDeg)
        val attitude = deviceToEnuFromOrientation(reportedHeading, pitchDeg)

        _pose.value = DevicePose(
            deviceToEnu = attitude,
            headingDeg = reportedHeading,
            pitchDeg = cameraPitchDeg(attitude),
            rollDeg = cameraRollDeg(attitude),
            timestampMs = now,
        )
        _headingStatus.value = statusFrom(now)
    }

    private fun statusFrom(atMs: Long): HeadingStatus {
        val estimate = fusion.estimate(atMs)
        return HeadingStatus(
            source = estimate.source,
            confidence = estimate.confidence,
            ageSeconds = estimate.ageSeconds,
            expectedErrorDeg = estimate.expectedErrorDeg,
        )
    }
}
