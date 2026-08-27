package com.fieldar.plotfinder.core.render

import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.METRES_PER_DEG_LAT
import com.fieldar.plotfinder.core.geo.deviceToEnuFromOrientation
import com.fieldar.plotfinder.core.geo.isOnScreen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos

class HealthGeometryTest {

    private val agent = LatLng(12.7862, 76.7201)
    private val frame = EnuFrame(agent)
    private val intrinsics = CameraIntrinsics(60.0, 1080, 1920)
    private val metresPerDegLng = cos(Math.toRadians(agent.lat)) * 111_320.0

    private fun offset(from: LatLng, eastM: Double, northM: Double) = LatLng(
        lat = from.lat + northM / METRES_PER_DEG_LAT,
        lng = from.lng + eastM / metresPerDegLng,
    )

    /** A [sizeM] square cell whose centre sits [eastM]/[northM] from the agent. */
    private fun cell(
        severity: Int,
        eastM: Double,
        northM: Double,
        sizeM: Double = 10.0,
    ): HealthCell {
        val half = sizeM / 2
        val centre = offset(agent, eastM, northM)
        return HealthCell(
            severity = severity,
            centroid = centre,
            ring = listOf(
                offset(centre, -half, -half),
                offset(centre, half, -half),
                offset(centre, half, half),
                offset(centre, -half, half),
                offset(centre, -half, -half),
            ),
        )
    }

    private fun hotspot(rank: Int, eastM: Double, northM: Double, severity: Int = 3) =
        HealthHotspot(
            rank = rank,
            severity = severity,
            centroid = offset(agent, eastM, northM),
        )

    private fun field(cells: List<HealthCell>, hotspots: List<HealthHotspot> = emptyList()) =
        HealthField(cells, hotspots, frame)

    private fun overlayFor(
        cells: List<HealthCell>,
        hotspots: List<HealthHotspot> = emptyList(),
        layer: HealthLayer = HealthLayer.ALL,
        headingDeg: Double = 0.0,
        pitchDeg: Double = 0.0,
        maxRangeM: Double = HEALTH_MAX_RANGE_M,
        maxPatches: Int = MAX_HEALTH_PATCHES,
    ) = buildHealthOverlay(
        field = field(cells, hotspots),
        eye = frame.toEnu(agent),
        enuToDevice = deviceToEnuFromOrientation(headingDeg, pitchDeg).transpose(),
        intrinsics = intrinsics,
        layer = layer,
        maxRangeM = maxRangeM,
        maxPatches = maxPatches,
    )

    @Test
    fun `a cell ahead of the agent projects onto the screen`() {
        // Pitched down: the ground 40 m out is below the horizon, so a level
        // phone would put it near the top edge and a test that only checked for
        // "some points" would pass on geometry that is actually behind the eye.
        val result = overlayFor(listOf(cell(severity = 3, eastM = 0.0, northM = 40.0)), pitchDeg = -15.0)

        assertEquals(1, result.patches.size)
        val patch = result.patches.first()
        assertTrue("a square cell keeps at least three corners", patch.corners.size >= 3)
        assertTrue(
            "the cell should be visible",
            patch.corners.any { it.isOnScreen(intrinsics) },
        )
        assertEquals(3, patch.severity)
    }

    @Test
    fun `the ground is below the horizon, never above it`() {
        // The single most visible failure mode: a sign error on the ground plane
        // puts the crop health in the sky. Held level, the ground can only ever
        // project below the centre line.
        val result = overlayFor(listOf(cell(severity = 2, eastM = 0.0, northM = 30.0)))
        val centreY = intrinsics.centreYPx

        for (corner in result.patches.first().corners) {
            assertTrue(
                "ground corner at y=${corner.y} must be below the horizon at $centreY",
                corner.y > centreY,
            )
        }
    }

