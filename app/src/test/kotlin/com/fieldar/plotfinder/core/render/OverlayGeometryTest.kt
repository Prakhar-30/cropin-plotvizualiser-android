package com.fieldar.plotfinder.core.render

import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.METRES_PER_DEG_LAT
import com.fieldar.plotfinder.core.geo.Vec3
import com.fieldar.plotfinder.core.geo.clipToNearPlane
import com.fieldar.plotfinder.core.geo.deviceToEnuFromOrientation
import com.fieldar.plotfinder.core.geo.isOnScreen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos

class OverlayGeometryTest {

    private val agent = LatLng(12.7862, 76.7201)
    private val frame = EnuFrame(agent)
    private val intrinsics = CameraIntrinsics(60.0, 1080, 1920)
    private val metresPerDegLng = cos(Math.toRadians(agent.lat)) * 111_320.0

    /** Offsets a position by metres, using the same model the frame does. */
    private fun offset(from: LatLng, eastM: Double, northM: Double) = LatLng(
        lat = from.lat + northM / METRES_PER_DEG_LAT,
        lng = from.lng + eastM / metresPerDegLng,
    )

    /** A square of `size` metres whose south-west corner is `awayM` north of the agent. */
    private fun square(size: Double, awayM: Double): List<LatLng> {
        val sw = offset(agent, -size / 2, awayM)
        return listOf(
            sw,
            offset(sw, size, 0.0),
            offset(sw, size, size),
            offset(sw, 0.0, size),
            sw,
        )
    }

    private fun centroidOf(ring: List<LatLng>): LatLng {
        val open = ring.dropLast(1)
        return LatLng(open.sumOf { it.lat } / open.size, open.sumOf { it.lng } / open.size)
    }

    private fun overlay(
        ring: List<LatLng>,
        headingDeg: Double = 0.0,
        pitchDeg: Double = 0.0,
        accuracyM: Double = 6.0,
        agentAt: LatLng = agent,
    ) = buildPlotOverlay(
        ring = ring,
        centroid = centroidOf(ring),
        agent = agentAt,
        frame = frame,
        deviceToEnu = deviceToEnuFromOrientation(headingDeg, pitchDeg),
        intrinsics = intrinsics,
        gnssAccuracyM = accuracyM,
    )

    @Test
    fun `a distant plot renders in far mode with a filled shape and posts`() {
        val result = overlay(square(size = 100.0, awayM = 80.0))

        assertEquals(RenderMode.FAR, result.mode)
        assertEquals(80.0, result.edgeDistanceM, 0.5)
        assertTrue("fill should be a closed shape", result.fill.size >= 4)
        assertEquals("one post per corner", 4, result.posts.size)
        assertTrue(result.bands.isEmpty())
        assertNotNull(result.label)
    }

    @Test
    fun `posts stand above their own bases`() {
        val result = overlay(square(size = 100.0, awayM = 80.0))
        for (post in result.posts) {
            assertTrue("post top must be higher on screen than its base", post.top.y < post.base.y)
            assertEquals("posts are vertical", post.base.x, post.top.x, 1.0f)
        }
    }

    @Test
    fun `standing near an edge switches to near mode and drops the fill`() {
        // Agent 10 m south of the plot's southern edge.
        val result = overlay(square(size = 100.0, awayM = 10.0))

        assertEquals(RenderMode.NEAR, result.mode)
        assertEquals(10.0, result.edgeDistanceM, 0.5)
        assertTrue("near mode must not claim a filled area", result.fill.isEmpty())
        assertTrue(result.posts.isEmpty())
        assertTrue(result.bands.isNotEmpty())
    }

    @Test
    fun `an elongated plot switches on its edge even with a far centroid`() {
        // 400 m long strip whose near edge is 8 m away; its centroid is 200 m off.
        val sw = offset(agent, -20.0, 8.0)
        val strip = listOf(
            sw,
            offset(sw, 400.0, 0.0),
            offset(sw, 400.0, 40.0),
            offset(sw, 0.0, 40.0),
            sw,
        )
        val result = overlay(strip)

        assertEquals(RenderMode.NEAR, result.mode)
        assertTrue(result.edgeDistanceM < NEAR_MODE_THRESHOLD_M)
        assertTrue(
            "centroid is far away, which is exactly why it must not drive the switch",
            result.centroidDistanceM > 100.0,
        )
    }

