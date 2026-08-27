package com.fieldar.plotfinder.data

import com.fieldar.plotfinder.core.geo.LatLng

/** A plot in the form the rest of the app uses: degrees in, metres computed later. */
data class Plot(
    val id: String,
    val name: String,
    /** Closed ring of WGS84 positions, in the order the surveyor drew them. */
    val ring: List<LatLng>,
    val centroid: LatLng,
    val accessPoint: LatLng,
    val areaSqM: Double,
    val landmarkNote: String,
    /** Palette slot; see `core.render.plotColour`. */
    val colourIndex: Int,
    val createdAt: String,
    val syncedAtMs: Long,
) {
    val areaHectares: Double get() = areaSqM / 10_000.0

    /** Corners the surveyor placed, ignoring the ring's closing repeat. */
    val cornerCount: Int
        get() = if (ring.size >= 2 && ring.first() == ring.last()) ring.size - 1 else ring.size
}
