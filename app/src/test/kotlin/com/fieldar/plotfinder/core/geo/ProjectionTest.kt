package com.fieldar.plotfinder.core.geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.tan

/**
 * A 1080 x 1920 viewport with a 60 degree horizontal field of view gives a focal
 * length of (1080 / 2) / tan(30 deg) = 540 / 0.57735027 = 935.307 px, and a
 * principal point at (540, 960). Every expectation below follows from those
 * three numbers.
 */
class ProjectionTest {

    private val intrinsics = CameraIntrinsics(
        horizontalFovDeg = 60.0,
        viewportWidthPx = 1080,
        viewportHeightPx = 1920,
    )

    /**
     * These tests place the camera at the frame origin, which keeps the expected
     * numbers hand-checkable. That the camera must be *stated* rather than
     * assumed is the point of the parameter - see `OverlayGeometryTest` for the
     * case where it sits somewhere else.
     */
    private val ORIGIN_EYE = Enu(0.0, 0.0, 0.0)

    /** Level camera, pointing due north. */
    private val facingNorth = deviceToEnuFromOrientation(headingDeg = 0.0, pitchDeg = 0.0)

    private fun project(point: Enu, deviceToEnu: Mat3 = facingNorth) =
        projectEnu(point, ORIGIN_EYE, deviceToEnu.transpose(), intrinsics)

    @Test
    fun `focal length and principal point come from the declared field of view`() {
        assertEquals(935.307, intrinsics.focalPx, 0.01)
        assertEquals(540.0, intrinsics.centreXPx, 1e-9)
        assertEquals(960.0, intrinsics.centreYPx, 1e-9)
    }

    @Test
    fun `a hundred metres dead ahead lands on the principal point`() {
        val p = project(Enu(east = 0.0, north = 100.0))!!
        assertEquals(540.0f, p.x, 0.01f)
        assertEquals(960.0f, p.y, 0.01f)
        assertEquals(100.0, p.distanceM, 1e-9)
    }

    @Test
    fun `a point at half the field of view lands exactly on the right edge`() {
        // 100 * tan(30 deg) = 57.735 m east of straight ahead.
        val east = 100.0 * tan(Math.toRadians(30.0))
        val p = project(Enu(east = east, north = 100.0))!!
        assertEquals(1080.0f, p.x, 0.02f)
        assertEquals(960.0f, p.y, 0.02f)
        assertTrue(p.isOnScreen(intrinsics))
    }

    @Test
    fun `the mirror image lands on the left edge`() {
        val east = -100.0 * tan(Math.toRadians(30.0))
        val p = project(Enu(east = east, north = 100.0))!!
        assertEquals(0.0f, p.x, 0.02f)
    }

    @Test
    fun `beyond the field of view the point projects off screen rather than vanishing`() {
        // 45 deg to the right: x = 540 + 935.307 * 1 = 1475.3, past the 1080 edge.
        val p = project(Enu(east = 100.0, north = 100.0))!!
        assertEquals(1475.307f, p.x, 0.02f)
        assertFalse(p.isOnScreen(intrinsics))
    }

    @Test
    fun `ground points sit below the horizon by the eye height`() {
        // The ground is 1.6 m below the phone, 100 m away:
        // y = 960 + 935.307 * 1.6 / 100 = 974.965
        val p = project(Enu(east = 0.0, north = 100.0, up = -EYE_HEIGHT_M))!!
        assertEquals(974.965f, p.y, 0.02f)
        assertEquals(540.0f, p.x, 0.02f)
    }

    @Test
    fun `points behind the camera are culled, not mirrored`() {
        // This is the whole reason the near-plane test exists: without it the
        // negative depth flips the sign and the field behind the agent draws on
        // top of the one in front.
        assertNull(project(Enu(east = 0.0, north = -100.0)))
        assertNull(project(Enu(east = 30.0, north = -100.0)))
        assertNull(project(Enu(east = -30.0, north = -100.0)))
        // Straight up is also behind a level camera's image plane.
        assertNull(project(Enu(east = 0.0, north = 0.0, up = 100.0)))
    }

    @Test
    fun `a point on the lens is culled by the near plane`() {
        assertNull(project(Enu(east = 0.0, north = 0.2)))
        assertNotNull(project(Enu(east = 0.0, north = 0.6)))
    }

    @Test
    fun `turning the camera east moves a northern point to the left`() {
        val facingEast = deviceToEnuFromOrientation(headingDeg = 90.0, pitchDeg = 0.0)
        // Facing east, a point due north is 90 deg to the left: behind the image
        // plane edge-on, so it culls.
        assertNull(project(Enu(east = 0.0, north = 100.0), facingEast))

        // 30 deg left of east is bearing 60: north = 100*cos60 = 50, east = 100*sin60 = 86.603
        val p = project(Enu(east = 86.603, north = 50.0), facingEast)!!
        assertEquals(0.0f, p.x, 0.05f)
    }

