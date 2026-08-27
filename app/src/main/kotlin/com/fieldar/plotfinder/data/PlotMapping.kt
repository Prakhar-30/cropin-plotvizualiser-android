package com.fieldar.plotfinder.data

import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.render.HealthCell
import com.fieldar.plotfinder.core.render.HealthHotspot
import com.fieldar.plotfinder.data.db.HealthEntity
import com.fieldar.plotfinder.data.db.PlotEntity
import com.fieldar.plotfinder.data.net.HealthDto
import com.fieldar.plotfinder.data.net.PlotDto
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Wire format to cache row to domain object.
 *
 * Split out of the repository so the off-device demo harness in `tools/demo`
 * goes through exactly this path rather than re-deriving it - the lng/lat swap
 * below is the one line in the app where a mistake silently relocates every plot,
 * and it should exist once.
 */

private val json = Json { ignoreUnknownKeys = true }
private val ringSerializer = ListSerializer(ListSerializer(Double.serializer()))

fun PlotDto.toEntity(syncedAtMs: Long = System.currentTimeMillis()): PlotEntity {
    val ring = polygon.coordinates.firstOrNull().orEmpty()
    return PlotEntity(
        id = id,
        name = name,
        ringJson = json.encodeToString(ringSerializer, ring),
        centroidLat = centroidLat,
        centroidLng = centroidLng,
        accessLat = accessLat,
        accessLng = accessLng,
        areaSqM = areaSqM,
        landmarkNote = landmarkNote,
        colourIndex = colourIndex,
        createdAt = createdAt,
        syncedAtMs = syncedAtMs,
    )
}

/**
 * A GeoJSON ring as WGS84 positions.
 *
 * The boundary and every health cell are the same shape on the wire, and the
 * lng-then-lat swap is the one line in the app where a mistake silently
 * relocates geometry. It exists once, here, and both callers go through it.
 */
private fun ringOf(coordinates: List<List<List<Double>>>): List<LatLng> =
    coordinates.firstOrNull().orEmpty().mapNotNull {
        if (it.size >= 2) LatLng(it[1], it[0]) else null
    }

fun HealthDto.toEntity(syncedAtMs: Long = System.currentTimeMillis()): HealthEntity = HealthEntity(
    plotId = plotId,
    capturedOn = capturedOn,
    synthetic = synthetic,
    // Re-serialised from the parsed DTO rather than kept as the raw body, so
    // the cache can only ever hold something this app can read back.
    snapshotJson = json.encodeToString(HealthDto.serializer(), this),
    syncedAtMs = syncedAtMs,
)

fun HealthDto.toHealth(syncedAtMs: Long): PlotHealth = PlotHealth(
    plotId = plotId,
    capturedOn = capturedOn,
    indexName = indexName,
    synthetic = synthetic,
    note = note,
    cellSizeM = cellSizeM,
    cells = cells.map {
        HealthCell(
            // Clamped, not trusted. A band the renderer has no colour for would
            // otherwise index off the end of the ramp mid-frame.
            severity = it.severity.coerceIn(0, 3),
            centroid = LatLng(it.centroidLat, it.centroidLng),
            ring = ringOf(it.cell.coordinates),
        )
    },
    hotspots = hotspots.map {
        HealthHotspot(
            rank = it.rank,
            severity = it.severity.coerceIn(0, 3),
            centroid = LatLng(it.centroidLat, it.centroidLng),
        )
    },
    syncedAtMs = syncedAtMs,
)

/**
 * Cache row back to domain, via the wire type.
 *
 * Decoding to [HealthDto] and reusing [toHealth] rather than writing a second
 * parser means the cached path and the network path cannot disagree about what
 * a snapshot means. A snapshot written by an older build that no longer parses
 * is treated as absent - the raster is a convenience, and a stale one is not
 * worth crashing an AR session for.
 */
fun HealthEntity.toHealth(): PlotHealth? = try {
    json.decodeFromString(HealthDto.serializer(), snapshotJson).toHealth(syncedAtMs)
} catch (e: Exception) {
    null
}

fun PlotEntity.toPlot(): Plot {
    val ring = json.decodeFromString(ringSerializer, ringJson)
    return Plot(
        id = id,
        name = name,
        // GeoJSON is lng-then-lat. Getting this backwards puts Karnataka in the
        // Indian Ocean, so the swap happens in exactly one place: `ringOf`.
        ring = ringOf(listOf(ring)),
        centroid = LatLng(centroidLat, centroidLng),
        accessPoint = LatLng(accessLat, accessLng),
        areaSqM = areaSqM,
        landmarkNote = landmarkNote,
        colourIndex = colourIndex,
        createdAt = createdAt,
        syncedAtMs = syncedAtMs,
    )
}
