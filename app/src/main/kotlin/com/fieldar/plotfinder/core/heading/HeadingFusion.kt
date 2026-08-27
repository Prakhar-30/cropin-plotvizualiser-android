package com.fieldar.plotfinder.core.heading

import com.fieldar.plotfinder.core.geo.angleDifferenceDeg
import com.fieldar.plotfinder.core.geo.normalizeDeg
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Holds a heading once something trustworthy has established it.
 *
 * Two attitude streams come in:
 *
 *  - the **carrier**, a gyro-dominant heading with no magnetic reference. It is
 *    smooth and disturbance-proof but its absolute yaw is arbitrary and drifts.
 *  - the **magnetic** heading, which knows where north is but is wrong by 15-25
 *    degrees anywhere near steel or a running motor.
 *
 * A fix - a walked segment or a landmark snap - pins the carrier to true north
 * by storing the offset between them. From then on the heading is carried by the
 * gyro, and the magnetometer is allowed only to trim slow drift, at a long time
 * constant and with a hard ceiling on total authority. That ceiling matters: an
 * unbounded trim would let a magnetically disturbed site drag a good lock onto
 * the neighbouring field slowly enough that nobody notices it happening.
 *
 * Pure: no sensors, no clock of its own. Every method takes the time.
 */
class HeadingFusion(private val config: HeadingConfig = HeadingConfig()) {

    private var carrierDeg: Double? = null
    private var magneticDeg: Double? = null

    /** True heading minus carrier heading, as fixed by the last walk or snap. */
    private var offsetDeg: Double = 0.0
    /** The offset at the moment of the fix, so drift can be bounded against it. */
    private var offsetAtFixDeg: Double = 0.0

    private var fixSource: HeadingSource? = null
    private var fixAtMs: Long = 0
    private var lastMagneticUpdateMs: Long = 0

    /** Gyro-carried heading, from a rotation vector with no magnetic input. */
    fun onCarrierHeading(headingDeg: Double, atMs: Long) {
        carrierDeg = normalizeDeg(headingDeg)
        // Drift trimming is driven from the carrier tick so it runs at a known
        // rate even when magnetic samples arrive irregularly.
        applyMagneticDrift(atMs)
    }

    /** Magnetometer-referenced heading, used as a fallback and as a slow trim. */
    fun onMagneticHeading(headingDeg: Double, atMs: Long) {
        magneticDeg = normalizeDeg(headingDeg)
        applyMagneticDrift(atMs)
    }

    /** A walk lock or a landmark snap. This is the only thing that sets a heading. */
    fun onFix(headingDeg: Double, source: HeadingSource, atMs: Long) {
        val carrier = carrierDeg
        offsetDeg = if (carrier == null) 0.0 else angleDifferenceDeg(carrier, headingDeg)
        offsetAtFixDeg = offsetDeg
        fixSource = source
        fixAtMs = atMs
        lastMagneticUpdateMs = atMs
        // With no carrier yet, the fix itself is the heading until one arrives.
        if (carrier == null) carrierDeg = normalizeDeg(headingDeg)
    }

    private fun applyMagneticDrift(atMs: Long) {
        val carrier = carrierDeg ?: return
        val magnetic = magneticDeg ?: return
        if (fixSource == null) return

        val previous = lastMagneticUpdateMs
        lastMagneticUpdateMs = atMs
        if (previous == 0L || atMs <= previous) return

        val dtSeconds = (atMs - previous) / 1000.0
        val alpha = 1.0 - exp(-dtSeconds / config.magneticDriftTimeConstantS)

        val targetOffset = angleDifferenceDeg(carrier, magnetic)
        val corrected = offsetDeg + alpha * angleDifferenceDeg(offsetDeg, targetOffset)

        // Never let the compass pull further than the ceiling from the fix.
        val drift = angleDifferenceDeg(offsetAtFixDeg, corrected)
        val ceiling = config.maxMagneticDriftCorrectionDeg
        offsetDeg = offsetAtFixDeg + max(-ceiling, min(ceiling, drift))
    }

    fun estimate(atMs: Long): HeadingEstimate {
        val source = fixSource
        val ageMs = if (source == null) 0L else max(0L, atMs - fixAtMs)

        if (source != null && ageMs <= config.lockTtlMs) {
            val carrier = carrierDeg ?: 0.0
            val confidence =
                if (ageMs <= config.lockFreshMs) HeadingConfidence.LOCKED else HeadingConfidence.HOLDING
            // A carried heading is only as good as its fix plus whatever drift
            // the compass has been allowed to introduce since.
            val drift = abs(angleDifferenceDeg(offsetAtFixDeg, offsetDeg))
            return HeadingEstimate(
                headingDeg = normalizeDeg(carrier + offsetDeg),
                source = source,
                confidence = confidence,
                ageMs = ageMs,
                expectedErrorDeg = source.typicalErrorDeg + drift,
            )
        }

        // No fix, or the lock expired: the compass is all that is left, and the
        // UI is expected to grey the overlay out and ask for a few steps.
        return HeadingEstimate(
            headingDeg = magneticDeg ?: carrierDeg ?: 0.0,
            source = HeadingSource.MAGNETOMETER,
            confidence = HeadingConfidence.UNRELIABLE,
            ageMs = ageMs,
            expectedErrorDeg = HeadingSource.MAGNETOMETER.typicalErrorDeg,
        )
    }
}
