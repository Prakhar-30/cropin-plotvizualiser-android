package com.fieldar.plotfinder.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One cached crop-health snapshot, keyed by plot.
 *
 * The raster is kept as the API's own JSON in [snapshotJson] rather than
 * exploded into a row per cell. Three reasons, in order of weight:
 *
 * 1. It is read as a whole and never queried by cell. A `health_cells` table
 *    would exist only to be `SELECT *`-ed back into a list.
 * 2. It is replaced as a whole. New imagery invalidates every cell at once, so
 *    per-row updates buy nothing.
 * 3. It keeps the cache a faithful copy of what the server sent, which is the
 *    same choice `PlotEntity.ringJson` makes for the boundary - and it means a
 *    new field in the snapshot is not a migration.
 *
 * The two scalar columns beside it are the ones that answer a question about
 * the snapshot without opening it - how old the imagery is, and whether it is
 * real. Derived statistics are not duplicated here: they would be a second
 * copy of something the JSON already says, free to drift and read by nobody.
 */
@Entity(tableName = "plot_health")
data class HealthEntity(
    @PrimaryKey val plotId: String,
    /** Capture date of the imagery, so staleness is answerable without parsing. */
    val capturedOn: String,
    val synthetic: Boolean,
    /** The whole snapshot, exactly as the API serialised it. */
    val snapshotJson: String,
    /** When this row was last pulled, for showing cache age offline. */
    val syncedAtMs: Long,
)
