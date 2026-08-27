package com.fieldar.plotfinder.core.geo

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sqrt

/**
 * Holds the agent's position still while they are standing still.
 *
 * A raw GNSS fix wanders by several metres from one second to the next even on a
 * phone lying motionless on a wall. Feeding that straight into the camera pose
 * makes the boundary swim, which reads to a farmer as "the app does not know
 * where my field is" - and they are not wrong to read it that way.
 *
 * The approach is the standard one from pedestrian navigation, not an invention:
 * a zero-velocity detector gates a constant-position Kalman filter, one scalar
 * filter per horizontal axis. See Chen et al., *Adaptive Kalman filtering-based
 * pedestrian navigation algorithm for smartphones* (Int. J. Adv. Robotic Systems
 * 17(3), 2020) and *A Continuous PDR and GNSS Fusing Algorithm for Smartphone
 * Positioning* (Remote Sensing 14(20):5171).
 *
 * The whole behaviour falls out of two numbers:
 *
 *  - **process noise** says how fast the true position may be changing. While
 *    stationary it is set to a couple of centimetres per second, so the
 *    estimate's variance stays small, the Kalman gain collapses towards zero and
 *    new fixes barely move the estimate: the overlay locks. While walking it
 *    opens up to roughly a brisk pace, the gain rises and the estimate tracks.
 *  - **measurement noise** is the receiver's own reported accuracy, squared. A
 *    fix that admits it is poor is automatically trusted less, with no threshold
 *    to tune.
 *
 * Nothing here does dead reckoning between fixes. Integrating accelerometers on
 * a hand-held phone drifts metres within seconds, which would trade a visible
 * jitter for an invisible bias - much worse for a boundary someone is about to
 * argue over.
 */

/** Below this ground speed the agent counts as standing still. */
const val STATIONARY_SPEED_MPS = 0.35

/** Assumed rate of true position change while stationary. Small on purpose. */
private const val STATIONARY_PROCESS_NOISE_MPS = 0.02

/** Assumed rate of true position change while walking, a brisk pace. */
private const val WALKING_PROCESS_NOISE_MPS = 1.6

/**
 * Floor on the accuracy a fix is allowed to claim.
 *
 * Android receivers routinely report 1 m or better when the true error is
 * several. Believing that verbatim makes the filter over-confident and it starts
 * ignoring good fixes, so no measurement is ever treated as sharper than this.
 */
private const val MIN_TRUSTED_ACCURACY_M = 3.0

/** Innovation beyond this many sigma is treated as an outlier and held back. */
private const val OUTLIER_SIGMA = 3.0

/**
 * Consecutive rejections after which the filter gives up and jumps.
 *
 * Without it, a genuine relocation - walking out from behind a shed, or a cold
 * receiver settling onto a better constellation - would be rejected forever and
 * the overlay would stay confidently wrong.
 */
private const val MAX_CONSECUTIVE_REJECTIONS = 4

/**
 * Wall-clock cap on how long a rejection may hold, whatever the fix count.
 *
 * A count alone is not a bound. Four samples is four seconds at 1 Hz and
 * *forever* at 0 Hz, so a receiver that goes quiet immediately after one wild
 * fix would strand the estimate on a stale position indefinitely - which is
 * precisely the "the boundary does not move" failure this class exists to fix,
 * reintroduced from the other direction. Whichever limit is reached first wins.
 */
private const val MAX_REJECTION_HOLD_MS = 5_000L

/**
 * How fast the *drawn* position may move while the agent is standing still.
 *
 * The Kalman estimate above is built to be unbiased, which is the right goal for
 * an estimator and the wrong one for something a person is looking at. An
 * unbiased estimate still twitches: each fix nudges it a few centimetres, and
 * because the overlay is redrawn from it, the boundary and the crop-health
 * patches twitch with it. On a phone held to the eye that reads as the field
 * sliding around, which is the single complaint this whole feature keeps
 * attracting.
 *
 * So the estimate and the thing that gets drawn are separated. The estimate
 * tracks the receiver; the drawn position *chases* the estimate at a bounded
 * rate. Standing still, 8 cm/s means a 1 m disagreement takes twelve seconds to
 * absorb - far below the threshold where the eye reads motion, while still
 * converging long before the agent has finished looking at anything.
 *
 * This trades accuracy for stability on purpose, and the trade is the right way
 * round here: the agent is looking for *which* corner of a field is failing, and
 * a boundary that sits still while being half a metre out is worth far more than
 * one that is unbiased and never settles.
 */
private const val RENDER_SLEW_STATIONARY_MPS = 0.08

/**
 * The same bound while walking, set above walking pace so it never lags a real
 * walk. Its job is only to reject the sudden metre-scale jumps a receiver makes
 * when its satellite geometry changes - which are not walks, whatever the speed
 * field says.
 */
private const val RENDER_SLEW_WALKING_MPS = 2.0

