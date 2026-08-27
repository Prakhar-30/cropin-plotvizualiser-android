package com.fieldar.plotfinder.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One sample of what the app actually saw in the field. No UI, ever.
 *
 * This table is the point of shipping v0. It produces the real accuracy
 * distribution across the actual device fleet - how often heading is locked
 * versus compass-only, what horizontal accuracy the phones really report, how
 * long a session takes - and that distribution is what justifies (or kills)
 * phase 2. Guessing at it from a spec is how teams end up buying RTK receivers
 * they did not need.
 */
@Entity(tableName = "telemetry")
data class TelemetryEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val timestampMs: Long,
    /** Groups every row from one AR session, so drift can be read as a series. */
    val sessionId: String,
    val plotId: String,
    val lat: Double,
    val lng: Double,
    /** Horizontal accuracy the receiver claimed, in metres. */
    val reportedAccuracyM: Double,
    val headingDeg: Double,
    /** Name of a [com.fieldar.plotfinder.core.heading.HeadingSource]. */
    val headingSource: String,
    /** Name of a [com.fieldar.plotfinder.core.heading.HeadingConfidence]. */
    val headingConfidence: String,
    /** Name of a [com.fieldar.plotfinder.core.render.RenderMode]. */
    val renderMode: String,
    /**
     * Largest single-update movement of the stabilised position recorded while
     * the agent was standing still, in metres.
     *
     * This is the number that answers the review comment directly: if it creeps
     * back above a few tens of centimetres on some handset, the overlay is
     * drifting there and the fleet data will say so before a farmer does.
     */
    val anchorShiftM: Double,
    /** Seconds since the local frame last re-anchored. */
    val anchorAgeS: Double,
    val deviceModel: String,
    val appVersion: String,
    val sessionDurationMs: Long,
    val uploaded: Boolean = false,
)
