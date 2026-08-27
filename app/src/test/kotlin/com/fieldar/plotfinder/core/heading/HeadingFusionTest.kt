package com.fieldar.plotfinder.core.heading

import com.fieldar.plotfinder.core.geo.angleDifferenceDeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class HeadingFusionTest {

    private val config = HeadingConfig()

    @Test
    fun `with no fix at all the compass is used and flagged unreliable`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(10.0, atMs = 0)
        fusion.onMagneticHeading(95.0, atMs = 0)

        val estimate = fusion.estimate(atMs = 0)
        assertEquals(95.0, estimate.headingDeg, 1e-9)
        assertEquals(HeadingSource.MAGNETOMETER, estimate.source)
        assertEquals(HeadingConfidence.UNRELIABLE, estimate.confidence)
        assertEquals(20.0, estimate.expectedErrorDeg, 1e-9)
    }

    @Test
    fun `a walk lock overrides a badly wrong compass`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(200.0, atMs = 0)
        fusion.onMagneticHeading(78.0, atMs = 0) // 30 deg out, standing by a tractor
        fusion.onFix(48.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)

        val estimate = fusion.estimate(atMs = 0)
        assertEquals(48.0, estimate.headingDeg, 1e-9)
        assertEquals(HeadingSource.COURSE_OVER_GROUND, estimate.source)
        assertEquals(HeadingConfidence.LOCKED, estimate.confidence)
    }

    @Test
    fun `the gyro carries the locked heading as the phone turns`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(200.0, atMs = 0)
        fusion.onFix(48.0, HeadingSource.LANDMARK_SNAP, atMs = 0)

        // The agent swings the phone 90 deg right; the carrier follows.
        fusion.onCarrierHeading(290.0, atMs = 2_000)
        assertEquals(138.0, fusion.estimate(2_000).headingDeg, 1e-9)

        // And back past the wrap point.
        fusion.onCarrierHeading(150.0, atMs = 4_000)
        assertEquals(358.0, fusion.estimate(4_000).headingDeg, 1e-9)
    }

    @Test
    fun `a fresh lock is green and an older one is amber`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(0.0, atMs = 0)
        fusion.onFix(90.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)

        assertEquals(HeadingConfidence.LOCKED, fusion.estimate(29_000).confidence)

        val holding = fusion.estimate(75_000)
        assertEquals(HeadingConfidence.HOLDING, holding.confidence)
        assertEquals(HeadingSource.COURSE_OVER_GROUND, holding.source)
        assertEquals(75, holding.ageSeconds)
        assertEquals(90.0, holding.headingDeg, 1e-9)
    }

    @Test
    fun `the lock expires after three minutes and drops to the compass`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(0.0, atMs = 0)
        fusion.onMagneticHeading(140.0, atMs = 0)
        fusion.onFix(90.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)

        assertEquals(HeadingConfidence.HOLDING, fusion.estimate(179_000).confidence)

        val expired = fusion.estimate(181_000)
        assertEquals(HeadingConfidence.UNRELIABLE, expired.confidence)
        assertEquals(HeadingSource.MAGNETOMETER, expired.source)
        assertEquals(140.0, expired.headingDeg, 1e-9)
    }

    @Test
    fun `a new fix restarts the clock`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(0.0, atMs = 0)
        fusion.onFix(90.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)
        assertEquals(HeadingConfidence.HOLDING, fusion.estimate(100_000).confidence)

        fusion.onFix(93.0, HeadingSource.LANDMARK_SNAP, atMs = 100_000)
        val refreshed = fusion.estimate(100_000)
        assertEquals(HeadingConfidence.LOCKED, refreshed.confidence)
        assertEquals(HeadingSource.LANDMARK_SNAP, refreshed.source)
        assertEquals(93.0, refreshed.headingDeg, 1e-9)
    }

    @Test
    fun `the compass trims drift only slowly`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(0.0, atMs = 0)
        fusion.onMagneticHeading(0.0, atMs = 0)
        fusion.onFix(90.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)

        // The compass now insists the heading is 8 deg further round. Ten
        // seconds of that, against a 300 s time constant, must move the answer
        // by well under a degree.
        for (t in 1..10) {
            fusion.onCarrierHeading(0.0, atMs = t * 1_000L)
            fusion.onMagneticHeading(98.0, atMs = t * 1_000L)
        }
        val nudged = fusion.estimate(10_000)
        val moved = abs(angleDifferenceDeg(90.0, nudged.headingDeg))
        assertTrue("moved $moved deg in 10 s, expected well under 1", moved < 1.0)
        assertTrue("but it should have moved a little", moved > 0.0)
    }

    @Test
    fun `the compass can never drag a lock further than the ceiling`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(0.0, atMs = 0)
        fusion.onMagneticHeading(0.0, atMs = 0)
        fusion.onFix(90.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)

        // An hour of the compass being 40 deg wrong - a badly disturbed site.
        for (t in 1..3_600) {
            fusion.onCarrierHeading(0.0, atMs = t * 1_000L)
            fusion.onMagneticHeading(130.0, atMs = t * 1_000L)
        }
        // The lock has expired by now, but check the offset ceiling held while
        // it was alive by asking at a time inside the window.
        val fresh = HeadingFusion(config)
        fresh.onCarrierHeading(0.0, atMs = 0)
        fresh.onMagneticHeading(0.0, atMs = 0)
        fresh.onFix(90.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)
        for (t in 1..179) {
            fresh.onCarrierHeading(0.0, atMs = t * 1_000L)
            fresh.onMagneticHeading(130.0, atMs = t * 1_000L)
        }
        val pulled = abs(angleDifferenceDeg(90.0, fresh.estimate(179_000).headingDeg))
        assertTrue("compass pulled the lock $pulled deg, ceiling is 10", pulled <= 10.0001)
    }

    @Test
    fun `carried error grows with the drift the compass introduced`() {
        val fusion = HeadingFusion(config)
        fusion.onCarrierHeading(0.0, atMs = 0)
        fusion.onMagneticHeading(0.0, atMs = 0)
        fusion.onFix(90.0, HeadingSource.LANDMARK_SNAP, atMs = 0)
        assertEquals(2.5, fusion.estimate(0).expectedErrorDeg, 1e-9)

        for (t in 1..120) {
            fusion.onCarrierHeading(0.0, atMs = t * 1_000L)
            fusion.onMagneticHeading(130.0, atMs = t * 1_000L)
        }
        assertTrue(fusion.estimate(120_000).expectedErrorDeg > 2.5)
    }

    @Test
    fun `a fix arriving before any attitude reading still holds`() {
        val fusion = HeadingFusion(config)
        fusion.onFix(137.0, HeadingSource.COURSE_OVER_GROUND, atMs = 0)
        assertEquals(137.0, fusion.estimate(0).headingDeg, 1e-9)
    }
}
