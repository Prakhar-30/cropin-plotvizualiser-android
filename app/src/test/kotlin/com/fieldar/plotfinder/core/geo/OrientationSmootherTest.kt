package com.fieldar.plotfinder.core.geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Mirrors the private AGILE_DEVIATION_DEG, for asserting saturation. */
private const val AGILE_DEVIATION_FOR_TEST = 25.0

/**
 * The smoother's contract: kill the shimmer, keep up with a deliberate turn.
 * Those two pull against each other, which is why it is speed-adaptive.
 */
class OrientationSmootherTest {

    private fun pose(headingDeg: Double, pitchDeg: Double = 0.0) =
        deviceToEnuFromOrientation(headingDeg, pitchDeg)

    @Test
    fun `two interleaved sensor streams switch the filter off`() {
        // The field bug, reproduced.
        //
        // The pose source used to run both rotation vectors through one
        // smoother. The two disagree in yaw - the game vector's origin is
        // arbitrary at boot - so the filter saw a stream alternating between two
        // attitudes tens of degrees apart at the combined sample rate.
        //
        // What that breaks is subtle, and worth stating precisely because the
        // obvious guess is wrong. It does *not* corrupt the drawn pitch and
        // roll directly: two attitudes differing by a yaw interpolate through
        // yaw, and `withHeading` overwrites yaw downstream anyway. What it does
        // is saturate the deviation measure. Deviation is how the filter tells a
        // deliberate turn from jitter; held permanently at sixty degrees it
        // reports "always turning", pins the time constant at its most agile
        // 0.05 s, and the smoother stops smoothing. The noise it existed to
        // remove then passes through untouched, silently, with every number
        // downstream still looking entirely plausible.
        val random = Random(3)
        fun noisyCarrier(i: Int) = pose(
            90.0 + random.nextDouble(-1.5, 1.5),
            pitchDeg = -12.0 + random.nextDouble(-1.5, 1.5),
        )

        val shared = OrientationSmoother()
        val carrierOnly = OrientationSmoother()
        var t = 0L
        var sharedWorst = 0.0
        var cleanWorst = 0.0

        repeat(300) { i ->
            t += 20
            val sample = noisyCarrier(i)
            // Shared filter: the magnetic sample lands between every carrier one.
            shared.update(pose(150.0, pitchDeg = -12.0), t)
            val sharedOut = shared.update(sample, t + 10)
            val cleanOut = carrierOnly.update(sample, t)
            if (i > 80) {
                sharedWorst = maxOf(sharedWorst, kotlin.math.abs(cameraPitchDeg(sharedOut) + 12.0))
                cleanWorst = maxOf(cleanWorst, kotlin.math.abs(cameraPitchDeg(cleanOut) + 12.0))
            }
        }

        println("INTERLEAVED pitch error %.3f deg | CARRIER-ONLY %.3f deg".format(sharedWorst, cleanWorst))
        println("INTERLEAVED tracking error %.1f deg".format(shared.trackingErrorDeg))

        assertTrue(
            "interleaving must saturate the deviation measure, saw ${"%.1f".format(shared.trackingErrorDeg)}",
            shared.trackingErrorDeg > 20.0,
        )
        assertTrue(
            "and the carrier-only filter must attenuate far better: " +
                "${"%.3f".format(cleanWorst)} vs ${"%.3f".format(sharedWorst)}",
            cleanWorst < sharedWorst / 2.0,
        )
    }

    @Test
    fun `walking bounce is smoothed, a deliberate pan is not`() {
        // Each footfall pitches and rolls the handset by several degrees. That
        // used to clear the agility threshold, so the filter went wide open on
        // every step and passed the gait straight through to the overlay.
        val smoother = OrientationSmoother()
        val random = Random(7)
        var t = 0L
        var worst = 0.0
        repeat(200) { i ->
            t += 20
            // A 5 degree gait wobble at roughly two steps per second.
            val phase = Math.sin(i * 0.25) * 5.0
            val sample = pose(90.0 + phase + random.nextDouble(-0.6, 0.6), pitchDeg = -12.0 + phase * 0.4)
            val out = smoother.update(sample, t)
            if (i > 60) worst = maxOf(worst, kotlin.math.abs(angleDifferenceDeg(cameraHeadingDeg(out), 90.0)))
        }
        assertTrue("gait should be attenuated well below its 5 deg amplitude, saw ${"%.2f".format(worst)}", worst < 2.5)

        // The same filter still has to follow a real turn. Ninety degrees is
        // what looking from one boundary to the next actually costs.
        var settled = 0.0
        repeat(50) {
            t += 20
            settled = cameraHeadingDeg(smoother.update(pose(180.0, pitchDeg = -12.0), t))
        }
        assertTrue(
            "a 90 deg pan must be essentially complete within a second, reached $settled",
            kotlin.math.abs(angleDifferenceDeg(settled, 180.0)) < 3.0,
        )
    }

    @Test
    fun `quaternion round trip preserves the rotation`() {
        for (heading in listOf(0.0, 37.0, 179.0, 181.0, 270.0, 359.5)) {
            for (pitch in listOf(-80.0, -20.0, 0.0, 45.0)) {
                val m = pose(heading, pitch)
                val back = m.toQuat().toMat3()
                assertEquals(heading, cameraHeadingDeg(back), 0.01)
                assertEquals(pitch, cameraPitchDeg(back), 0.01)
            }
        }
    }

