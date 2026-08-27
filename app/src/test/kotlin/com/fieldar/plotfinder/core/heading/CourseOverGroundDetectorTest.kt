package com.fieldar.plotfinder.core.heading

import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.METRES_PER_DEG_LAT
import com.fieldar.plotfinder.core.geo.normalizeDeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class CourseOverGroundDetectorTest {

    private val start = LatLng(12.7862, 76.7201)
    private val metresPerDegLng = cos(Math.toRadians(start.lat)) * 111_320.0

    /** Walks `count` fixes of `stepM` each along `bearing`, one per second. */
    private fun walk(
        detector: CourseOverGroundDetector,
        bearingDeg: Double,
        count: Int,
        stepM: Double = 5.0,
        startAtMs: Long = 0,
        from: LatLng = start,
        speedMps: Double = 1.3,
        accuracyM: Double = 6.0,
        bearingNoise: (Int) -> Double = { 0.0 },
    ): Pair<Double?, LatLng> {
        var position = from
        var result: Double? = null
        for (i in 0 until count) {
            val r = Math.toRadians(bearingDeg)
            position = LatLng(
                lat = position.lat + (stepM * cos(r)) / METRES_PER_DEG_LAT,
                lng = position.lng + (stepM * sin(r)) / metresPerDegLng,
            )
            val emitted = detector.add(
                LocationSample(
                    position = position,
                    bearingDeg = normalizeDeg(bearingDeg + bearingNoise(i)),
                    speedMps = speedMps,
                    accuracyM = accuracyM,
                    timestampMs = startAtMs + (i + 1) * 1_000L,
                ),
            )
            if (emitted != null) result = emitted
        }
        return result to position
    }

    @Test
    fun `a straight walk past twenty metres locks a heading`() {
        val detector = CourseOverGroundDetector()
        // Six fixes 5 m apart: 25 m of ground, clear of both the distance and
        // the sample-count bars.
        val (heading, _) = walk(detector, bearingDeg = 42.0, count = 6)
        assertNotNull(heading)
        assertEquals(42.0, heading!!, 0.001)
    }

    @Test
    fun `fifteen metres is not yet enough ground`() {
        val detector = CourseOverGroundDetector()
        // Four fixes 5 m apart is 15 m of travel - three gaps, not four.
        assertNull(walk(detector, bearingDeg = 42.0, count = 4).first)
        assertEquals(15.0, detector.segmentDistanceM, 0.05)
    }

    @Test
    fun `a short walk locks nothing`() {
        val detector = CourseOverGroundDetector()
        val (heading, _) = walk(detector, bearingDeg = 42.0, count = 3)
        assertNull(heading)
    }

    @Test
    fun `standing still discards the segment`() {
        val detector = CourseOverGroundDetector()
        walk(detector, bearingDeg = 42.0, count = 3)
        // A stationary fix: no bearing, no speed.
        assertNull(
            detector.add(
                LocationSample(start, bearingDeg = null, speedMps = 0.0, accuracyM = 6.0, timestampMs = 4_000),
            ),
        )
        assertEquals(0, detector.sampleCount)
        assertEquals(0.0, detector.segmentDistanceM, 1e-9)
    }

    @Test
    fun `a slow shuffle is not a walk`() {
        val detector = CourseOverGroundDetector()
        val (heading, _) = walk(detector, bearingDeg = 42.0, count = 8, speedMps = 0.4)
        assertNull(heading)
    }

    @Test
    fun `a poor fix is dropped rather than averaged in`() {
        val detector = CourseOverGroundDetector()
        val (heading, _) = walk(detector, bearingDeg = 42.0, count = 8, accuracyM = 40.0)
        assertNull(heading)
    }

    @Test
    fun `turning mid-window throws the window away`() {
        val detector = CourseOverGroundDetector()
        // Three steps north, then three steps east: 20 m covered, but the mean
        // of those bearings points north-east, at neither leg of the walk.
        val (_, corner) = walk(detector, bearingDeg = 0.0, count = 3)
        val (heading, _) = walk(detector, bearingDeg = 90.0, count = 3, startAtMs = 3_000, from = corner)
        assertNull("a turn must not produce a confident heading", heading)
    }

    @Test
    fun `small wobble in a straight walk is tolerated`() {
        val detector = CourseOverGroundDetector()
        // Plus or minus 4 deg of GNSS bearing noise: mean deviation ~4 deg, under
        // the 8 deg bar, so this is still a straight line.
        val (heading, _) = walk(detector, bearingDeg = 300.0, count = 6) { i ->
            if (i % 2 == 0) 4.0 else -4.0
        }
        assertNotNull(heading)
        assertEquals(300.0, heading!!, 1.0)
    }

    @Test
    fun `a walk across north averages correctly instead of through south`() {
        val detector = CourseOverGroundDetector()
        // Bearings alternating 358 and 2 must average to 0, not to 180.
        val (heading, _) = walk(detector, bearingDeg = 0.0, count = 6) { i ->
            if (i % 2 == 0) -2.0 else 2.0
        }
        assertNotNull(heading)
        assertEquals(0.0, com.fieldar.plotfinder.core.geo.angleDifferenceDeg(0.0, heading!!), 0.5)
    }

    @Test
    fun `a long gap between fixes breaks the segment`() {
        val detector = CourseOverGroundDetector()
        walk(detector, bearingDeg = 42.0, count = 3)
        val far = LatLng(start.lat + 0.0005, start.lng)
        val emitted = detector.add(
            LocationSample(far, bearingDeg = 42.0, speedMps = 1.3, accuracyM = 6.0, timestampMs = 60_000),
        )
        assertNull(emitted)
        assertEquals("window restarts from the newest fix", 1, detector.sampleCount)
    }

    @Test
    fun `the detector resets after emitting so the next segment starts clean`() {
        val detector = CourseOverGroundDetector()
        val (heading, _) = walk(detector, bearingDeg = 42.0, count = 6)
        assertNotNull(heading)
        assertEquals(0, detector.sampleCount)
        assertEquals(0.0, detector.segmentDistanceM, 1e-9)
    }
}
