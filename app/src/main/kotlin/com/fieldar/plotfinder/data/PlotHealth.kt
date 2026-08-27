package com.fieldar.plotfinder.data

import com.fieldar.plotfinder.core.render.HealthCell
import com.fieldar.plotfinder.core.render.HealthHotspot

/**
 * A crop-health snapshot for one plot, as the app uses it.
 *
 * [HealthCell] and [HealthHotspot] are the `core.render` types rather than
 * copies of them. Mirroring a four-field shape across the data and render
 * layers buys nothing but a mapping function and the chance for the two to
 * disagree about what `severity` means - and `data` already depends on `core`
 * for [com.fieldar.plotfinder.core.geo.LatLng], so the direction is unchanged.
 */
data class PlotHealth(
    val plotId: String,
    /** Capture date of the underlying imagery, `YYYY-MM-DD`. */
    val capturedOn: String,
    /** Which index was graded, e.g. `ndvi`. */
    val indexName: String,
    /**
     * True when the values are a stand-in rather than measured imagery.
     *
     * Surfaced in the AR view, not just logged. An agent acting on a made-up
     * NDVI is the one failure mode of this feature that costs real money, and
     * the overlay is convincing enough that nothing but an explicit label will
     * stop it being believed.
     */
    val synthetic: Boolean,
    /** The server's own wording for any caveat, shown verbatim - see [synthetic]. */
    val note: String,
    val cellSizeM: Double,
    val cells: List<HealthCell>,
    val hotspots: List<HealthHotspot>,
    val syncedAtMs: Long,
) {
    /** Cells at or above the "stressed" band. The count the readout leads with. */
    val stressedCellCount: Int get() = cells.count { it.severity >= 2 }

    /** Ground area graded as stressed or worse. */
    val stressedAreaSqM: Double get() = stressedCellCount * cellSizeM * cellSizeM
}
