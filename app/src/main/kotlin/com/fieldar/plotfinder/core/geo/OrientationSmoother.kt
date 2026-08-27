package com.fieldar.plotfinder.core.geo

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Takes the shimmer out of the device orientation.
 *
 * This matters more than the position filter did, and for a reason worth
 * stating: position error moves the overlay by a fixed number of metres, but
 * orientation error moves it by an amount that grows with range. At 50 m, one
 * degree of jitter swings a boundary 0.87 m sideways; at 150 m it is 2.6 m.
 * Android's rotation vector wobbles by a degree or two even on a phone lying on
 * a table, so an unfiltered pose is worth several metres of visible movement -
 * far more than the raw GNSS jitter that was fixed first.
 *
 * The filter is speed-adaptive, following the 1-euro filter (Casiez, Roussel and
 * Vogel, CHI 2012): smooth hard when the phone is nearly still, and barely at
 * all when it is being deliberately turned. A fixed low-pass cannot win here -
 * set it heavy enough to kill the shimmer and the overlay lags visibly behind
 * the camera when you pan; set it light enough to keep up and the shimmer comes
 * straight back. Tying the time constant to the measured angular rate gets both,
 * because jitter and intent live at different speeds.
 *
 * Interpolation is spherical, on quaternions. Averaging rotation matrices
 * element-wise does not produce a rotation - the result is not orthonormal, and
 * it shears the overlay rather than turning it.
 */

/** Time constant while the phone is held still. Heavy: kills the shimmer. */
private const val STEADY_TAU_S = 0.65

/** Time constant while the phone is being turned. Light: catches up fast. */
private const val AGILE_TAU_S = 0.05

/**
 * Deviation from the current estimate that counts as fully deliberate motion.
 *
 * Adapting on *deviation* rather than on frame-to-frame angular rate is the
 * whole trick, and getting it wrong the first time is instructive: jitter of a
 * degree and a half arriving every 20 ms is an instantaneous rate of 75 deg/s,
 * which looks exactly like a deliberate pan and defeats the filter completely.
 *
 * Deviation separates them cleanly instead. Jitter is bounded by its own
 * amplitude no matter how fast it arrives, because the estimate sits at the
 * middle of it. A genuine turn makes the estimate fall behind, and the gap
 * grows until the filter speeds up to close it.
 *
 * Raised from 10 degrees after field testing. Walking is not a still phone with
 * noise on top: each footfall pitches and rolls the handset by several degrees,
 * and an arm swing adds more. At 10 degrees that ordinary gait was reading as
 * deliberate motion, so the filter went agile with every step and passed the
 * bounce straight through to the overlay - the boundary jogging along with the
 * walk. A deliberate pan is 60 degrees or more and still clears this bar
 * immediately, so nothing was given up to buy it.
 */
private const val AGILE_DEVIATION_DEG = 25.0

/**
 * Time constant for the deviation measure itself.
 *
 * Without it the agility term is driven by a single noisy sample and the filter
 * flickers between smooth and responsive from frame to frame - which is its own
 * kind of visible instability.
 *
 * Lengthened to 0.3 s alongside the deviation threshold. A footfall disturbance
 * lasts about 0.2 s; at the old 0.15 s the measure could rise far enough within
 * a single step to unlock the filter. Averaging over longer than one step means
 * a step cannot, while a turn - which lasts a second or more - still can.
 */
private const val DEVIATION_TAU_S = 0.30

/** Longest gap that is still treated as continuous. Beyond it, re-seed. */
private const val MAX_GAP_S = 0.5

/** Unit quaternion. `w` is the scalar part. */
data class Quat(val w: Double, val x: Double, val y: Double, val z: Double) {
    fun normalized(): Quat {
        val n = sqrt(w * w + x * x + y * y + z * z)
        return if (n < 1e-12) IDENTITY else Quat(w / n, x / n, y / n, z / n)
    }

    operator fun unaryMinus(): Quat = Quat(-w, -x, -y, -z)

    companion object {
        val IDENTITY = Quat(1.0, 0.0, 0.0, 0.0)
    }
}

fun Quat.dot(other: Quat): Double = w * other.w + x * other.x + y * other.y + z * other.z

/**
 * Rotation matrix to quaternion, by Shepperd's method.
 *
 * The branch on the largest diagonal term is not an optimisation: the naive
 * `sqrt(trace + 1)` form divides by a value that approaches zero for rotations
 * near 180 degrees, and a phone turned to face behind the agent is exactly that
 * case.
 */
