package com.fieldar.plotfinder.core.render

import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.EYE_HEIGHT_M
import com.fieldar.plotfinder.core.geo.Enu
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.Mat3
import com.fieldar.plotfinder.core.geo.ScreenPoint
import com.fieldar.plotfinder.core.geo.clipToNearPlane
import com.fieldar.plotfinder.core.geo.openRing
import com.fieldar.plotfinder.core.geo.projectDevice
import com.fieldar.plotfinder.core.geo.toDevice
import kotlin.math.hypot

/**
 * Paints the crop-health raster onto the ground.
 *
 * The boundary answers "where is the plot"; this answers "which part of it do I
 * need to walk to". Both are drawn from the same pose, in the same ENU frame,
 * against the same ground plane - a health patch computed in its own frame
 * would sit metres away from the boundary that is supposed to contain it, and
 * the whole claim of the layer is that the brown ground is *inside this plot*.
 *
 * Every cell arrives already trimmed to the boundary by the API (see
 * `clipToBoundary` in `@plot/shared`), so nothing here has to clip against the
 * ring. That trimming happens once, server-side, rather than sixty times a
 * second on a phone.
 */

/**
 * One graded ground cell. 0 healthy to 3 critical; see [severityColour].
 *
 * Only what is drawn is carried. The raw index value is deliberately absent:
 * nothing on this screen shows an NDVI number, the band is what decides the
 * colour, and a field parsed a few hundred times per sync to be discarded is
 * work the phone should not be doing.
 */
data class HealthCell(
    val severity: Int,
    /** Used for range culling before any projection happens. */
    val centroid: LatLng,
    /** Closed ground ring of the cell, already trimmed to the plot boundary. */
    val ring: List<LatLng>,
)

/** A cluster of stressed cells worth a walk. [rank] 1 is the worst. */
data class HealthHotspot(
    val rank: Int,
    val severity: Int,
    val centroid: LatLng,
)

/**
 * How much of the raster to draw.
 *
 * [STRESS] is the default, and the reason is the whole point of the feature: a
 * plot is mostly healthy, so painting every cell covers the crop the agent came
 * to look at with a green wash and buries the two patches that matter. Hiding
 * band 0 leaves the stressed ground standing alone against the real field.
 * [ALL] exists because "is that patch bad, or is the whole field like that?" is
 * a fair question, and it can only be answered by showing the healthy cells too.
 */
enum class HealthLayer {
    OFF,
    STRESS,
    ALL,
    ;

    fun next(): HealthLayer = entries[(ordinal + 1) % entries.size]

    /** The lowest band this layer draws. */
    val minSeverity: Int get() = if (this == ALL) 0 else 1

    val label: String get() = when (this) {
        OFF -> "Health off"
        STRESS -> "Problem areas"
        ALL -> "All cells"
    }
}

/**
 * Cells beyond this are dropped.
 *
 * Not a performance number - a legibility one. A 10 m cell at 150 m subtends
 * about 60 px of width and a handful of pixels of height, because the ground
 * plane is nearly edge-on at that range. Past here the raster stops being a map
 * of the field and becomes a coloured smear along the horizon, which reads as
 * an error in the overlay rather than as information.
 */
const val HEALTH_MAX_RANGE_M = 150.0

/**
 * Hard cap on drawn cells, nearest first.
 *
 * A 40 ha plot at 10 m resolution is 4000 cells, and projecting every one of
 * them on a 50 Hz pose stream drops frames on the mid-range hardware this is
 * built for. The nearest 500 are the ones the agent can actually stand on.
 */
const val MAX_HEALTH_PATCHES = 500

/**
 * Ground cells nearer than this are faded, but never below [MIN_PATCH_OPACITY].
 *
 * A cell the agent is standing in has its far edge 10 m out and its near edge
 * behind the camera, so it projects across the entire lower half of the frame.
 * At full strength that is a coloured floor blocking the view of the crop -
 * which is the thing the agent came to inspect. Fading the foreground keeps the
 * grading readable without painting over the answer it is pointing at.
 */
const val PATCH_FADE_START_M = 6.0

/**
 * Floor for the foreground fade.
 *
 * Raised sharply after field testing, because this number was not acting alone.
 * Three independent factors multiply into the final alpha - the severity band,
 * this fade, and the heading-confidence tier - and each looked reasonable in
 * isolation. Together, a stressed patch underfoot on a carried heading came out
 * at 0.42 x 0.35 x 0.6, which is nine percent: invisible on a phone screen in
 * daylight, and indistinguishable from the feature being broken.
 *
 * Compounding multipliers is the trap. Every one of them still exists, because
 * each says something true, but the floors are now set so their product stays
 * legible at the worst combination rather than only at the best.
 */
const val MIN_PATCH_OPACITY = 0.62f

/** How tall a hotspot marker stands. Matches the boundary corner posts. */
const val HOTSPOT_MARKER_HEIGHT_M = VERTEX_POST_HEIGHT_M

/** One graded cell, projected and ready to fill. */
data class HealthPatch(
    val corners: List<ScreenPoint>,
    val severity: Int,
    val nearestDistanceM: Double,
    val opacity: Float,
)

/** A stem standing at a hotspot centroid, so the target is visible over the crop. */
data class HealthMarker(
    val base: ScreenPoint,
    val top: ScreenPoint,
    val rank: Int,
    val severity: Int,
    val distanceM: Double,
)

