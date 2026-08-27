package com.fieldar.plotfinder.core.geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.random.Random

/**
 * The stabiliser's contract, stated as the two things the partners asked for:
 * standing still must hold the overlay still, and walking must still work.
 */
class PositionStabilizerTest {

    private val origin = LatLng(12.7862, 76.7201)
    private val metresPerDegLng = cos(Math.toRadians(origin.lat)) * METRES_PER_DEG_LNG_AT_EQUATOR

    private fun offset(from: LatLng, eastM: Double, northM: Double) = LatLng(
        lat = from.lat + northM / METRES_PER_DEG_LAT,
        lng = from.lng + eastM / metresPerDegLng,
    )

    /** A fixed seed keeps the noise identical run to run: no flaky thresholds. */
    private fun noise(random: Random, metres: Double) = (random.nextDouble() - 0.5) * 2.0 * metres

    @Test
    fun `a stationary agent under noisy fixes barely moves`() {
        val stabilizer = PositionStabilizer()
        val random = Random(7)
        var t = 1_000L

        // 90 seconds of 1 Hz fixes, each scattered up to 5 m from the truth -
        // a realistic phone standing on a wall in the open.
        val converging = mutableListOf<LatLng>()
        val locked = mutableListOf<LatLng>()
        repeat(90) { i ->
            val fix = offset(origin, noise(random, 5.0), noise(random, 5.0))
            val out = stabilizer.update(fix, accuracyM = 5.0, speedMps = 0.0, timestampMs = t)
            t += 1_000
            // The filter is seeded with the first fix's own accuracy as its
            // variance, which is the honest prior but means the gain starts near
            // 0.5 and takes about half a minute to collapse. That is deliberate:
            // locking instantly would mean locking onto whatever the first fix
            // happened to be. The two phases are asserted separately.
            if (i in 5..29) converging += out.position else if (i >= 30) locked += out.position
        }

        val worstFromTruth = locked.maxOf { distanceM(origin, it) }
        println("STATIONARY worst-from-truth %.3f m".format(worstFromTruth))
        // Loosened from 2.0 m when the drawn position was separated from the
        // filter's estimate by a slew limiter. That limiter deliberately trades
        // absolute accuracy for stillness: it lets the drawn position lag the
        // estimate rather than follow every correction, so a metre of standing
        // error is now possible where before it was not.
        //
        // That is the right way round for this product, and the assertion below
        // is the reason. A boundary sitting half a metre off but perfectly still
        // reads as correct; one that is unbiased and twitching reads as broken.
        // The bound that got tighter is the one a person can actually see.
        assertTrue(
            "stationary estimate drifted $worstFromTruth m from truth",
            worstFromTruth < 3.0,
        )

        // The number that matters on screen is frame-to-frame movement, not
        // absolute error: a boundary 1 m off but rock steady looks correct,
        // one that is perfectly centred but twitching looks broken.
        val convergingStep = converging.zipWithNext().maxOf { (a, b) -> distanceM(a, b) }
        assertTrue("still settling: stepped $convergingStep m between fixes", convergingStep < 0.7)

        // The bound is set by what an eye can see, not by what looks tidy in a
        // test. A boundary edge 50 m away subtends 0.23 deg per 20 cm of camera
        // movement, which on a 60 deg / 1080 px viewport is about 4 px. The raw
        // fixes this replaces move the same edge by 5 m, or 90 px, every second.
        val lockedStep = locked.zipWithNext().maxOf { (a, b) -> distanceM(a, b) }
        println("STATIONARY locked step %.4f m | converging step %.4f m".format(lockedStep, convergingStep))
        // Tightened from 0.25 m to the slew limit itself. Standing still, the
        // drawn position may move at most RENDER_SLEW_STATIONARY_MPS per second
        // whatever the receiver reports, so this is now a guarantee rather than
        // an observation about one random seed. At 50 m that is 0.09 deg per
        // second, or under 2 px - below what an eye reads as motion at all.
        assertTrue("locked overlay stepped $lockedStep m between fixes", lockedStep <= 0.09)
    }

    @Test
    fun `the stationary detector reports standing still`() {
        val stabilizer = PositionStabilizer()
        val random = Random(11)
        var t = 1_000L
        var last = stabilizer.update(origin, 5.0, 0.0, t)
        repeat(20) {
            t += 1_000
            last = stabilizer.update(
                offset(origin, noise(random, 4.0), noise(random, 4.0)),
                accuracyM = 5.0,
                speedMps = 0.05,
                timestampMs = t,
            )
        }
        assertTrue(last.stationary)
    }

    @Test
    fun `a walking agent is tracked, not held back`() {
        val stabilizer = PositionStabilizer()
        val random = Random(13)
        var t = 1_000L
        stabilizer.update(origin, 5.0, 0.0, t)

        // 40 seconds due north at 1.4 m/s, a normal walking pace.
        var truth = origin
        var out = LatLng(0.0, 0.0)
        repeat(40) {
            t += 1_000
            truth = offset(truth, 0.0, 1.4)
            out = stabilizer.update(
                offset(truth, noise(random, 4.0), noise(random, 4.0)),
                accuracyM = 5.0,
                speedMps = 1.4,
                timestampMs = t,
            ).position
        }

        // Lag is acceptable; being stuck is not. At 1.4 m/s a filter that
        // refused to move would be 56 m behind by now.
        val error = distanceM(truth, out)
        assertTrue("walking agent tracked to within $error m", error < 5.0)
        assertFalse(stabilizer.stationary)
    }