    @Test
    fun `a rotation near 180 degrees survives the conversion`() {
        // The naive sqrt(trace + 1) form divides by nearly zero here, which is
        // why toQuat branches on the largest diagonal term.
        val m = pose(headingDeg = 180.0, pitchDeg = 0.0)
        assertEquals(180.0, cameraHeadingDeg(m.toQuat().toMat3()), 0.01)
    }

    @Test
    fun `slerp takes the short way round the wrap`() {
        // 359 to 1 degrees is a 2 degree turn, not a 358 degree one.
        val mid = slerp(pose(359.0).toQuat(), pose(1.0).toQuat(), 0.5)
        val heading = cameraHeadingDeg(mid.toMat3())
        val fromZero = angleDifferenceDeg(0.0, heading)
        assertTrue("halfway should be near 0 deg, got $heading", kotlin.math.abs(fromZero) < 1.0)
    }

    @Test
    fun `a still phone stops shimmering`() {
        val smoother = OrientationSmoother()
        val random = Random(5)
        var t = 0L

        // 4 seconds at 50 Hz of a phone held still, with the +/- 1.5 deg of
        // jitter Android's rotation vector actually produces.
        val settled = mutableListOf<Double>()
        repeat(200) { i ->
            val jitterH = (random.nextDouble() - 0.5) * 3.0
            val jitterP = (random.nextDouble() - 0.5) * 3.0
            val out = smoother.update(pose(90.0 + jitterH, jitterP), t)
            t += 20
            if (i >= 50) settled += cameraHeadingDeg(out)
        }

        val swing = settled.max() - settled.min()
        // At 50 m, 0.5 deg is 44 cm of lateral movement - below what the eye
        // picks out against a hand-held camera. The raw input swings 3 deg,
        // or 2.6 m, which is what the field test showed.
        assertTrue("smoothed heading still swings $swing deg", swing < 0.5)
    }

    @Test
    fun `a pan is tracked, and settles quickly once it stops`() {
        val smoother = OrientationSmoother()
        var t = 0L
        var heading = 0.0

        // Turning at 60 deg/s for one second, sampled at 50 Hz.
        var out = 0.0
        repeat(50) {
            heading += 60.0 / 50.0
            out = cameraHeadingDeg(smoother.update(pose(heading), t))
            t += 20
        }

        // Some lag while turning is the price of killing the shimmer, and it is
        // the right trade: this app is used by someone standing still trying to
        // read a boundary, not by someone whipping the phone around. What must
        // not happen is the filter falling so far behind that the overlay is
        // somewhere else entirely.
        val lagWhileTurning = kotlin.math.abs(angleDifferenceDeg(out, heading))
        println("PAN lag %.2f deg".format(lagWhileTurning))
        // Widened from 15 deg when the filter was made heavier to reject walking
        // gait. 17 deg at 60 deg/s is 0.28 s of lag, and that is the deliberate
        // side of the trade: this app is used by someone standing in a field
        // trying to read where a boundary runs, not by someone whipping the
        // phone around. Steadiness while still is worth a quarter second while
        // turning, and the field test was unambiguous about which one was
        // missing.
        assertTrue("lagged $lagWhileTurning deg behind a 60 deg/s pan", lagWhileTurning < 20.0)

        // Now stop and watch it settle. The tail is deliberately slow: as the
        // gap closes the filter hands control back to the heavy time constant,
        // which is exactly what stops the shimmer returning the moment the
        // phone is still. Both horizons are asserted so the shape of that
        // settling curve is pinned rather than assumed.
        repeat(25) {
            out = cameraHeadingDeg(smoother.update(pose(heading), t))
            t += 20
        }
        val afterHalfSecond = kotlin.math.abs(angleDifferenceDeg(out, heading))
        println("SETTLE 0.5s %.2f deg".format(afterHalfSecond))
        // Widened alongside the heavier time constant. The overlay now glides
        // into place over about a second after a big pan instead of snapping.
        // That is a deliberate, visible property and not a defect: a glide reads
        // as settling, which is what it is, whereas the shimmer it buys out
        // reads as the boundary being in the wrong place.
        assertTrue("$afterHalfSecond deg off half a second after stopping", afterHalfSecond < 5.0)

        repeat(50) {
            out = cameraHeadingDeg(smoother.update(pose(heading), t))
            t += 20
        }
        val afterAnotherSecond = kotlin.math.abs(angleDifferenceDeg(out, heading))
        println("SETTLE 1.5s %.3f deg".format(afterAnotherSecond))
        assertTrue("$afterAnotherSecond deg off 1.5 s after stopping", afterAnotherSecond < 1.0)
    }

    @Test
    fun `a long gap re-seeds instead of sweeping through every angle`() {
        val smoother = OrientationSmoother()
        smoother.update(pose(0.0), 0L)
        // Backgrounded for two seconds while the agent turned round.
        // Interpolating across that would drag the overlay through 180 degrees
        // of orientations the phone never held.
        val out = smoother.update(pose(180.0), 2_000L)
        assertEquals(180.0, cameraHeadingDeg(out), 0.5)
    }
}