/**
 * Beyond this the drawn position stops chasing and snaps.
 *
 * At 8 cm/s a genuine relocation - an agent who drove to the next field with the
 * screen on - would take minutes to catch up, and would spend those minutes
 * drawing a boundary that is somewhere else entirely. Slewing is for suppressing
 * noise, not for hiding the truth.
 */
private const val RENDER_SNAP_M = 10.0

/** What the stabiliser believes, and how sure it is. */
data class StabilizedPosition(
    val position: LatLng,
    /** 1-sigma horizontal uncertainty of the estimate, in metres. */
    val uncertaintyM: Double,
    val stationary: Boolean,
    /** How far this estimate moved from the previous one, in metres. */
    val shiftM: Double,
    /** True when the fix was too far from the estimate to be believed. */
    val rejectedOutlier: Boolean,
)

class PositionStabilizer(
    private val stationarySpeedMps: Double = STATIONARY_SPEED_MPS,
) {
    /**
     * Internal metric frame. The filter runs in metres, never in degrees: a
     * variance expressed in degrees would mean two different distances on the
     * two axes and the filter would be anisotropic for no physical reason.
     */
    private var frame: EnuFrame? = null

    private var east = 0.0
    private var north = 0.0
    private var varEast = 0.0
    private var varNorth = 0.0
    private var lastFixMs = 0L
    private var rejections = 0
    private var firstRejectionAtMs = 0L

    /** Last published estimate, for reporting frame-to-frame shift. */
    private var lastPublished: LatLng? = null

    /**
     * The drawn position, in the active frame's metres.
     *
     * Deliberately not the filter's own estimate - see [RENDER_SLEW_STATIONARY_MPS].
     * Held in the same frame as [east]/[north] so re-anchoring moves both
     * together and the slew never sees a jump that is really a change of origin.
     */
    private var renderEast = 0.0
    private var renderNorth = 0.0
    private var renderSeeded = false
    private var lastPublishMs = 0L

    var stationary: Boolean = false
        private set

    /** Current 1-sigma horizontal uncertainty, metres. Zero before the first fix. */
    val uncertaintyM: Double get() = sqrt((varEast + varNorth) / 2.0)

    /**
     * Folds one fix into the estimate.
     *
     * @param speedMps Doppler-derived ground speed when the receiver provides it.
     *   It is a far better motion cue than differencing successive positions,
     *   because it does not inherit the positions' noise. Pass `null` when the
     *   fix carries no speed and the displacement fallback will be used instead.
     */
    fun update(
        position: LatLng,
        accuracyM: Double,
        speedMps: Double?,
        timestampMs: Long,
    ): StabilizedPosition {
        val existing = frame
        if (existing == null) {
            return seed(position, accuracyM, timestampMs)
        }

        // Keep the working frame near the agent so the equirectangular
        // approximation stays sub-metre, and so east/north never grow large
        // enough to lose precision against the variances.
        val active = if (existing.needsReanchor(estimateLatLng(existing))) {
            reanchor(existing)
        } else {
            existing
        }

        val measured = active.toEnu(position)
        val dtS = ((timestampMs - lastFixMs).coerceAtLeast(0L)) / 1000.0
        lastFixMs = timestampMs

        stationary = isStationary(speedMps, measured, dtS)

        // --- predict -------------------------------------------------------
        // Constant-position model: the estimate does not move on its own, only
        // its uncertainty grows, at the rate the motion state implies.
        val processNoiseMps =
            if (stationary) STATIONARY_PROCESS_NOISE_MPS else WALKING_PROCESS_NOISE_MPS
        val growth = (processNoiseMps * dtS) * (processNoiseMps * dtS)
        varEast += growth
        varNorth += growth

        // --- gate ----------------------------------------------------------
        val measurementVariance = trustedAccuracy(accuracyM).let { it * it }
        val innovationE = measured.east - east
        val innovationN = measured.north - north
        val gateE = OUTLIER_SIGMA * sqrt(varEast + measurementVariance)
        val gateN = OUTLIER_SIGMA * sqrt(varNorth + measurementVariance)

        if (abs(innovationE) > gateE || abs(innovationN) > gateN) {
            if (rejections == 0) firstRejectionAtMs = timestampMs
            rejections++
            val heldForMs = timestampMs - firstRejectionAtMs
            if (rejections < MAX_CONSECUTIVE_REJECTIONS && heldForMs < MAX_REJECTION_HOLD_MS) {
                // Hold the estimate but let the uncertainty keep growing, so a
                // genuinely relocated agent is believed within a few seconds.
                return publish(active, rejectedOutlier = true)
            }
            // Persistent disagreement means the estimate, not the fix, is wrong.
            return seed(position, accuracyM, timestampMs)
        }
        rejections = 0

        // --- correct -------------------------------------------------------
        val gainE = varEast / (varEast + measurementVariance)
        val gainN = varNorth / (varNorth + measurementVariance)
        east += gainE * innovationE
        north += gainN * innovationN
        varEast *= (1.0 - gainE)
        varNorth *= (1.0 - gainN)

        return publish(active, rejectedOutlier = false)
    }

    /** Forgets everything. Used when an AR session starts. */
    /**
     * Forgets everything.
     *
     * Called when the agent's position changes discontinuously for a reason that
     * is *not* measurement noise - starting a session, or the simulator being
     * teleported. Such a jump is not an observation to be filtered against the
     * old estimate; the old estimate no longer refers to anything.
     */
    fun reset() {
        frame = null
        lastPublished = null
        rejections = 0
        firstRejectionAtMs = 0L
        stationary = false
        renderSeeded = false
        lastPublishMs = 0L
    }

    private fun seed(position: LatLng, accuracyM: Double, timestampMs: Long): StabilizedPosition {
        val fresh = EnuFrame(position)
        frame = fresh
        east = 0.0
        north = 0.0
        val accuracy = trustedAccuracy(accuracyM)
        varEast = accuracy * accuracy
        varNorth = accuracy * accuracy
        lastFixMs = timestampMs
        rejections = 0
        firstRejectionAtMs = 0L
        stationary = false
        // A seed is a discontinuity by definition - first fix, or an estimate
        // abandoned as wrong. There is nothing to slew away from.
        renderEast = 0.0
        renderNorth = 0.0
        renderSeeded = true
        lastPublishMs = timestampMs
        return publish(fresh, rejectedOutlier = false, atMs = timestampMs)
    }

    private fun reanchor(previous: EnuFrame): EnuFrame {
        // Re-express the estimate against a new origin. Only the origin changes:
        // the estimate and its variance are physical quantities and survive
        // untouched, so re-anchoring is invisible on screen.
        val here = estimateLatLng(previous)
        val fresh = EnuFrame(here)
        frame = fresh
        // The drawn position is carried across as a displacement from the
        // estimate, not reset. It is a physical place; only the origin changed.
        renderEast -= east
        renderNorth -= north
        east = 0.0
        north = 0.0
        return fresh
    }

    private fun estimateLatLng(against: EnuFrame): LatLng =
        against.toLatLng(Enu(east, north))

    private fun publish(
        active: EnuFrame,
        rejectedOutlier: Boolean,
        atMs: Long = lastFixMs,
    ): StabilizedPosition {
        advanceRender(atMs)

        val here = active.toLatLng(Enu(renderEast, renderNorth))
        val shift = lastPublished?.let { distanceM(it, here) } ?: 0.0
        lastPublished = here
        return StabilizedPosition(
            position = here,
            uncertaintyM = uncertaintyM,
            stationary = stationary,
            shiftM = shift,
            rejectedOutlier = rejectedOutlier,
        )
    }

    /**
     * Moves the drawn position toward the estimate, at most so far.
     *
     * The cap is on *distance*, applied along the line to the estimate, rather
     * than per axis. A per-axis cap would let a diagonal correction travel
     * sqrt(2) times the intended rate and would bend the path toward the axes,
     * which is visible as the overlay sidling rather than sliding.
     */
    private fun advanceRender(atMs: Long) {
        if (!renderSeeded) {
            renderEast = east
            renderNorth = north
            renderSeeded = true
            lastPublishMs = atMs
            return
        }

        val dtS = ((atMs - lastPublishMs).coerceAtLeast(0L)) / 1000.0
        lastPublishMs = atMs

        val gapE = east - renderEast
        val gapN = north - renderNorth
        val gap = hypot(gapE, gapN)
        if (gap < 1e-6) return

        if (gap > RENDER_SNAP_M) {
            renderEast = east
            renderNorth = north
            return
        }

        val limit = (if (stationary) RENDER_SLEW_STATIONARY_MPS else RENDER_SLEW_WALKING_MPS) * dtS
        if (limit >= gap) {
            renderEast = east
            renderNorth = north
        } else {
            renderEast += gapE / gap * limit
            renderNorth += gapN / gap * limit
        }
    }

    /**
     * Doppler speed decides when the receiver reports it. Otherwise fall back to
     * asking whether the displacement since the last estimate is bigger than the
     * noise that displacement is measured with - below that, "moved" and "did
     * not move" are indistinguishable and standing still is the safer reading.
     */
    private fun isStationary(speedMps: Double?, measured: Enu, dtS: Double): Boolean {
        if (speedMps != null) return speedMps < stationarySpeedMps
        if (dtS <= 0.0) return stationary
        val displacement = hypot(measured.east - east, measured.north - north)
        return displacement / dtS < stationarySpeedMps
    }

    private fun trustedAccuracy(reported: Double): Double =
        if (reported.isFinite() && reported > MIN_TRUSTED_ACCURACY_M) {
            reported
        } else {
            MIN_TRUSTED_ACCURACY_M
        }
}
