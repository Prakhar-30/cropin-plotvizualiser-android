package com.fieldar.plotfinder.core.geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every expected value below is computed by hand from the documented model, not
 * by calling the code under test back on itself.
 *
 * Working latitude is 12.7862 N (the seeded plots in Mandya district), where
 * cos(12.7862 deg) = 0.9752027, so one degree of longitude is
 * 0.9752027 * 111320 = 108559.6 m and one degree of latitude is 110540 m.
 */
class EnuFrameTest {

    private val origin = LatLng(12.7862, 76.7201)
    private val frame = EnuFrame(origin)

    @Test
    fun `a thousandth of a degree north is 110_54 metres`() {
        val enu = frame.toEnu(LatLng(origin.lat + 0.001, origin.lng))
        assertEquals(110.540, enu.north, 0.001)
        assertEquals(0.0, enu.east, 1e-9)
    }

    @Test
    fun `a thousandth of a degree east is shortened by the cosine of the latitude`() {
        val enu = frame.toEnu(LatLng(origin.lat, origin.lng + 0.001))
        // 0.001 * 0.9752027 * 111320 = 108.5596 m, not the equatorial 111.32 m.
        assertEquals(108.5596, enu.east, 0.002)
        assertEquals(0.0, enu.north, 1e-9)
    }

    @Test
    fun `south and west come out negative`() {
        val enu = frame.toEnu(LatLng(origin.lat - 0.002, origin.lng - 0.002))
        assertEquals(-221.080, enu.north, 0.002)
        assertEquals(-217.1191, enu.east, 0.004)
    }

    @Test
    fun `converting to metres and back returns the original degrees`() {
        val point = LatLng(12.78931, 76.72447)
        val roundTripped = frame.toLatLng(frame.toEnu(point))
        assertEquals(point.lat, roundTripped.lat, 1e-12)
        assertEquals(point.lng, roundTripped.lng, 1e-12)
    }

    @Test
    fun `the origin is at the origin`() {
        val enu = frame.toEnu(origin)
        assertEquals(0.0, enu.east, 1e-12)
        assertEquals(0.0, enu.north, 1e-12)
        assertEquals(0.0, enu.up, 1e-12)
    }

    @Test
    fun `re-anchors only after fifty metres of walking`() {
        // 0.0004 deg of latitude is 44.2 m; 0.0006 deg is 66.3 m.
        assertFalse(frame.needsReanchor(LatLng(origin.lat + 0.0004, origin.lng)))
        assertTrue(frame.needsReanchor(LatLng(origin.lat + 0.0006, origin.lng)))
    }

    @Test
    fun `ground range ignores height but range does not`() {
        val point = Enu(east = 3.0, north = 4.0, up = 12.0)
        assertEquals(5.0, point.groundRange, 1e-12)
        assertEquals(13.0, point.range, 1e-12)
    }

    @Test
    fun `bearings are compass bearings, clockwise from north`() {
        assertEquals(0.0, Enu(0.0, 100.0).bearingDeg, 1e-9)
        assertEquals(90.0, Enu(100.0, 0.0).bearingDeg, 1e-9)
        assertEquals(180.0, Enu(0.0, -100.0).bearingDeg, 1e-9)
        assertEquals(270.0, Enu(-100.0, 0.0).bearingDeg, 1e-9)
        assertEquals(45.0, Enu(100.0, 100.0).bearingDeg, 1e-9)
        assertEquals(315.0, Enu(-100.0, 100.0).bearingDeg, 1e-9)
    }

    @Test
    fun `bearing between two positions goes through the metric frame`() {
        // Due east of the origin must read 90 deg even though the degree deltas
        // differ in size - this is exactly what computing in raw degrees breaks.
        val east = LatLng(origin.lat, origin.lng + 0.002)
        assertEquals(90.0, bearingDeg(origin, east), 1e-9)
        assertEquals(217.1191, distanceM(origin, east), 0.01)

        val north = LatLng(origin.lat + 0.002, origin.lng)
        assertEquals(0.0, bearingDeg(origin, north), 1e-9)
        assertEquals(221.080, distanceM(origin, north), 0.01)
    }

    @Test
    fun `equal metric offsets give a true forty five degrees`() {
        // 0.001 deg north is 110.540 m; the matching easting is 110.540 m, which
        // is 110.540 / 108559.6 = 0.00101824 deg of longitude.
        val target = LatLng(origin.lat + 0.001, origin.lng + 0.00101824)
        assertEquals(45.0, bearingDeg(origin, target), 0.001)
    }
}