    @Test
    fun `pitching the camera up pushes the target down the screen`() {
        val pitchedUp = deviceToEnuFromOrientation(headingDeg = 0.0, pitchDeg = 10.0)
        // y = 960 + 935.307 * tan(10 deg) = 960 + 164.925 = 1124.925
        val p = project(Enu(east = 0.0, north = 100.0), pitchedUp)!!
        assertEquals(1124.925f, p.y, 0.05f)
        assertEquals(540.0f, p.x, 0.05f)
    }

    @Test
    fun `pitching the camera down pulls the target up the screen`() {
        val pitchedDown = deviceToEnuFromOrientation(headingDeg = 0.0, pitchDeg = -10.0)
        val p = project(Enu(east = 0.0, north = 100.0), pitchedDown)!!
        assertEquals(795.075f, p.y, 0.05f)
    }

    @Test
    fun `camera heading is recovered from the rotation matrix`() {
        for (heading in listOf(0.0, 37.0, 90.0, 180.0, 271.5, 359.0)) {
            for (pitch in listOf(-20.0, 0.0, 15.0)) {
                val r = deviceToEnuFromOrientation(heading, pitch)
                assertEquals(heading, cameraHeadingDeg(r), 1e-6)
            }
        }
    }

    @Test
    fun `pitch and roll are recovered from the rotation matrix`() {
        for (heading in listOf(0.0, 115.0, 300.0)) {
            for (pitch in listOf(-35.0, -5.0, 0.0, 22.0)) {
                for (roll in listOf(-40.0, 0.0, 18.0)) {
                    val r = deviceToEnuFromOrientation(heading, pitch, roll)
                    assertEquals("pitch at h=$heading p=$pitch r=$roll", pitch, cameraPitchDeg(r), 1e-6)
                    assertEquals("roll at h=$heading p=$pitch r=$roll", roll, cameraRollDeg(r), 1e-6)
                }
            }
        }
    }

    @Test
    fun `roll does not change where the camera is aimed`() {
        val upright = deviceToEnuFromOrientation(50.0, 5.0, rollDeg = 0.0)
        val rolled = deviceToEnuFromOrientation(50.0, 5.0, rollDeg = 25.0)
        assertEquals(cameraHeadingDeg(upright), cameraHeadingDeg(rolled), 1e-6)
    }

    @Test
    fun `roll rotates the scene about the camera axis`() {
        val rolled = deviceToEnuFromOrientation(0.0, 0.0, rollDeg = 90.0)
        // A point 30 deg right of a level camera sits on the right edge, 540 px
        // from centre. Roll the *device* 90 deg clockwise and the scene
        // counter-rotates, carrying that point to 540 px above centre.
        val east = 100.0 * tan(Math.toRadians(30.0))
        val p = project(Enu(east = east, north = 100.0), rolled)!!
        assertEquals(540.0f, p.x, 0.05f)
        assertEquals(420.0f, p.y, 0.05f)
    }

    @Test
    fun `substituting a heading keeps pitch and roll intact`() {
        val sensorPose = deviceToEnuFromOrientation(headingDeg = 200.0, pitchDeg = 12.0, rollDeg = 8.0)
        val corrected = withHeading(sensorPose, desiredHeadingDeg = 65.0)

        assertEquals(65.0, cameraHeadingDeg(corrected), 1e-6)

        // Pitch survives: a point 100 m along the new heading must land at the
        // same height on screen as it did under the old one.
        val before = projectEnu(Enu(0.0, 100.0), ORIGIN_EYE, sensorPose.transpose(), intrinsics)
        val rebuilt = deviceToEnuFromOrientation(65.0, 12.0, 8.0)
        val afterCorrected = projectEnu(Enu(0.0, 100.0), ORIGIN_EYE, corrected.transpose(), intrinsics)
        val afterRebuilt = projectEnu(Enu(0.0, 100.0), ORIGIN_EYE, rebuilt.transpose(), intrinsics)
        assertNull(before) // heading 200 means north is behind the camera
        assertEquals(afterRebuilt!!.x, afterCorrected!!.x, 0.05f)
        assertEquals(afterRebuilt.y, afterCorrected.y, 0.05f)
    }

    @Test
    fun `a twenty degree heading error shifts an eighty metre target by twenty seven metres`() {
        // The reason the heading architecture exists, as an assertion.
        val truth = Enu(east = 0.0, north = 80.0)
        val wrongPose = deviceToEnuFromOrientation(headingDeg = 20.0, pitchDeg = 0.0)
        val p = project(truth, wrongPose)!!

        // Off by 20 deg, so the target appears 20 deg left of centre:
        // x = 540 - 935.307 * tan(20 deg) = 540 - 340.44 = 199.56
        assertEquals(199.56f, p.x, 0.1f)

        // On the ground that is 80 * tan(20 deg) = 29.1 m of lateral error -
        // comfortably into the neighbour's field.
        assertEquals(29.12, 80.0 * tan(Math.toRadians(20.0)), 0.01)
    }
}