    @Test
    fun `the stress layer hides healthy cells and counts them`() {
        val cells = listOf(
            cell(severity = 0, eastM = -12.0, northM = 40.0),
            cell(severity = 0, eastM = 0.0, northM = 40.0),
            cell(severity = 2, eastM = 12.0, northM = 40.0),
        )

        val all = overlayFor(cells, layer = HealthLayer.ALL, pitchDeg = -15.0)
        assertEquals(3, all.patches.size)
        assertEquals(0, all.hiddenCellCount)

        val stress = overlayFor(cells, layer = HealthLayer.STRESS, pitchDeg = -15.0)
        assertEquals("only the stressed cell survives", 1, stress.patches.size)
        assertEquals(2, stress.patches.first().severity)
        // The count is what lets the UI say "2 healthy cells hidden" rather than
        // leaving a gap the agent reads as missing data.
        assertEquals(2, stress.hiddenCellCount)
    }

    @Test
    fun `the off layer draws nothing at all`() {
        val result = overlayFor(
            listOf(cell(severity = 3, eastM = 0.0, northM = 20.0)),
            hotspots = listOf(hotspot(rank = 1, eastM = 0.0, northM = 20.0)),
            layer = HealthLayer.OFF,
        )
        assertTrue(result.patches.isEmpty())
        assertTrue("markers must go too, not just the fill", result.markers.isEmpty())
    }

    @Test
    fun `cells beyond the range limit are dropped`() {
        val near = cell(severity = 3, eastM = 0.0, northM = 50.0)
        val far = cell(severity = 3, eastM = 0.0, northM = 400.0)

        val result = overlayFor(listOf(near, far), pitchDeg = -15.0)
        assertEquals("the 400 m cell is past the 150 m limit", 1, result.patches.size)

        // And the drop is by distance, not by list order.
        val reversed = overlayFor(listOf(far, near), pitchDeg = -15.0)
        assertEquals(1, reversed.patches.size)
    }

    @Test
    fun `a range-culled cell is not counted as hidden by the layer`() {
        // hiddenCellCount drives a "n cells hidden" readout. If range culling
        // fed into it, standing at one end of a large plot would report hundreds
        // of hidden cells that the toggle cannot bring back - a control that
        // promises something it cannot deliver.
        val result = overlayFor(
            listOf(cell(severity = 0, eastM = 0.0, northM = 400.0)),
            layer = HealthLayer.STRESS,
        )
        assertEquals(0, result.hiddenCellCount)
        assertTrue(result.patches.isEmpty())
    }

    @Test
    fun `patches are ordered far to near so near cells paint last`() {
        val cells = (1..6).map { cell(severity = 2, eastM = 0.0, northM = it * 12.0) }
        val result = overlayFor(cells, pitchDeg = -20.0)

        assertTrue("expected several patches", result.patches.size >= 4)
        val distances = result.patches.map { it.nearestDistanceM }
        assertEquals(
            "painter's algorithm: farthest first",
            distances.sortedDescending(),
            distances,
        )
    }

    @Test
    fun `the patch cap keeps the nearest cells, not the first ones`() {
        // Listed farthest-first on purpose: a cap that just took the head of the
        // list would keep the cells the agent cannot reach and drop the ones
        // under their feet.
        val cells = (1..12).map { cell(severity = 2, eastM = 0.0, northM = (13 - it) * 10.0) }
        val result = overlayFor(cells, pitchDeg = -20.0, maxPatches = 3)

        assertEquals(3, result.patches.size)
        assertTrue(
            "kept patches should all be close, not 100 m out",
            result.patches.all { it.nearestDistanceM < 45.0 },
        )
    }

    @Test
    fun `foreground cells fade but never vanish`() {
        val underfoot = overlayFor(
            listOf(cell(severity = 3, eastM = 0.0, northM = 2.0)),
            pitchDeg = -45.0,
        ).patches.firstOrNull()
        val ahead = overlayFor(
            listOf(cell(severity = 3, eastM = 0.0, northM = 60.0)),
            pitchDeg = -10.0,
        ).patches.firstOrNull()

        requireNotNull(underfoot)
        requireNotNull(ahead)
        assertTrue("a cell underfoot must be faded", underfoot.opacity < ahead.opacity)
        assertTrue(
            "but standing on a critical patch is worth knowing",
            underfoot.opacity >= MIN_PATCH_OPACITY,
        )
        assertEquals("a distant cell is drawn at full strength", 1.0f, ahead.opacity, 1e-4f)
    }