    @Test
    fun `a single wild fix is rejected`() {
        val stabilizer = PositionStabilizer()
        var t = 1_000L
        repeat(15) {
            stabilizer.update(origin, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)
            t += 1_000
        }

        val wild = offset(origin, 0.0, 400.0)
        val out = stabilizer.update(wild, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)

        assertTrue("a 400 m jump should be gated", out.rejectedOutlier)
        assertTrue(
            "the estimate must not follow the outlier",
            distanceM(origin, out.position) < 2.0,
        )
    }

    @Test
    fun `a genuine relocation is accepted once it persists`() {
        val stabilizer = PositionStabilizer()
        var t = 1_000L
        repeat(15) {
            stabilizer.update(origin, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)
            t += 1_000
        }

        // The same "impossible" position, over and over. After a few rejections
        // the filter must conclude that its own estimate is the wrong one -
        // otherwise an agent who steps out from behind a shed is stranded.
        val elsewhere = offset(origin, 0.0, 400.0)
        var out = stabilizer.update(elsewhere, 4.0, 0.0, t)
        repeat(6) {
            t += 1_000
            out = stabilizer.update(elsewhere, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)
        }

        assertTrue(
            "the filter must eventually believe a persistent relocation",
            distanceM(elsewhere, out.position) < 5.0,
        )
    }

    @Test
    fun `a fix claiming implausible accuracy is not blindly trusted`() {
        // A receiver reporting 0.1 m accuracy while 8 m off must not be allowed
        // to yank the estimate onto itself in one step.
        val stabilizer = PositionStabilizer()
        var t = 1_000L
        repeat(15) {
            stabilizer.update(origin, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)
            t += 1_000
        }

        val overconfident = offset(origin, 8.0, 0.0)
        val out = stabilizer.update(overconfident, accuracyM = 0.1, speedMps = 0.0, timestampMs = t)
        assertTrue(
            "an over-confident fix moved the estimate ${distanceM(origin, out.position)} m in one step",
            distanceM(origin, out.position) < 1.0,
        )
    }

    @Test
    fun `re-anchoring the internal frame does not move the estimate`() {
        val stabilizer = PositionStabilizer()
        var t = 1_000L
        stabilizer.update(origin, 4.0, 0.0, t)

        // Walk 120 m, well past REANCHOR_DISTANCE_M, in steady steps.
        var truth = origin
        var out = LatLng(0.0, 0.0)
        val steps = mutableListOf<Double>()
        repeat(80) {
            t += 1_000
            truth = offset(truth, 0.0, 1.5)
            val next = stabilizer.update(truth, accuracyM = 4.0, speedMps = 1.5, timestampMs = t)
            if (it > 5) steps += next.shiftM
            out = next.position
        }

        // If a re-anchor leaked, one step would be far bigger than its neighbours.
        val worst = steps.max()
        assertTrue("re-anchor produced a $worst m jump", worst < 4.0)
        assertEquals(0.0, distanceM(truth, out), 6.0)
    }

    /**
     * Regression test for an overlay stranded 97 km from the plot.
     *
     * The rejection hold used to be bounded only by a count of fixes. That is
     * not a bound at all: four samples is four seconds at 1 Hz and *forever* at
     * 0 Hz. The simulator publishes a fix only when something happens, so one
     * wild fix was rejected and no second fix ever arrived to break the hold -
     * and the same thing would happen to a real receiver that dropped out right
     * after a bad fix.
     */
    @Test
    fun `a rejection cannot hold longer than its wall-clock cap`() {
        val stabilizer = PositionStabilizer()
        var t = 1_000L
        stabilizer.update(origin, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)

        val elsewhere = offset(origin, 0.0, 400.0)

        // One outlier, held.
        t += 1_000
        val held = stabilizer.update(elsewhere, 4.0, 0.0, t)
        assertTrue(held.rejectedOutlier)

        // The receiver then goes quiet for a while. The very next fix, however
        // long it took to arrive, must not still be gated against a stale
        // estimate: no count of fixes will ever be reached.
        t += 30_000
        val resumed = stabilizer.update(elsewhere, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)
        assertTrue(
            "estimate stranded ${distanceM(elsewhere, resumed.position)} m from the fix",
            distanceM(elsewhere, resumed.position) < 5.0,
        )
    }

    @Test
    fun `reset makes the next fix a fresh start rather than an outlier`() {
        // A teleport is not a GNSS observation. Filtering one against an estimate
        // anchored somewhere else gates it as a wild outlier, which is how the
        // simulator ended up 97 km from the plot it was supposed to be showing.
        val stabilizer = PositionStabilizer()
        var t = 1_000L
        repeat(10) {
            stabilizer.update(origin, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)
            t += 1_000
        }

        val farAway = offset(origin, 0.0, 90_000.0)
        stabilizer.reset()
        val out = stabilizer.update(farAway, accuracyM = 4.0, speedMps = 0.0, timestampMs = t)

        assertFalse("a fix after reset must not be gated", out.rejectedOutlier)
        assertEquals(0.0, distanceM(farAway, out.position), 1.0)
    }
}
