package com.fieldar.plotfinder.core.render

import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.EYE_HEIGHT_M
import com.fieldar.plotfinder.core.geo.Enu
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.Mat3
import com.fieldar.plotfinder.core.geo.ScreenPoint
import com.fieldar.plotfinder.core.geo.Vec3
import com.fieldar.plotfinder.core.geo.angleDifferenceDeg
import com.fieldar.plotfinder.core.geo.cameraHeadingDeg
import com.fieldar.plotfinder.core.geo.clipSegmentToNearPlane
import com.fieldar.plotfinder.core.geo.clipToNearPlane
import com.fieldar.plotfinder.core.geo.distanceToNearestEdgeM
import com.fieldar.plotfinder.core.geo.isOnScreen
import com.fieldar.plotfinder.core.geo.openRing
import com.fieldar.plotfinder.core.geo.projectDevice
import com.fieldar.plotfinder.core.geo.toDevice
import kotlin.math.hypot

/**
 * Decides what the overlay should draw, in screen coordinates, without touching
 * a Canvas. Pure, so the mode switch and the culling are unit-testable.
 */

/** Switch point between the two modes, measured to the nearest edge. */
const val NEAR_MODE_THRESHOLD_M = 30.0

/** How tall the vertex posts stand above the ground plane. */
const val VERTEX_POST_HEIGHT_M = 2.5

/**
 * How tall the boundary wall stands.
 *
 * The first field test drew the boundary flat on the ground, and the reviewers'
 * first comment was that it read as a coloured carpet rather than as a fence -
 * a shape lying on the floor gives the eye no cue that it is a *limit*. Standing
 * the edges up fixes that, and it also fixes a subtler problem: a flat overlay
 * disappears entirely when the phone is held level, because the ground plane is
 * then edge-on to the camera.
 *
 * Measured from the ground, and tall enough to finish one metre above the
 * agent's eye. Field feedback was that a wall topping out below eye level reads
 * as floating: the eye takes the top rail for the boundary and the bottom edge
 * for a shadow, because nothing visually connects it to the ground. Carrying it
 * past eye level puts the rail against the sky or the far treeline instead, and
 * the panel unmistakably stands on the earth.
 */
const val BOUNDARY_WALL_HEIGHT_M = EYE_HEIGHT_M + 1.0

enum class RenderMode {
    /**
     * Beyond 30 m: a translucent filled shape with a post at each corner. The
     * *shape* is the point - a pin tells the agent nothing about which of six
     * identical fields they are looking at, while an outline they can match
     * against the hedge line confirms it even when heading is a few degrees off.
     */
    FAR,

    /**
     * Inside 30 m: no fill, and each edge becomes a band as wide as the current
     * GNSS accuracy. A crisp line here would be a false precision claim, and the
     * first time a farmer disputes a reading it is the line that gets blamed.
     */
    NEAR,
}

data class OverlayPost(val base: ScreenPoint, val top: ScreenPoint)

/**
 * One boundary edge, stood up into a vertical panel.
 *
 * [nearestDistanceM] exists so the renderer can draw far walls first. Without
 * that ordering the translucent panels composite in ring order, and the far side
 * of a plot paints over the near side - which looks like a fold in the boundary.
 */
data class OverlayWall(
    val quad: List<ScreenPoint>,
    val nearestDistanceM: Double,
    /**
     * How solidly to draw this panel, 0..1.
     *
     * A 2.6 m wall standing 3 m from the camera subtends most of the frame, and
     * a boundary the agent is standing against is the one they least need drawn
     * over their view - they can see the fence. Panels fade out as they come
     * within [WALL_FADE_START_M], so walking up to a boundary opens the camera
     * back up instead of filling it with colour.
     */
    val opacity: Float,
)

/** The top edge of a wall, stroked solid so the boundary line stays crisp. */
data class OverlayRail(val from: ScreenPoint, val to: ScreenPoint, val opacity: Float)