    @Test
    fun `hotspot markers stand up from the ground`() {
        val result = overlayFor(
            listOf(cell(severity = 3, eastM = 0.0, northM = 45.0)),
            hotspots = listOf(hotspot(rank = 1, eastM = 0.0, northM = 45.0)),
            pitchDeg = -10.0,
        )

        assertEquals(1, result.markers.size)
        val marker = result.markers.first()
        assertTrue("the stem must rise on screen", marker.top.y < marker.base.y)
        assertEquals(1, marker.rank)
        assertEquals(45.0, marker.distanceM, 0.5)
    }

    @Test
    fun `markers survive the stress layer regardless of banding`() {
        // A hotspot is the walk-to target. It must not disappear because the
        // layer happens to be filtering the cells around it.
        val result = overlayFor(
            listOf(cell(severity = 0, eastM = 0.0, northM = 45.0)),
            hotspots = listOf(hotspot(rank = 1, eastM = 0.0, northM = 45.0)),
            layer = HealthLayer.STRESS,
            pitchDeg = -10.0,
        )
        assertTrue("the healthy cell is hidden", result.patches.isEmpty())
        assertEquals("the marker is not", 1, result.markers.size)
    }

    @Test
    fun `a cell behind the agent is culled rather than mirrored`() {
        // Without near-plane clipping, a point behind the camera projects to a
        // mirrored position in front of it - a stress patch that appears in
        // exactly the wrong direction. This is the failure the clipper exists
        // to prevent, so it is worth asserting directly.
        val behind = overlayFor(
            listOf(cell(severity = 3, eastM = 0.0, northM = -40.0)),
            pitchDeg = -15.0,
        )
        assertTrue(
            "nothing behind the agent may be drawn",
            behind.patches.all { patch -> patch.corners.none { it.isOnScreen(intrinsics) } },
        )
    }

    @Test
    fun `a cell straddling the camera keeps its front half`() {
        // The agent standing inside a cell: part of it is in front, part behind.
        // The clipper should keep a drawable polygon rather than discarding the
        // whole thing - the ground you are standing on is the ground you most
        // want graded.
        val result = overlayFor(
            listOf(cell(severity = 3, eastM = 0.0, northM = 0.0, sizeM = 20.0)),
            pitchDeg = -40.0,
        )
        assertEquals(1, result.patches.size)
        assertTrue(result.patches.first().corners.size >= 3)
    }

    @Test
    fun `the field is reusable only for the frame it was built against`() {
        val built = field(listOf(cell(severity = 1, eastM = 0.0, northM = 30.0)))
        assertTrue(built.matches(frame))
        // A re-anchor produces a new frame with a new origin. Reusing the old
        // metres against it would offset the raster by the whole walk.
        assertFalse(built.matches(EnuFrame(offset(agent, 500.0, 0.0))))
    }

    @Test
    fun `a degenerate cell is dropped rather than drawn as a sliver`() {
        val degenerate = HealthCell(
            severity = 3,
            centroid = offset(agent, 0.0, 30.0),
            ring = listOf(offset(agent, 0.0, 30.0), offset(agent, 1.0, 30.0)),
        )
        assertTrue(field(listOf(degenerate)).cells.isEmpty())
    }

    @Test
    fun `severity colours cover every band the classifier can emit`() {
        // The renderer indexes this list by a value that arrives over the wire.
        assertEquals(4, SEVERITY_COLOURS.size)
        SEVERITY_COLOURS.forEachIndexed { index, band -> assertEquals(index, band.level) }

        // Clamped, not wrapped: a corrupt band must not read as "healthy".
        assertEquals(3, severityColour(9).level)
        assertEquals(0, severityColour(-2).level)

        // And the ramp must actually rise, or the fade encodes nothing.
        val alphas = SEVERITY_COLOURS.map { it.fillAlpha }
        assertEquals(alphas.sorted(), alphas)
    }
}
