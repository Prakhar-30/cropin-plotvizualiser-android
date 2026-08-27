package com.fieldar.plotfinder.core.heading

import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.horizontalAngleOffsetDeg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LandmarkSnapTest {

    private val agent = LatLng(12.7862, 76.7201)
    private val intrinsics = CameraIntrinsics(60.0, 1080, 1920)

    @Test
    fun `aiming dead centre pins the heading to the true bearing`() {
        // 0.002 deg east of the agent is due east, 217 m away.
        val feature = LatLng(agent.lat, agent.lng + 0.002)
        assertEquals(90.0, headingFromLandmarkSnap(agent, feature)!!, 1e-9)
    }

    @Test
    fun `a crosshair off to the right means the camera points further left`() {
        val feature = LatLng(agent.lat, agent.lng + 0.002)
        // A crosshair 30 deg right of centre sees the feature at bearing 90, so
        // the camera axis itself is aimed at 60.
        assertEquals(60.0, headingFromLandmarkSnap(agent, feature, crosshairOffsetDeg = 30.0)!!, 1e-9)
    }

    @Test
    fun `the crosshair offset comes from the real focal length`() {
        // Right edge of a 60 deg viewport is exactly half the field of view out.
        assertEquals(30.0, horizontalAngleOffsetDeg(1080.0, intrinsics), 1e-6)
        assertEquals(0.0, horizontalAngleOffsetDeg(540.0, intrinsics), 1e-9)
        assertEquals(-30.0, horizontalAngleOffsetDeg(0.0, intrinsics), 1e-6)
    }

    @Test
    fun `snapping wraps past north rather than going negative`() {
        // Feature due north, crosshair 30 deg right: camera axis is at 330.
        val feature = LatLng(agent.lat + 0.002, agent.lng)
        assertEquals(330.0, headingFromLandmarkSnap(agent, feature, crosshairOffsetDeg = 30.0)!!, 1e-9)
    }

    @Test
    fun `a feature too close to aim at is refused`() {
        // 5 m away: the agent's own GNSS error would dominate the bearing.
        val close = LatLng(agent.lat + 5.0 / 110_540.0, agent.lng)
        assertNull(headingFromLandmarkSnap(agent, close))
    }
}