/** Panels nearer than this begin to fade; the rail stays, the fill goes. */
const val WALL_FADE_START_M = 8.0

/** Below this the panel is gone entirely and only its top rail remains. */
const val WALL_FADE_END_M = 1.5

/**
 * Ramps a surface's opacity in over the last few metres of approach.
 *
 * Two surfaces need this and they need different floors, so it is written once
 * with the floor as a parameter rather than twice with one number changed.
 * Below [fadeEndM] the result is [floor]; above [fadeStartM] it is 1; between
 * them it is linear.
 *
 * The general problem it solves is the same in both cases: geometry drawn on or
 * near the camera subtends far more of the frame than its importance justifies,
 * because perspective magnifies whatever is close. Fading by distance is the
 * cheapest correction that does not require knowing the projected area.
 */
internal fun linearFade(
    distanceM: Double,
    fadeEndM: Double,
    fadeStartM: Double,
    floor: Float = 0.0f,
): Float = when {
    distanceM >= fadeStartM -> 1.0f
    distanceM <= fadeEndM -> floor
    else -> {
        val t = (distanceM - fadeEndM) / (fadeStartM - fadeEndM)
        floor + (1.0f - floor) * t.toFloat()
    }
}

/**
 * Fade factor for a panel at [distanceM].
 *
 * The rail never fades below [MIN_RAIL_OPACITY]: the line is the boundary, and
 * losing it as you step up to the fence would remove the answer at exactly the
 * moment the agent is trying to stand on it. The panel itself goes to nothing,
 * so walking up to a boundary opens the camera back up.
 */
internal fun wallOpacity(distanceM: Double): Float =
    linearFade(distanceM, WALL_FADE_END_M, WALL_FADE_START_M)

const val MIN_RAIL_OPACITY = 0.75f

/** Four projected corners of an accuracy band around one boundary edge. */
data class OverlayBand(val corners: List<ScreenPoint>)

data class OverlayLabel(val at: ScreenPoint, val distanceM: Double)

data class PlotOverlay(
    val mode: RenderMode,
    val edgeDistanceM: Double,
    val centroidDistanceM: Double,
    /** Closed ground outline. Kept faint - the walls carry the boundary now. */
    val fill: List<ScreenPoint>,
    /** The standing boundary panels, ordered far to near for correct blending. */
    val walls: List<OverlayWall>,
    /** Top edge of each wall. */
    val rails: List<OverlayRail>,
    /** Accuracy bands in near mode, empty in far mode. */
    val bands: List<OverlayBand>,
    val posts: List<OverlayPost>,
    val label: OverlayLabel?,
    /**
     * Relative bearing to the plot when nothing of it is on screen, so the UI can
     * put an arrow at the edge. Negative is left, positive is right.
     */
    val offscreenBearingDeg: Double?,
)

/**
 * Builds the overlay for one plot.
 *
 * All geometry sits on the ground plane, taken as the device's own altitude
 * minus a fixed eye height. There is no terrain model and no attempt at one: a
 * wrong elevation would tilt the whole shape, and on the flat farmland this is
 * built for, assuming level ground is both simpler and closer to true.
 */
