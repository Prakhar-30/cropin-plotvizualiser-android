package com.fieldar.plotfinder.core.geo

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Plot geometry in the local metric frame.
 *
 * The render mode switches on distance to the nearest **edge**, never to the
 * centroid: an elongated plot can have its centroid 60 m away while the agent is
 * standing on its boundary, and showing them a far-mode filled shape at that
 * point claims a precision the fix does not have.
 */

/** Distance from a point to a line segment, all in metres. */
fun distanceToSegmentM(point: Enu, a: Enu, b: Enu): Double {
    val abE = b.east - a.east
    val abN = b.north - a.north
    val lengthSq = abE * abE + abN * abN

    // A degenerate edge collapses to its own endpoint.
    if (lengthSq == 0.0) return hypot(point.east - a.east, point.north - a.north)

    val t = ((point.east - a.east) * abE + (point.north - a.north) * abN) / lengthSq
    val clamped = max(0.0, min(1.0, t))
    val closestE = a.east + clamped * abE
    val closestN = a.north + clamped * abN
    return hypot(point.east - closestE, point.north - closestN)
}

/**
 * Distance from [point] to the closest boundary edge of [ring], in metres.
 *
 * Zero when the point sits on the boundary, and positive both inside and
 * outside - the overlay cares how far the line is, not which side of it you are
 * standing on.
 */
fun distanceToNearestEdgeM(ring: List<Enu>, point: Enu): Double {
    val vertices = openRing(ring)
    if (vertices.isEmpty()) return Double.POSITIVE_INFINITY
    if (vertices.size == 1) return hypot(point.east - vertices[0].east, point.north - vertices[0].north)

    var nearest = Double.POSITIVE_INFINITY
    for (i in vertices.indices) {
        val a = vertices[i]
        val b = vertices[(i + 1) % vertices.size]
        nearest = min(nearest, distanceToSegmentM(point, a, b))
    }
    return nearest
}

/**
 * Drops the repeated closing vertex a GeoJSON ring carries.
 *
 * Left in place it produces a zero-length edge, which is harmless for distance
 * but draws a stray vertex post on top of another one.
 */
fun openRing(ring: List<Enu>): List<Enu> {
    if (ring.size < 2) return ring
    val first = ring.first()
    val last = ring.last()
    val closed = hypot(first.east - last.east, first.north - last.north) < 1e-6
    return if (closed) ring.dropLast(1) else ring
}
