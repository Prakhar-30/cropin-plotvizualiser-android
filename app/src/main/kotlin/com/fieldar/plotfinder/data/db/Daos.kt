package com.fieldar.plotfinder.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow

@Dao
interface PlotDao {
    @Query("SELECT * FROM plots ORDER BY name")
    fun observeAll(): Flow<List<PlotEntity>>

    @Query("SELECT * FROM plots WHERE id = :id")
    suspend fun findById(id: String): PlotEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(plots: List<PlotEntity>)

    /**
     * Replaces the cache in one transaction. A half-written cache is worse than a
     * stale one: the agent is standing in a field with no signal, and a plot that
     * vanished mid-sync cannot be fetched again.
     */
    @Transaction
    suspend fun replaceAll(plots: List<PlotEntity>) {
        deleteMissing(plots.map { it.id })
        upsertAll(plots)
    }

    @Query("DELETE FROM plots WHERE id NOT IN (:keepIds)")
    suspend fun deleteMissing(keepIds: List<String>)
}

@Dao
interface HealthDao {
    @Query("SELECT * FROM plot_health WHERE plotId = :plotId")
    suspend fun findByPlot(plotId: String): HealthEntity?

    @Query("SELECT * FROM plot_health WHERE plotId = :plotId")
    fun observeForPlot(plotId: String): Flow<HealthEntity?>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(row: HealthEntity)

    /**
     * Drops rasters for plots that no longer exist.
     *
     * Called from the same transaction that replaces the plots, so the cache
     * cannot end up holding a raster for a boundary it can no longer draw -
     * which would be a coloured patch of ground with nothing containing it.
     */
    @Query("DELETE FROM plot_health WHERE plotId NOT IN (:keepIds)")
    suspend fun deleteMissing(keepIds: List<String>)
}

@Dao
interface TelemetryDao {
    @Insert
    suspend fun insert(row: TelemetryEntity)

    @Query("SELECT * FROM telemetry WHERE uploaded = 0 ORDER BY timestampMs LIMIT :limit")
    suspend fun pending(limit: Int = 200): List<TelemetryEntity>

    @Query("UPDATE telemetry SET uploaded = 1 WHERE id IN (:ids)")
    suspend fun markUploaded(ids: List<Long>)
}