fun buildPlotOverlay(
    ring: List<LatLng>,
    centroid: LatLng,
    agent: LatLng,
    frame: EnuFrame,
    deviceToEnu: Mat3,
    intrinsics: CameraIntrinsics,
    gnssAccuracyM: Double,
): PlotOverlay {
    val enuToDevice = deviceToEnu.transpose()
    val groundUp = -EYE_HEIGHT_M

    val ringGround = openRing(ring.map { frame.toEnu(it, groundUp) })

    // The camera. It sits at the agent's own position, at up = 0, which puts it
    // EYE_HEIGHT_M above the ground plane the boundary is drawn on. Everything
    // projected below is measured from here, never from the frame origin.
    val eye = frame.toEnu(agent)

    // Distances are measured on the ground, ignoring the eye-height offset.
    val agentFlat = Enu(eye.east, eye.north)
    val ringFlat = ringGround.map { Enu(it.east, it.north) }

    val edgeDistanceM = distanceToNearestEdgeM(ringFlat, agentFlat)
    val centroidEnu = frame.toEnu(centroid, groundUp)
    val centroidDistanceM = hypot(
        centroidEnu.east - agentFlat.east,
        centroidEnu.north - agentFlat.north,
    )

    val mode = if (edgeDistanceM < NEAR_MODE_THRESHOLD_M) RenderMode.NEAR else RenderMode.FAR

    val fill = if (mode == RenderMode.FAR) {
        clipToNearPlane(ringGround.map { toDevice(it, eye, enuToDevice) })
            .mapNotNull { projectDevice(it, intrinsics) }
    } else {
        emptyList()
    }

    // Walls are drawn in both modes. They are the boundary now; the ground fill
    // has been demoted to a faint hint of which side of the line the crop is on.
    val (walls, rails) = buildWalls(ringGround, eye, enuToDevice, intrinsics)

    // Accuracy bands are suppressed once the agent is closer to the edge than
    // the accuracy itself. A band is a slab `gnssAccuracyM` wide lying on the
    // ground; standing 6 m from an edge with an 8 m fix puts its near side
    // *behind* the camera, so it wraps around the viewer and floods the whole
    // frame with translucent colour. The honest statement at that range is not
    // a shape at all - it is the number already printed on the label, and the
    // walls still show where the boundary is believed to run.
    val bandHalfWidth = gnssAccuracyM.coerceAtLeast(MIN_BAND_HALF_WIDTH_M)
    val bands = if (mode == RenderMode.NEAR && edgeDistanceM > bandHalfWidth) {
        buildBands(ringGround, eye, enuToDevice, intrinsics, gnssAccuracyM)
    } else {
        emptyList()
    }

    val posts = if (mode == RenderMode.FAR) {
        ringGround.mapNotNull { vertex ->
            val base = projectDevice(toDevice(vertex, eye, enuToDevice), intrinsics)
            val top = projectDevice(
                toDevice(
                    Enu(vertex.east, vertex.north, vertex.up + VERTEX_POST_HEIGHT_M),
                    eye,
                    enuToDevice,
                ),
                intrinsics,
            )
            if (base != null && top != null) OverlayPost(base, top) else null
        }
    } else {
        emptyList()
    }

    val label = projectDevice(toDevice(centroidEnu, eye, enuToDevice), intrinsics)
        ?.let { OverlayLabel(it, centroidDistanceM) }

    val anythingVisible = (
        fill +
            walls.flatMap { it.quad } +
            bands.flatMap { it.corners } +
            posts.map { it.base }
        ).any { it.isOnScreen(intrinsics) }

    val offscreenBearingDeg = if (anythingVisible) {
        null
    } else {
        angleDifferenceDeg(
            cameraHeadingDeg(deviceToEnu),
            Enu(centroidEnu.east - agentFlat.east, centroidEnu.north - agentFlat.north).bearingDeg,
        )
    }

    return PlotOverlay(
        mode = mode,
        edgeDistanceM = edgeDistanceM,
        centroidDistanceM = centroidDistanceM,
        fill = fill,
        walls = walls,
        rails = rails,
        bands = bands,
        posts = posts,
        label = label,
        offscreenBearingDeg = offscreenBearingDeg,
    )
}

/**
 * Stands each boundary edge up into a vertical panel.
 *
 * Each edge becomes a quad wound up-across-down, so the polygon stays simple and
 * the near-plane clipper produces a sensible result when the agent walks through
 * a boundary. The top edge is emitted separately as a rail: clipping a closed
 * quad loses which of its sides was the top, and a solid line along the top is
 * what makes a translucent panel read as a fence rather than as haze.
 */
