package com.fieldar.plotfinder.core.geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.hypot

class PolygonGeometryTest {

    /** A 100 m square with its south-west corner at the frame origin. */
    private val square = listOf(
        Enu(0.0, 0.0),
        Enu(100.0, 0.0),
        Enu(100.0, 100.0),
        Enu(0.0, 100.0),
        Enu(0.0, 0.0), // closing repeat, as GeoJSON delivers it
    )

    @Test
    fun `the closing repeat is dropped`() {
        assertEquals(4, openRing(square).size)
        assertEquals(3, openRing(listOf(Enu(0.0, 0.0), Enu(1.0, 0.0), Enu(0.0, 1.0))).size)
    }

    @Test
    fun `distance to a segment clamps at the endpoints`() {
        val a = Enu(0.0, 0.0)
        val b = Enu(100.0, 0.0)
        // Perpendicular from above the middle.
        assertEquals(20.0, distanceToSegmentM(Enu(50.0, 20.0), a, b), 1e-9)
        // Past the end, so the answer is the distance to the endpoint itself.
        assertEquals(30.0, distanceToSegmentM(Enu(130.0, 0.0), a, b), 1e-9)
        assertEquals(hypot(30.0, 40.0), distanceToSegmentM(Enu(130.0, 40.0), a, b), 1e-9)
    }

    @Test
    fun `a degenerate edge collapses to a point`() {
        val a = Enu(10.0, 10.0)
        assertEquals(5.0, distanceToSegmentM(Enu(15.0, 10.0), a, a), 1e-9)
    }

    @Test
    fun `nearest edge is measured from outside`() {
        assertEquals(20.0, distanceToNearestEdgeM(square, Enu(50.0, -20.0)), 1e-9)
        assertEquals(20.0, distanceToNearestEdgeM(square, Enu(120.0, 50.0)), 1e-9)
    }

    @Test
    fun `standing on the boundary reads zero`() {
        assertEquals(0.0, distanceToNearestEdgeM(square, Enu(50.0, 0.0)), 1e-9)
        assertEquals(0.0, distanceToNearestEdgeM(square, Enu(0.0, 0.0)), 1e-9)
    }

    @Test
    fun `from inside, the nearest edge is the closest wall`() {
        // 10 m in from the south edge of a 100 m square.
        assertEquals(10.0, distanceToNearestEdgeM(square, Enu(50.0, 10.0)), 1e-9)
        // Dead centre is 50 m from all four.
        assertEquals(50.0, distanceToNearestEdgeM(square, Enu(50.0, 50.0)), 1e-9)
    }

    @Test
    fun `near a corner the distance is the diagonal to the corner`() {
        assertEquals(hypot(20.0, 20.0), distanceToNearestEdgeM(square, Enu(-20.0, -20.0)), 1e-9)
    }

    @Test
    fun `an elongated plot switches on the edge, not the centroid`() {
        // 400 m x 40 m strip. The agent stands 5 m off its long south edge,
        // level with one end - near mode by any honest reading.
        val strip = listOf(
            Enu(0.0, 0.0),
            Enu(400.0, 0.0),
            Enu(400.0, 40.0),
            Enu(0.0, 40.0),
            Enu(0.0, 0.0),
        )
        val agent = Enu(20.0, -5.0)

        val edgeDistance = distanceToNearestEdgeM(strip, agent)
        val centroid = Enu(200.0, 20.0)
        val centroidDistance = hypot(centroid.east - agent.east, centroid.north - agent.north)

        assertEquals(5.0, edgeDistance, 1e-9)
        assertTrue(
            "centroid distance should be far outside near mode, was $centroidDistance",
            centroidDistance > 30.0,
        )
        assertTrue(edgeDistance < 30.0)
    }

    @Test
    fun `an empty ring is infinitely far away`() {
        assertEquals(
            Double.POSITIVE_INFINITY,
            distanceToNearestEdgeM(emptyList(), Enu(0.0, 0.0)),
            0.0,
        )
    }
}