data class HealthOverlay(
    val patches: List<HealthPatch>,
    val markers: List<HealthMarker>,
    /** Cells inside range that this layer chose not to draw, for the readout. */
    val hiddenCellCount: Int,
)

/**
 * The raster converted to metres, once.
 *
 * Degrees-to-metres is trigonometry per point, and a few hundred cells at four
 * corners each is a few thousand conversions - cheap once, wasteful sixty times
 * a second. Nothing here depends on where the camera is looking, only on where
 * the frame is anchored, so it survives every pose update and is rebuilt only
 * when the agent walks far enough for [EnuFrame] to re-anchor.
 *
 * Ground distances are stored alongside so the per-frame path can range-cull
 * without touching a square root.
 */
class HealthField(
    cells: List<HealthCell>,
    hotspots: List<HealthHotspot>,
    private val frame: EnuFrame,
) {
    /** One cell, in metres. [centre] is on the ground plane, like [ring]. */
    class Prepared(val severity: Int, val centre: Enu, val ring: List<Enu>)

    class PreparedHotspot(val rank: Int, val severity: Int, val at: Enu)

    private val groundUp = -EYE_HEIGHT_M

    val cells: List<Prepared> = cells.mapNotNull { cell ->
        val ring = openRing(cell.ring.map { frame.toEnu(it, groundUp) })
        if (ring.size < 3) {
            null
        } else {
            Prepared(cell.severity, frame.toEnu(cell.centroid, groundUp), ring)
        }
    }

    val hotspots: List<PreparedHotspot> = hotspots.map {
        PreparedHotspot(it.rank, it.severity, frame.toEnu(it.centroid, groundUp))
    }

    /** True when this field was built against [other] and can still be reused. */
    fun matches(other: EnuFrame): Boolean = frame === other

    val isEmpty: Boolean get() = cells.isEmpty() && hotspots.isEmpty()
}

/**
 * Projects the visible part of the raster for one frame.
 *
 * Patches come back sorted far-to-near for the same reason the walls do:
 * translucent fills composited in grid order let a far cell paint over a near
 * one, and on a ground plane that reads as the grading being scrambled.
 */
fun buildHealthOverlay(
    field: HealthField,
    eye: Enu,
    enuToDevice: Mat3,
    intrinsics: CameraIntrinsics,
    layer: HealthLayer,
    maxRangeM: Double = HEALTH_MAX_RANGE_M,
    maxPatches: Int = MAX_HEALTH_PATCHES,
): HealthOverlay {
    if (layer == HealthLayer.OFF) return HealthOverlay(emptyList(), emptyList(), 0)

    val maxRangeSq = maxRangeM * maxRangeM
    var hidden = 0

    // Range-cull and band-filter before any projection. Squared distance on the
    // ground plane only - the eye-height offset is a constant 1.6 m and cannot
    // move a cell across a 150 m threshold.
    val candidates = ArrayList<Pair<HealthField.Prepared, Double>>(field.cells.size)
    for (cell in field.cells) {
        val dEast = cell.centre.east - eye.east
        val dNorth = cell.centre.north - eye.north
        val distanceSq = dEast * dEast + dNorth * dNorth
        if (distanceSq > maxRangeSq) continue
        if (cell.severity < layer.minSeverity) {
            hidden++
            continue
        }
        candidates += cell to distanceSq
    }

    // Keep the nearest, then draw them back to front. Capping by distance rather
    // than by grid order means the cells that survive are the ones underfoot,
    // which is where the agent is about to look.
    val kept = candidates
        .sortedBy { it.second }
        .take(maxPatches)
        .sortedByDescending { it.second }

    val patches = kept.mapNotNull { (cell, _) ->
        val projected = clipToNearPlane(cell.ring.map { toDevice(it, eye, enuToDevice) })
            .mapNotNull { projectDevice(it, intrinsics) }
        if (projected.size < 3) return@mapNotNull null

        val nearest = projected.minOf { it.distanceM }
        HealthPatch(
            corners = projected,
            severity = cell.severity,
            nearestDistanceM = nearest,
            opacity = linearFade(nearest, 0.0, PATCH_FADE_START_M, floor = MIN_PATCH_OPACITY),
        )
    }

    // Markers ignore the band filter: a hotspot is by definition stressed, and
    // it is the walk-to target, so it stays visible in every layer that is on.
    val markers = field.hotspots.mapNotNull { hotspot ->
        val dEast = hotspot.at.east - eye.east
        val dNorth = hotspot.at.north - eye.north
        val distanceM = hypot(dEast, dNorth)
        if (distanceM > maxRangeM) return@mapNotNull null

        val base = projectDevice(toDevice(hotspot.at, eye, enuToDevice), intrinsics)
            ?: return@mapNotNull null
        val top = projectDevice(
            toDevice(
                Enu(hotspot.at.east, hotspot.at.north, hotspot.at.up + HOTSPOT_MARKER_HEIGHT_M),
                eye,
                enuToDevice,
            ),
            intrinsics,
        ) ?: return@mapNotNull null

        HealthMarker(base, top, hotspot.rank, hotspot.severity, distanceM)
    }.sortedByDescending { it.distanceM }

    return HealthOverlay(patches, markers, hidden)
}
