package com.fieldar.plotfinder.data.net

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * The companion web tool's API, exactly as it is served.
 *
 * `near` is the endpoint that matters: the agent is dispatched to a place, and
 * the app caches everything within a radius of it so the whole visit works with
 * the radio off.
 */
interface PlotApi {

    @GET("api/plots")
    suspend fun listPlots(): List<PlotDto>

    /** @param near formatted as "lat,lng". */
    @GET("api/plots")
    suspend fun listPlotsNear(
        @Query("near") near: String,
        @Query("radius_m") radiusM: Int,
    ): List<PlotDto>

    /**
     * The crop-health raster for one plot.
     *
     * Separate from the plot itself because it is an order of magnitude larger -
     * a few hundred graded cells against one boundary ring - and because it has
     * a different lifetime: a boundary is drawn once, a health snapshot is
     * re-derived every time new imagery lands. Bundling them would force a
     * re-download of every boundary to refresh a raster.
     */
    @GET("api/plots/{id}/health")
    suspend fun health(@Path("id") id: String): HealthDto

    /**
     * Telemetry upload. The web service does not implement this yet; the client
     * side is built now so that switching it on is a server change alone.
     */
    @POST("api/telemetry")
    suspend fun uploadTelemetry(@Body rows: List<TelemetryDto>)
}

@Serializable
data class PlotDto(
    val id: String,
    val name: String,
    val polygon: PolygonDto,
    @SerialName("centroid_lat") val centroidLat: Double,
    @SerialName("centroid_lng") val centroidLng: Double,
    @SerialName("access_lat") val accessLat: Double,
    @SerialName("access_lng") val accessLng: Double,
    @SerialName("area_sq_m") val areaSqM: Double,
    @SerialName("landmark_note") val landmarkNote: String = "",
    // Defaulted so a server that has not been migrated yet still deserialises;
    // every plot then draws in slot 0, which is wrong but not broken.
    @SerialName("colour_index") val colourIndex: Int = 0,
    @SerialName("created_at") val createdAt: String,
    // The `?near=` response also carries `distance_m`; the app recomputes the
    // distance locally from the agent's live fix, so it is ignored here.
)

@Serializable
data class PolygonDto(
    val type: String,
    /** Rings of `[lng, lat]` pairs. Only the first is used - plots have no holes. */
    val coordinates: List<List<List<Double>>>,
)

/**
 * One health snapshot, exactly as `GET /api/plots/:id/health` serves it.
 *
 * [synthetic] and [note] are defaulted rather than required so that a server
 * which has not been updated still deserialises - but the default is `false`,
 * which is the *unsafe* direction, so the app treats a missing flag as
 * measured. That is deliberate: the current server always sends it, and a
 * silent default of `true` would libel a real snapshot as fake.
 */
@Serializable
data class HealthDto(
    @SerialName("plot_id") val plotId: String,
    @SerialName("captured_on") val capturedOn: String,
    @SerialName("index_name") val indexName: String,
    @SerialName("cell_size_m") val cellSizeM: Double,
    val cells: List<HealthCellDto> = emptyList(),
    val hotspots: List<HealthHotspotDto> = emptyList(),
    val synthetic: Boolean = false,
    val note: String = "",
)

@Serializable
data class HealthCellDto(
    /** 0 healthy to 3 critical. Banded server-side so no client owns the agronomy. */
    val severity: Int,
    @SerialName("centroid_lat") val centroidLat: Double,
    @SerialName("centroid_lng") val centroidLng: Double,
    /** The cell square, already trimmed to the plot boundary by the API. */
    val cell: PolygonDto,
)

@Serializable
data class HealthHotspotDto(
    /** 1 is the worst. What the agent walks to first. */
    val rank: Int,
    @SerialName("centroid_lat") val centroidLat: Double,
    @SerialName("centroid_lng") val centroidLng: Double,
    val severity: Int,
)

@Serializable
data class TelemetryDto(
    @SerialName("timestamp_ms") val timestampMs: Long,
    @SerialName("session_id") val sessionId: String,
    @SerialName("plot_id") val plotId: String,
    val lat: Double,
    val lng: Double,
    @SerialName("accuracy_m") val accuracyM: Double,
    @SerialName("heading_deg") val headingDeg: Double,
    @SerialName("heading_source") val headingSource: String,
    @SerialName("heading_confidence") val headingConfidence: String,
    @SerialName("render_mode") val renderMode: String,
    @SerialName("anchor_shift_m") val anchorShiftM: Double,
    @SerialName("anchor_age_s") val anchorAgeS: Double,
    @SerialName("device_model") val deviceModel: String,
    @SerialName("app_version") val appVersion: String,
    @SerialName("session_duration_ms") val sessionDurationMs: Long,
)
