package com.fieldar.plotfinder.core.heading

import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.bearingStatistics
import com.fieldar.plotfinder.core.geo.distanceM

/** One GNSS fix, as the platform hands it over. */
data class LocationSample(
    val position: LatLng,
    /** `Location.bearing`, degrees clockwise from true north. Null when not moving. */
    val bearingDeg: Double?,
    val speedMps: Double,
    val accuracyM: Double,
    val timestampMs: Long,
)

/** Tunables for what counts as "walked far enough in a straight enough line". */
data class CourseOverGroundConfig(
    val minSpeedMps: Double = 0.7,
    val minSegmentDistanceM: Double = 20.0,
    val minSamples: Int = 5,
    /**
     * Mean absolute deviation of the bearings in the window. Above this the
     * agent turned, and averaging the segment would produce a heading pointing
     * at neither leg of the walk.
     */
    val maxBearingSpreadDeg: Double = 8.0,
    /** Fixes worse than this contribute more noise to the bearing than signal. */
    val maxAccuracyM: Double = 25.0,
    /** A gap this long means the fixes are no longer one continuous walk. */
    val maxSampleGapMs: Long = 5_000,
)

/**
 * Turns a walked segment into a heading.
 *
 * `Location.bearing` is derived from GNSS motion, not from the magnetic field,
 * so it is the one heading source in this app that a tractor, a transformer or a
 * steel gatepost cannot corrupt. The catch is that it is only meaningful while
 * the agent is actually walking in a straight line, so this class accumulates a
 * window and rejects it outright if the bearings inside it disagree - a segment
 * where the agent turned is worse than no segment at all, because averaging its
 * two legs gives a confident heading pointing between them.
 *
 * Pure and clock-free: feed it samples, it returns a heading or null.
 */
class CourseOverGroundDetector(private val config: CourseOverGroundConfig = CourseOverGroundConfig()) {

    private val window = mutableListOf<LocationSample>()

    /** Metres of ground covered by the samples currently in the window. */
    var segmentDistanceM: Double = 0.0
        private set

    val sampleCount: Int get() = window.size

    fun reset() {
        window.clear()
        segmentDistanceM = 0.0
    }

    /**
     * Adds a fix and returns a locked heading when the window has become a valid
     * straight segment. Returns null while the segment is still forming, and
     * discards the window whenever the walk breaks.
     */
    fun add(sample: LocationSample): Double? {
        val bearing = sample.bearingDeg
        val usable = bearing != null &&
            sample.speedMps >= config.minSpeedMps &&
            sample.accuracyM <= config.maxAccuracyM

        if (!usable) {
            // Standing still, or a fix too poor to trust: the walk is over.
            reset()
            return null
        }

        val previous = window.lastOrNull()
        if (previous != null) {
            if (sample.timestampMs - previous.timestampMs > config.maxSampleGapMs) {
                reset()
            } else {
                segmentDistanceM += distanceM(previous.position, sample.position)
            }
        }
        window += sample

        if (segmentDistanceM < config.minSegmentDistanceM || window.size < config.minSamples) {
            return null
        }

        val stats = bearingStatistics(window.mapNotNull { it.bearingDeg }) ?: return null
        if (stats.spreadDeg > config.maxBearingSpreadDeg) {
            // The agent turned somewhere in this window. Throw it away and start
            // a fresh segment from the newest fix.
            val newest = window.last()
            reset()
            window += newest
            return null
        }

        reset()
        return stats.meanDeg
    }
}