private fun buildWalls(
    ringGround: List<Enu>,
    eye: Enu,
    enuToDevice: Mat3,
    intrinsics: CameraIntrinsics,
): Pair<List<OverlayWall>, List<OverlayRail>> {
    if (ringGround.size < 2) return emptyList<OverlayWall>() to emptyList()

    val walls = mutableListOf<OverlayWall>()
    val rails = mutableListOf<OverlayRail>()

    for (i in ringGround.indices) {
        val a = ringGround[i]
        val b = ringGround[(i + 1) % ringGround.size]
        val aTop = Enu(a.east, a.north, a.up + BOUNDARY_WALL_HEIGHT_M)
        val bTop = Enu(b.east, b.north, b.up + BOUNDARY_WALL_HEIGHT_M)

        val quad = listOf(a, b, bTop, aTop).map { toDevice(it, eye, enuToDevice) }
        val projected = clipToNearPlane(quad).mapNotNull { projectDevice(it, intrinsics) }
        if (projected.size >= 3) {
            val nearest = projected.minOf { it.distanceM }
            val opacity = wallOpacity(nearest)
            if (opacity > 0.0f) walls += OverlayWall(projected, nearest, opacity)
        }

        val rail = clipSegmentToNearPlane(
            toDevice(aTop, eye, enuToDevice),
            toDevice(bTop, eye, enuToDevice),
        )
        if (rail != null) {
            val from = projectDevice(rail.first, intrinsics)
            val to = projectDevice(rail.second, intrinsics)
            if (from != null && to != null) {
                val nearest = minOf(from.distanceM, to.distanceM)
                rails += OverlayRail(
                    from,
                    to,
                    wallOpacity(nearest).coerceAtLeast(MIN_RAIL_OPACITY),
                )
            }
        }
    }

    // Painter's algorithm. Translucent panels composited in ring order let the
    // far side of a plot paint over the near side, which looks like a crease.
    return walls.sortedByDescending { it.nearestDistanceM } to rails
}

/**
 * Widens each boundary edge into a rectangle whose half-width is the live GNSS
 * accuracy, then projects it. Building the band in metres rather than pixels
 * means perspective narrows it with distance on its own, which is what an
 * uncertainty of a fixed number of metres actually looks like.
 */
private fun buildBands(
    ringGround: List<Enu>,
    eye: Enu,
    enuToDevice: Mat3,
    intrinsics: CameraIntrinsics,
    accuracyM: Double,
): List<OverlayBand> {
    if (ringGround.size < 2) return emptyList()
    val halfWidth = accuracyM.coerceAtLeast(MIN_BAND_HALF_WIDTH_M)

    return ringGround.indices.mapNotNull { i ->
        val a = ringGround[i]
        val b = ringGround[(i + 1) % ringGround.size]
        val dEast = b.east - a.east
        val dNorth = b.north - a.north
        val length = hypot(dEast, dNorth)
        if (length < 1e-6) return@mapNotNull null

        // Unit normal to the edge, in the ground plane.
        val nEast = dNorth / length * halfWidth
        val nNorth = -dEast / length * halfWidth

        val quad = listOf(
            Enu(a.east + nEast, a.north + nNorth, a.up),
            Enu(b.east + nEast, b.north + nNorth, b.up),
            Enu(b.east - nEast, b.north - nNorth, b.up),
            Enu(a.east - nEast, a.north - nNorth, a.up),
        )
        val corners: List<Vec3> = clipToNearPlane(quad.map { toDevice(it, eye, enuToDevice) })
        val projected = corners.mapNotNull { projectDevice(it, intrinsics) }
        if (projected.size < 3) null else OverlayBand(projected)
    }
}

/**
 * Even a perfect fix does not justify a hairline: below this the band stops
 * shrinking, so the drawing never implies centimetre certainty.
 */
const val MIN_BAND_HALF_WIDTH_M = 1.5
