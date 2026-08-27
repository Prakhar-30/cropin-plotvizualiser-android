package com.fieldar.plotfinder.data

import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.data.db.HealthDao
import com.fieldar.plotfinder.data.db.PlotDao
import com.fieldar.plotfinder.data.net.PlotApi
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * The cache is the source of truth.
 *
 * Every read goes to Room and nothing on a screen ever waits for the network:
 * rural sites have no data, and an app that degrades when the radio drops is an
 * app that does not work where it is used. Sync is a separate, explicitly
 * triggered action that refills the cache when there happens to be signal.
 */
class PlotRepository(
    private val dao: PlotDao,
    private val healthDao: HealthDao,
    private val api: PlotApi,
) {
    fun observePlots(): Flow<List<Plot>> = dao.observeAll().map { rows -> rows.map { it.toPlot() } }

    suspend fun findById(id: String): Plot? = dao.findById(id)?.toPlot()

    /**
     * The cached crop-health raster for a plot, or null if none was ever pulled.
     *
     * Reads the cache only. The AR screen opens with the radio off as often as
     * not, and blocking the overlay on a network call would mean the boundary
     * waits for the raster - the boundary is the thing the agent came for.
     */
    suspend fun healthFor(plotId: String): PlotHealth? =
        healthDao.findByPlot(plotId)?.toHealth()

    /**
     * Pulls plots from the API into the cache.
     *
     * With an [around] position it fetches only what is within [radiusM], which
     * is what a dispatched agent actually needs; without one it takes the lot,
     * which is fine for a prototype's worth of plots.
     */
    suspend fun sync(around: LatLng? = null, radiusM: Int = 5_000): SyncResult = try {
        val nearby = if (around == null) {
            emptyList()
        } else {
            api.listPlotsNear("${around.lat},${around.lng}", radiusM)
        }

        // Falling back to the whole set when nothing is within the radius. A
        // dispatched agent standing on their site wants only what is around
        // them, but "0 plots near you" is indistinguishable on screen from "the
        // sync failed", and the honest reading of an empty radius is usually
        // that the boundary was drawn somewhere else - not that there is
        // nothing to show.
        val dtos = nearby.ifEmpty { api.listPlots() }
        val fellBack = around != null && nearby.isEmpty() && dtos.isNotEmpty()

        dao.replaceAll(dtos.map { it.toEntity() })
        healthDao.deleteMissing(dtos.map { it.id })

        // Rasters are pulled after the boundaries are safely committed, and a
        // failure here is swallowed per plot. The health layer is an extra; a
        // sync that lands every boundary and misses one raster is a success,
        // and reporting it as a failure would send the agent back to hunt for
        // signal they do not need.
        val healthCount = syncHealthFor(dtos.map { it.id })

        SyncResult.Success(dtos.size, healthCount, widenedToEverything = fellBack)
    } catch (e: Exception) {
        // Offline is the expected case, not an error worth shouting about. The
        // cached plots stay exactly as they were.
        SyncResult.Failed(e.message ?: e::class.simpleName ?: "sync failed")
    }

    /**
     * Pulls the health raster for one plot on its own.
     *
     * Used when the agent opens a plot that synced before the health layer
     * existed, so they are not made to re-sync every boundary to colour one
     * field. Returns false when there was no signal, which the caller shows as
     * "not cached" rather than as "this plot is healthy" - the difference
     * matters and only the caller can word it.
     */
    suspend fun syncHealth(plotId: String): Boolean = syncHealthFor(listOf(plotId)) > 0

    /**
     * Fetches rasters concurrently, tolerating individual failures.
     *
     * Concurrent because these are independent round trips and a dispatched
     * agent syncing a dozen plots over rural HSPA would otherwise wait a dozen
     * latencies in a row. Each one is guarded separately: one plot whose raster
     * 404s must not cost the other eleven.
     */
    private suspend fun syncHealthFor(plotIds: List<String>): Int = coroutineScope {
        plotIds.map { id ->
            async {
                try {
                    healthDao.upsert(api.health(id).toEntity())
                    1
                } catch (e: Exception) {
                    0
                }
            }
        }.awaitAll().sum()
    }
}

sealed interface SyncResult {
    /**
     * @param healthCount how many rasters came with them. Reported separately
     *   because it can legitimately be lower than [plotCount] - see
     *   `syncHealthFor` - and a silent shortfall would look like plots that are
     *   simply healthy.
     * @param widenedToEverything true when nothing was within the radius.
     */
    data class Success(
        val plotCount: Int,
        val healthCount: Int = 0,
        val widenedToEverything: Boolean = false,
    ) : SyncResult
    data class Failed(val reason: String) : SyncResult
}