    @Test
    fun `a wider accuracy figure makes a wider band`() {
        // 25 m from the near edge, so even the wide band stays in front of the
        // camera and the comparison is about width alone, not clipping.
        val ring = square(size = 100.0, awayM = 25.0)
        val tight = overlay(ring, accuracyM = 3.0)
        val loose = overlay(ring, accuracyM = 12.0)

        // Compare screen area, not bounding box: the box is dominated by the
        // 100 m edge length, which is identical in both cases.
        val tightArea = bandArea(tight.bands.first())
        val looseArea = bandArea(loose.bands.first())
        assertTrue("$looseArea should be well over $tightArea", looseArea > tightArea * 2)
    }

    @Test
    fun `an excellent fix still draws a band rather than a hairline`() {
        val result = overlay(square(size = 100.0, awayM = 25.0), accuracyM = 0.1)
        assertTrue(bandArea(result.bands.first()) > 0f)
    }

    /** Shoelace area of the projected quad, in square pixels. */
    private fun bandArea(band: OverlayBand): Float {
        val c = band.corners
        var sum = 0.0f
        for (i in c.indices) {
            val n = c[(i + 1) % c.size]
            sum += c[i].x * n.y - n.x * c[i].y
        }
        return kotlin.math.abs(sum) / 2f
    }

    @Test
    fun `looking the wrong way reports a bearing for the edge arrow`() {
        val ring = square(size = 100.0, awayM = 120.0)
        // Facing due south while the plot is due north.
        val result = overlay(ring, headingDeg = 180.0)

        assertNotNull("nothing is on screen, so the arrow must have a bearing", result.offscreenBearingDeg)
        assertEquals(180.0, kotlin.math.abs(result.offscreenBearingDeg!!), 2.0)
        assertNull("a culled centroid has no label", result.label)
    }

    @Test
    fun `facing the plot needs no edge arrow`() {
        val result = overlay(square(size = 100.0, awayM = 120.0), headingDeg = 0.0)
        assertNull(result.offscreenBearingDeg)
        assertTrue(result.fill.any { it.isOnScreen(intrinsics) })
    }

    @Test
    fun `the arrow points the shorter way round`() {
        // Plot due north, agent facing 350: the plot is 10 deg to the right.
        val result = overlay(square(size = 40.0, awayM = 300.0), headingDeg = 300.0)
        val bearing = result.offscreenBearingDeg
        assertNotNull(bearing)
        assertEquals(60.0, bearing!!, 3.0)
    }

    @Test
    fun `standing inside a large plot clips the outline instead of reshaping it`() {
        // Centre of a 100 m square: every edge is 50 m off, so this is still far
        // mode, and the two corners behind the agent must be clipped rather than
        // dropped - dropping them would close the outline across the field.
        val sw = offset(agent, -50.0, -50.0)
        val ring = listOf(sw, offset(sw, 100.0, 0.0), offset(sw, 100.0, 100.0), offset(sw, 0.0, 100.0), sw)
        val result = overlay(ring, agentAt = agent)

        assertEquals(RenderMode.FAR, result.mode)
        assertEquals(50.0, result.edgeDistanceM, 0.5)
        assertEquals(
            "two corners in front plus two new points on the clip plane",
            4,
            result.fill.size,
        )
        assertEquals("only the two corners in front can carry posts", 2, result.posts.size)
    }

    @Test
    fun `standing inside a small plot is near mode`() {
        // Centre of a 40 m square: 20 m to every edge.
        val sw = offset(agent, -20.0, -20.0)
        val ring = listOf(sw, offset(sw, 40.0, 0.0), offset(sw, 40.0, 40.0), offset(sw, 0.0, 40.0), sw)
        val result = overlay(ring, agentAt = agent)

        assertEquals(RenderMode.NEAR, result.mode)
        assertEquals(20.0, result.edgeDistanceM, 0.5)
        assertTrue("some edge must still be drawable", result.bands.isNotEmpty())
    }

