package com.fieldar.plotfinder.data

import com.fieldar.plotfinder.data.db.TelemetryDao
import com.fieldar.plotfinder.data.db.TelemetryEntity
import com.fieldar.plotfinder.data.net.PlotApi
import com.fieldar.plotfinder.data.net.TelemetryDto

/**
 * Records what the app saw, and drains the queue when there is signal.
 *
 * Writes are local and unconditional; uploads are best-effort and silent. A
 * failed upload is not an error the agent should ever see - the row simply stays
 * queued, which is why `uploaded` is a column rather than a delete.
 */
class TelemetryRepository(
    private val dao: TelemetryDao,
    private val api: PlotApi,
) {
    suspend fun record(row: TelemetryEntity) = dao.insert(row)

    /** Uploads queued rows. Returns how many made it, zero if offline. */
    suspend fun syncPending(): Int {
        val pending = dao.pending()
        if (pending.isEmpty()) return 0
        return try {
            api.uploadTelemetry(pending.map(::toDto))
            dao.markUploaded(pending.map { it.id })
            pending.size
        } catch (_: Exception) {
            0
        }
    }

    private fun toDto(row: TelemetryEntity) = TelemetryDto(
        timestampMs = row.timestampMs,
        sessionId = row.sessionId,
        plotId = row.plotId,
        lat = row.lat,
        lng = row.lng,
        accuracyM = row.reportedAccuracyM,
        headingDeg = row.headingDeg,
        headingSource = row.headingSource,
        headingConfidence = row.headingConfidence,
        renderMode = row.renderMode,
        anchorShiftM = row.anchorShiftM,
        anchorAgeS = row.anchorAgeS,
        deviceModel = row.deviceModel,
        appVersion = row.appVersion,
        sessionDurationMs = row.sessionDurationMs,
    )
}