fun Mat3.toQuat(): Quat {
    val trace = m00 + m11 + m22
    return when {
        trace > 0.0 -> {
            val s = sqrt(trace + 1.0) * 2.0
            Quat(0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s)
        }
        m00 > m11 && m00 > m22 -> {
            val s = sqrt(1.0 + m00 - m11 - m22) * 2.0
            Quat((m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s)
        }
        m11 > m22 -> {
            val s = sqrt(1.0 + m11 - m00 - m22) * 2.0
            Quat((m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s)
        }
        else -> {
            val s = sqrt(1.0 + m22 - m00 - m11) * 2.0
            Quat((m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s)
        }
    }.normalized()
}

fun Quat.toMat3(): Mat3 {
    val q = normalized()
    val (w, x, y, z) = q
    return Mat3(
        1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y),
        2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x),
        2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y),
    )
}

/** Angle between two orientations, in degrees. */
fun angleBetweenDeg(a: Quat, b: Quat): Double {
    val d = abs(a.normalized().dot(b.normalized())).coerceIn(-1.0, 1.0)
    return Math.toDegrees(2.0 * acos(d))
}

/**
 * Spherical linear interpolation, taking the shorter arc.
 *
 * `q` and `-q` are the same rotation, so without the sign flip an interpolation
 * can take the long way round and spin the overlay through most of a circle to
 * reach an orientation a fraction of a degree away.
 */
fun slerp(from: Quat, to: Quat, t: Double): Quat {
    val a = from.normalized()
    var b = to.normalized()
    var cosine = a.dot(b)
    if (cosine < 0.0) {
        b = -b
        cosine = -cosine
    }

    // Nearly parallel: sin(theta) underflows, so interpolate linearly instead.
    if (cosine > 0.9995) {
        return Quat(
            a.w + t * (b.w - a.w),
            a.x + t * (b.x - a.x),
            a.y + t * (b.y - a.y),
            a.z + t * (b.z - a.z),
        ).normalized()
    }

    val theta = acos(cosine.coerceIn(-1.0, 1.0))
    val sinTheta = sin(theta)
    val wa = sin((1.0 - t) * theta) / sinTheta
    val wb = sin(t * theta) / sinTheta
    return Quat(
        wa * a.w + wb * b.w,
        wa * a.x + wb * b.x,
        wa * a.y + wb * b.y,
        wa * a.z + wb * b.z,
    ).normalized()
}

class OrientationSmoother(
    private val steadyTauS: Double = STEADY_TAU_S,
    private val agileTauS: Double = AGILE_TAU_S,
    private val agileDeviationDeg: Double = AGILE_DEVIATION_DEG,
) {
    private var smoothed: Quat? = null
    private var lastSampleMs = 0L
    private var deviationDeg = 0.0

    /** How far the raw sample currently sits from the estimate. For telemetry. */
    val trackingErrorDeg: Double get() = deviationDeg

    /**
     * Folds one sensor sample in and returns the orientation to draw with.
     *
     * @param timestampMs monotonic; only differences are used.
     */
    fun update(sample: Mat3, timestampMs: Long): Mat3 {
        val target = sample.toQuat()
        val previous = smoothed
        val dtS = (timestampMs - lastSampleMs) / 1000.0
        lastSampleMs = timestampMs

        // First sample, or a gap long enough that the phone could be anywhere:
        // interpolating across it would drag the overlay through every
        // orientation in between.
        if (previous == null || dtS <= 0.0 || dtS > MAX_GAP_S) {
            smoothed = target
            deviationDeg = 0.0
            return target.toMat3()
        }

        // Low-pass the deviation before it steers anything, so one noisy sample
        // cannot flip the filter between smooth and responsive.
        val instant = angleBetweenDeg(previous, target)
        val deviationAlpha = 1.0 - exp(-dtS / DEVIATION_TAU_S)
        deviationDeg += deviationAlpha * (instant - deviationDeg)

        // Slide between the two time constants by how far behind the estimate is.
        val agility = (deviationDeg / agileDeviationDeg).coerceIn(0.0, 1.0)
        val tau = steadyTauS + (agileTauS - steadyTauS) * agility

        // Exponential smoothing expressed against elapsed time rather than a
        // fixed per-sample weight, so the behaviour does not change when the
        // sensor delivers at a different rate on a different handset.
        val alpha = 1.0 - exp(-dtS / tau)

        val next = slerp(previous, target, alpha.coerceIn(0.0, 1.0))
        smoothed = next
        return next.toMat3()
    }

    /** Forgets the current estimate; the next sample is taken as-is. */
    fun reset() {
        smoothed = null
        lastSampleMs = 0L
        deviationDeg = 0.0
    }
}