    @Test
    fun `clipping keeps the visible part of a polygon crossing the near plane`() {
        // A square straddling the camera: two corners in front, two behind.
        val polygon = listOf(
            Vec3(-10.0, 0.0, -50.0), // 50 m in front
            Vec3(10.0, 0.0, -50.0),
            Vec3(10.0, 0.0, 50.0), // 50 m behind
            Vec3(-10.0, 0.0, 50.0),
        )
        val clipped = clipToNearPlane(polygon)

        assertEquals("two originals plus two new points on the plane", 4, clipped.size)
        assertTrue("nothing may survive behind the near plane", clipped.all { -it.z >= 0.499 })
    }

    @Test
    fun `a polygon entirely behind the camera clips to nothing`() {
        val behind = listOf(
            Vec3(-10.0, 0.0, 50.0),
            Vec3(10.0, 0.0, 50.0),
            Vec3(0.0, 0.0, 80.0),
        )
        assertTrue(clipToNearPlane(behind).isEmpty())
    }

    /**
     * Regression test for the bug the partners saw in the field.
     *
     * The frame stays anchored where the session started while the agent walks
     * 50 m towards the plot. The drawing must respond: the camera is at the
     * agent, not at the anchor. Before this was fixed, `buildPlotOverlay` used
     * the agent's position for the distance readouts only and projected every
     * vertex as though the camera sat on the frame origin - so the boundary held
     * a constant apparent distance and appeared to walk along with the agent,
     * while the label counted honestly down.
     */
    @Test
    fun `walking towards a plot moves the drawing, not just the label`() {
        val ring = square(size = 100.0, awayM = 100.0)

        val far = overlay(ring)
        val near = overlay(ring, agentAt = offset(agent, 0.0, 50.0))

        // The label numbers were always right; they are the control.
        assertEquals(150.0, far.centroidDistanceM, 0.5)
        assertEquals(100.0, near.centroidDistanceM, 0.5)

        val farLabel = far.label!!.at
        val nearLabel = near.label!!.at

        // Ground below eye height projects below the optical centre, and the
        // drop grows as the inverse of range: 1/100 against 1/150 is a factor
        // of exactly 1.5.
        val farDrop = farLabel.y - intrinsics.centreYPx
        val nearDrop = nearLabel.y - intrinsics.centreYPx
        assertTrue("ground should project below the optical centre", farDrop > 0)
        assertEquals(1.5, nearDrop / farDrop, 0.02)

        // The whole shape must move, not only the label.
        assertTrue(
            "the boundary must not hold a constant apparent position as the agent walks",
            near.fill.zip(far.fill).any { (n, f) -> kotlin.math.abs(n.y - f.y) > 1.0 }
        )
    }

    @Test
    fun `standing still with the frame anchored elsewhere still projects correctly`() {
        // A frame anchored 40 m away from the agent must give the same drawing
        // as one anchored on them: the anchor is bookkeeping, not a viewpoint.
        val ring = square(size = 100.0, awayM = 100.0)
        val displacedFrame = EnuFrame(offset(agent, 40.0, -25.0))

        val onAgent = overlay(ring)
        val displaced = buildPlotOverlay(
            ring = ring,
            centroid = centroidOf(ring),
            agent = agent,
            frame = displacedFrame,
            deviceToEnu = deviceToEnuFromOrientation(0.0, 0.0),
            intrinsics = intrinsics,
            gnssAccuracyM = 6.0,
        )

        assertEquals(onAgent.centroidDistanceM, displaced.centroidDistanceM, 0.2)
        assertEquals(onAgent.label!!.at.x.toDouble(), displaced.label!!.at.x.toDouble(), 1.0)
        assertEquals(onAgent.label!!.at.y.toDouble(), displaced.label!!.at.y.toDouble(), 1.0)
    }

    // --- vertical boundary walls --------------------------------------------

