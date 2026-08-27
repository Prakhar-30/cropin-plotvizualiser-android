package com.fieldar.plotfinder.data

import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.render.HealthLayer
import com.fieldar.plotfinder.core.render.buildHealthOverlay
import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.deviceToEnuFromOrientation
import com.fieldar.plotfinder.core.render.HealthField
import com.fieldar.plotfinder.data.net.HealthDto
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parses a response captured verbatim from the deployed API.
 *
 * The wire contract is the seam this feature is most likely to break at, and it
 * is the one place unit tests normally cannot reach: every `@SerialName` here
 * is a guess about a server written in another language, in another repository,
 * that deploys on its own schedule. A hand-written fixture would only test that
 * the guess agrees with itself. This one was fetched from the live service, so
 * a rename on either side fails the build instead of silently producing a plot
 * with no crop health and no error.
 *
 * The payload deliberately still contains the fields the app does *not* map -
 * `source`, `value`, `grid_cols` and the rest - because dropping them from the
 * DTO is only safe if the parser really does ignore them.
 */
class HealthDtoParsingTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val captured = """{"plot_id":"PLT-9254","captured_on":"2026-08-25","source":"synthetic","index_name":"ndvi","cell_size_m":10,"grid_cols":3,"grid_rows":3,"value_min":-0.02182532349969879,"value_max":0.7673356737933222,"value_mean":0.6112958701311224,"cells":[{"col":0,"row":0,"value":0.7673356737933222,"severity":0,"centroid_lat":12.918769788495025,"centroid_lng":77.61035668799951,"cell":{"type":"Polygon","coordinates":[[[77.61031585449398,12.91881502099005],[77.610318653,12.918735013],[77.61040276999904,12.918731243538161],[77.61040276999904,12.91881502099005],[77.61031585449398,12.91881502099005]]]}},{"col":1,"row":0,"value":0.5316769404150821,"severity":1,"centroid_lat":12.918769788495025,"centroid_lng":77.61044885199856,"cell":{"type":"Polygon","coordinates":[[[77.61040276999904,12.918731243538161],[77.61049493399808,12.918727113473118],[77.61049493399808,12.91881502099005],[77.61040276999904,12.91881502099005],[77.61040276999904,12.918731243538161]]]}}],"hotspots":[],"synthetic":true,"note":"Synthetic NDVI for demonstration. Not derived from satellite imagery."}"""

    @Test
    fun `a real API response parses into cells the renderer can use`() {
        val dto = json.decodeFromString(HealthDto.serializer(), captured)

        assertEquals("PLT-9254", dto.plotId)
        assertEquals("ndvi", dto.indexName)
        assertEquals(10.0, dto.cellSizeM, 1e-9)
        assertTrue("the live service labels its synthetic values", dto.synthetic)
        assertTrue("and explains itself", dto.note.isNotBlank())
        assertEquals(2, dto.cells.size)

        val health = dto.toHealth(syncedAtMs = 1_000L)
        assertEquals(2, health.cells.size)

        // The lng/lat swap: Bengaluru is near 12.9N 77.6E. Getting this
        // backwards puts the cell in the Arabian Sea off Somalia, and nothing
        // else in the pipeline would notice.
        val first = health.cells.first()
        assertTrue("lat should be ~12.9, was ${first.centroid.lat}", first.centroid.lat in 12.0..14.0)
        assertTrue("lng should be ~77.6, was ${first.centroid.lng}", first.centroid.lng in 77.0..78.0)
        assertTrue("a cell ring must be closed and drawable", first.ring.size >= 4)
        for (corner in first.ring) {
            assertTrue(corner.lat in 12.0..14.0)
            assertTrue(corner.lng in 77.0..78.0)
        }
    }

    @Test
    fun `the parsed raster projects onto the screen from inside the plot`() {
        // The full path in one test: wire bytes to filled screen polygons.
        val health = json.decodeFromString(HealthDto.serializer(), captured).toHealth(1_000L)
        val agent = health.cells.first().centroid
        val frame = EnuFrame(agent)
        val intrinsics = CameraIntrinsics(60.0, 1080, 1920)

        val overlay = buildHealthOverlay(
            field = HealthField(health.cells, health.hotspots, frame),
            eye = frame.toEnu(agent),
            // Pitched down at the ground the agent is standing on.
            enuToDevice = deviceToEnuFromOrientation(0.0, -50.0).transpose(),
            intrinsics = intrinsics,
            layer = HealthLayer.ALL,
        )

        assertTrue("expected the standing-on cell to survive clipping", overlay.patches.isNotEmpty())
        assertTrue(overlay.patches.all { it.corners.size >= 3 })
    }

    @Test
    fun `a snapshot survives the cache round trip`() {
        val dto = json.decodeFromString(HealthDto.serializer(), captured)
        val restored = dto.toEntity(syncedAtMs = 42L).toHealth()

        requireNotNull(restored)
        assertEquals(42L, restored.syncedAtMs)
        assertEquals(dto.cells.size, restored.cells.size)
        assertEquals(dto.plotId, restored.plotId)
    }

    @Test
    fun `an unreadable cached snapshot is dropped, not thrown`() {
        // A row written by a build whose DTO has since changed. The boundary is
        // still perfectly usable, so an AR session must not die over a raster.
        val row = com.fieldar.plotfinder.data.db.HealthEntity(
            plotId = "PLT-9254",
            capturedOn = "2026-08-25",
            synthetic = true,
            snapshotJson = "{ not json at all",
            syncedAtMs = 1L,
        )
        assertEquals(null, row.toHealth())
    }
}
