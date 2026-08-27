package com.fieldar.plotfinder.core.geo

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sqrt

/**
 * Conversion between WGS84 degrees and a local East-North-Up metric frame.
 *
 * Every piece of geometry in this app happens in metres. Degrees are converted
 * once, at the edge, and never used for distance, bearing or projection - a
 * degree of longitude is 108.5 m here and 111.3 m at the equator, so anything
 * computed in raw degrees is wrong by a different amount in each direction.
 *
 * The equirectangular approximation below is accurate to well under a metre at
 * the few-hundred-metre ranges this app works over, which is far inside the
 * GNSS error it is drawn against.
 */

const val METRES_PER_DEG_LAT = 110_540.0
const val METRES_PER_DEG_LNG_AT_EQUATOR = 111_320.0

/** Re-anchor the frame once the agent has walked this far from the origin. */
const val REANCHOR_DISTANCE_M = 50.0

/** Plot geometry is drawn on the ground, this far below the phone. */
const val EYE_HEIGHT_M = 1.6

data class LatLng(val lat: Double, val lng: Double)

/** A point in the local metric frame. `up` is metres above the origin. */
data class Enu(val east: Double, val north: Double, val up: Double = 0.0) {
    /** Straight-line distance from the frame origin. */
    val range: Double get() = sqrt(east * east + north * north + up * up)

    /** Distance ignoring height, which is what "how far do I walk" means. */
    val groundRange: Double get() = hypot(east, north)

    /** Compass bearing from the origin to this point, degrees clockwise from north. */
    val bearingDeg: Double get() = normalizeDeg(Math.toDegrees(atan2(east, north)))
}

/**
 * A local frame anchored at one GNSS fix.
 *
 * The frame is immutable: moving the anchor means building a new one, which
 * makes it impossible to convert two points against different origins by
 * accident.
 */
class EnuFrame(val origin: LatLng) {

    /** Metres per degree of longitude shrinks with the cosine of the latitude. */
    private val metresPerDegLng = cos(Math.toRadians(origin.lat)) * METRES_PER_DEG_LNG_AT_EQUATOR

    fun toEnu(point: LatLng, up: Double = 0.0): Enu = Enu(
        east = (point.lng - origin.lng) * metresPerDegLng,
        north = (point.lat - origin.lat) * METRES_PER_DEG_LAT,
        up = up,
    )

    fun toLatLng(point: Enu): LatLng = LatLng(
        lat = origin.lat + point.north / METRES_PER_DEG_LAT,
        lng = origin.lng + point.east / metresPerDegLng,
    )

    /** Ground distance from the anchor, in metres. */
    fun distanceFromOrigin(point: LatLng): Double = toEnu(point).groundRange

    /**
     * True once the agent has walked far enough that the approximation, and the
     * accumulated rounding in it, deserve a fresh anchor.
     */
    fun needsReanchor(current: LatLng): Boolean =
        distanceFromOrigin(current) > REANCHOR_DISTANCE_M
}

/**
 * Compass bearing from one position to another, degrees clockwise from north.
 *
 * Computed through the same local metric frame the overlay uses, so a landmark
 * snap and the rendered geometry can never disagree about which way a feature is.
 */
fun bearingDeg(from: LatLng, to: LatLng): Double = EnuFrame(from).toEnu(to).bearingDeg

/** Ground distance between two positions, in metres. */
fun distanceM(from: LatLng, to: LatLng): Double = EnuFrame(from).toEnu(to).groundRange

/** Folds any angle into `[0, 360)`. */
fun normalizeDeg(deg: Double): Double {
    val wrapped = deg % 360.0
    return if (wrapped < 0) wrapped + 360.0 else wrapped
}

/**
 * Shortest signed turn from `a` to `b`, in `(-180, 180]`.
 *
 * Every heading comparison in the app goes through this. Subtracting headings
 * directly makes 359 and 1 look 358 degrees apart instead of 2, which would
 * reject a perfectly straight walk that happens to cross north.
 */
fun angleDifferenceDeg(a: Double, b: Double): Double {
    val diff = normalizeDeg(b - a)
    return if (diff > 180.0) diff - 360.0 else diff
}

/**
 * Circular mean of a set of bearings, and how tightly they cluster.
 *
 * Returned spread is the mean absolute deviation from that mean, in degrees;
 * the straight-segment detector thresholds on it.
 */
fun bearingStatistics(bearings: List<Double>): BearingStatistics? {
    if (bearings.isEmpty()) return null
    var sumSin = 0.0
    var sumCos = 0.0
    for (b in bearings) {
        val r = Math.toRadians(b)
        sumSin += kotlin.math.sin(r)
        sumCos += cos(r)
    }
    val mean = normalizeDeg(Math.toDegrees(atan2(sumSin, sumCos)))
    val spread = bearings.sumOf { abs(angleDifferenceDeg(mean, it)) } / bearings.size
    return BearingStatistics(mean, spread)
}

data class BearingStatistics(val meanDeg: Double, val spreadDeg: Double)