    @Test
    fun `every boundary edge becomes a standing panel with a top rail`() {
        val result = overlay(square(size = 100.0, awayM = 60.0))

        // A square has four edges; all four are in front of a camera 60 m south.
        assertEquals(4, result.walls.size)
        assertEquals(4, result.rails.size)
        assertTrue("panels need at least three corners", result.walls.all { it.quad.size >= 3 })
    }

    @Test
    fun `walls stand up on screen rather than lying flat`() {
        val result = overlay(square(size = 100.0, awayM = 60.0))

        // The rail is BOUNDARY_WALL_HEIGHT_M above the ground, so for a level
        // camera it must project above every point of the panel it caps. This is
        // the whole partner request in one assertion: a boundary with height.
        for ((wall, rail) in result.walls.zip(result.rails)) {
            val lowest = wall.quad.maxOf { it.y }
            val railY = maxOf(rail.from.y, rail.to.y)
            assertTrue(
                "rail at $railY should sit above the panel foot at $lowest",
                railY < lowest,
            )
        }
    }

    @Test
    fun `panels are ordered far to near so translucency composites correctly`() {
        val walls = overlay(square(size = 100.0, awayM = 60.0)).walls
        val distances = walls.map { it.nearestDistanceM }
        assertEquals(
            "walls must arrive sorted farthest first",
            distances.sortedDescending(),
            distances,
        )
    }

    @Test
    fun `walls are drawn in near mode too, where the ground fill is suppressed`() {
        val result = overlay(square(size = 100.0, awayM = 5.0))

        assertEquals(RenderMode.NEAR, result.mode)
        assertTrue("near mode drops the ground fill", result.fill.isEmpty())
        assertTrue("near mode keeps the standing boundary", result.walls.isNotEmpty())
    }

    @Test
    fun `a wall the agent is standing inside is clipped, not dropped`() {
        // Standing in the middle of the plot puts two edges behind the camera.
        // Those must still contribute clipped panels rather than vanishing, or
        // the boundary appears to open up behind the agent.
        //
        // 40 m rather than 100 m: the mode switch measures to the *nearest edge*,
        // and the centre of a 100 m square is 50 m from every one of them, which
        // is far mode however much it feels like being inside.
        val ring = square(size = 40.0, awayM = -20.0)
        val result = overlay(ring)

        assertEquals(RenderMode.NEAR, result.mode)
        assertTrue("some boundary must remain visible from inside", result.walls.isNotEmpty())
        assertTrue(
            "clipped panels must stay in front of the camera",
            result.walls.all { wall -> wall.nearestDistanceM > 0.0 },
        )
    }

    @Test
    fun `accuracy bands are suppressed when they would engulf the camera`() {
        // Standing 6 m from an edge with a 10 m fix: the band is a 10 m-wide
        // slab lying on the ground, so its near side is 4 m BEHIND the camera.
        // It wraps around the viewer and floods the frame with translucent
        // colour, which is what the field test showed. At that range the honest
        // statement is the number on the label, not a shape.
        val engulfing = overlay(square(size = 60.0, awayM = 6.0), accuracyM = 10.0)
        assertEquals(RenderMode.NEAR, engulfing.mode)
        assertTrue("bands must not be drawn from inside them", engulfing.bands.isEmpty())
        assertTrue("the boundary itself must still be drawn", engulfing.walls.isNotEmpty())

        // Comfortably inside near mode but clear of the band: still drawn.
        val usable = overlay(square(size = 60.0, awayM = 25.0), accuracyM = 4.0)
        assertEquals(RenderMode.NEAR, usable.mode)
        assertTrue("a band that fits in front of the agent is useful", usable.bands.isNotEmpty())
    }

    @Test
    fun `walls finish above eye level so they read as standing on the ground`() {
        // The rail must project ABOVE the optical centre for a level camera:
        // that is what puts it against the sky rather than lying on the floor,
        // and it is the difference between a fence and a shadow.
        val result = overlay(square(size = 100.0, awayM = 40.0))
        val rail = result.rails.minByOrNull { minOf(it.from.y, it.to.y) }!!
        assertTrue(
            "wall tops should sit above the horizon, got y=${rail.from.y}",
            rail.from.y < intrinsics.centreYPx,
        )
    }
}
