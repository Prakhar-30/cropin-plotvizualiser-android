package com.fieldar.plotfinder.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A plot as cached on the device. Mirrors the web tool's `plots` table.
 *
 * The boundary is stored as the raw GeoJSON ring so the cache is a faithful copy
 * of what the server sent; it is parsed into metres once per AR session, against
 * the agent's own local frame.
 *
 * `boundaryEdited` and `editedRing` are unused in v0 - boundary correction is out
 * of scope - but the columns exist so adding it later is a migration that adds
 * nothing, rather than one that rewrites every row.
 */
@Entity(tableName = "plots")
data class PlotEntity(
    @PrimaryKey val id: String,
    val name: String,
    /** JSON array of `[lng, lat]` pairs, closed, exactly as the API returned it. */
    val ringJson: String,
    val centroidLat: Double,
    val centroidLng: Double,
    val accessLat: Double,
    val accessLng: Double,
    val areaSqM: Double,
    val landmarkNote: String,
    /** Palette slot 0-7, assigned server-side so neighbouring plots differ. */
    val colourIndex: Int,
    val createdAt: String,
    /** When this row was last pulled from the API, for showing cache age offline. */
    val syncedAtMs: Long,
)
