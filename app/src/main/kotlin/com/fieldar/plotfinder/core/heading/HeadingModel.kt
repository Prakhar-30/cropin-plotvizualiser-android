package com.fieldar.plotfinder.core.heading

/**
 * Heading is the whole ballgame.
 *
 * A position error of a few metres shifts the overlay by a few metres, which is
 * invisible at 80 m. A heading error scales with distance: at 80 m, 20 degrees
 * of heading error puts the boundary 29 m sideways, which is the middle of the
 * neighbour's field. So heading is never reported as a bare number - it always
 * carries where it came from and how much to trust it.
 */
enum class HeadingSource {
    /**
     * Derived from GNSS motion over a walked segment: 3-5 deg. Immune to
     * magnetic disturbance, because no magnetometer is involved - a tractor or a
     * transformer cannot corrupt it.
     */
    COURSE_OVER_GROUND,

    /** The agent aimed at a known feature and tapped: 2-3 deg. */
    LANDMARK_SNAP,

    /** Compass only: 15-25 deg in a farmyard. Fallback, never a resting state. */
    MAGNETOMETER,
}

/** Mid-range field error for each source, used to size the honesty band in the UI. */
val HeadingSource.typicalErrorDeg: Double
    get() = when (this) {
        HeadingSource.COURSE_OVER_GROUND -> 4.0
        HeadingSource.LANDMARK_SNAP -> 2.5
        HeadingSource.MAGNETOMETER -> 20.0
    }

enum class HeadingConfidence {
    /** Green: fixed by a recent walk or snap. */
    LOCKED,

    /** Amber: gyro-carried since the last fix. Shows seconds elapsed. */
    HOLDING,

    /** Grey: compass only. The overlay greys out and asks for a few steps. */
    UNRELIABLE,
}

data class HeadingEstimate(
    val headingDeg: Double,
    val source: HeadingSource,
    val confidence: HeadingConfidence,
    /** Milliseconds since the last walk lock or snap; zero when there has been none. */
    val ageMs: Long,
    val expectedErrorDeg: Double,
) {
    val ageSeconds: Int get() = (ageMs / 1000L).toInt()
}

/** Tunables for the heading state machine, in one place so the tests can vary them. */
data class HeadingConfig(
    /**
     * A fix younger than this still counts as a live lock.
     *
     * Raised from 30 s after field testing showed the overlay spending an entire
     * visit past it. Re-locking needs a twenty-metre straight walk, and an agent
     * inspecting a plot circles it rather than crossing it, so 30 s made HOLDING
     * the permanent state and LOCKED the rare one - inverting what the two
     * labels are for.
     *
     * The carried heading has not become more accurate; the estimate simply is
     * not stale at sixty seconds. Drift is bounded independently, by the
     * magnetometer trim and its ten-degree ceiling, and whatever drift has
     * accumulated is reported in degrees on the chip either way.
     */
    val lockFreshMs: Long = 60_000,
    /** Past this with no new fix, the lock expires and the compass takes over. */
    val lockTtlMs: Long = 180_000,
    /**
     * Time constant for letting the magnetometer pull the carried heading back.
     * Deliberately long: the compass is the least trustworthy input here, so it
     * corrects slow gyro drift and nothing else.
     */
    val magneticDriftTimeConstantS: Double = 300.0,
    /**
     * Hard ceiling on how far the compass may drag a lock, in degrees. Without
     * it a magnetically disturbed site would eventually walk a good lock onto
     * the neighbouring field, slowly enough that nobody notices.
     */
    val maxMagneticDriftCorrectionDeg: Double = 10.0,
)
