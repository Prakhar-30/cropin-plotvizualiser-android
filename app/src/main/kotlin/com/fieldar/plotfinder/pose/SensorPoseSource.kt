package com.fieldar.plotfinder.pose

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import android.hardware.display.DisplayManager
import android.view.Display
import android.view.Surface
import com.fieldar.plotfinder.core.geo.Mat3
import com.fieldar.plotfinder.core.geo.OrientationSmoother
import com.fieldar.plotfinder.core.geo.cameraHeadingDeg
import com.fieldar.plotfinder.core.geo.cameraPitchDeg
import com.fieldar.plotfinder.core.geo.cameraRollDeg
import com.fieldar.plotfinder.core.geo.withHeading
import com.fieldar.plotfinder.core.heading.HeadingFusion
import com.fieldar.plotfinder.core.heading.HeadingSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Pose from `TYPE_ROTATION_VECTOR`, with the heading replaced by whatever the
 * [HeadingFusion] currently trusts.
 *
 * Two rotation sensors are used, for different jobs:
 *
 *  - `TYPE_ROTATION_VECTOR` knows where magnetic north is. Its heading feeds the
 *    fusion as the low-weight drift trim and as the last-resort fallback.
 *  - `TYPE_GAME_ROTATION_VECTOR` has no magnetometer input at all. Its heading is
 *    the gyro carrier: arbitrary in absolute terms, but immune to a tractor
 *    parked next to the agent. Where the device does not provide it, the
 *    magnetic rotation vector carries instead, which is worse but never absent.
 *
 * Pitch and roll always come from the sensors untouched. Only yaw is substituted.
 */
class SensorPoseSource(
    context: Context,
    private val fusion: HeadingFusion = HeadingFusion(),
    private val clockMs: () -> Long = SystemClock::elapsedRealtime,
) : PoseSource, SensorEventListener {

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    // Read through DisplayManager rather than WindowManager or `Context.display`:
    // this is an application context, and those two either need a visual context
    // or are deprecated in a way that throws on newer Android.
    private val display = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
        .getDisplay(Display.DEFAULT_DISPLAY)

    private val magneticRotation: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val gameRotation: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)

    private val _pose = MutableStateFlow(DevicePose.UNKNOWN)
    override val pose: StateFlow<DevicePose> = _pose.asStateFlow()

    private val _headingStatus = MutableStateFlow(initialStatus())
    override val headingStatus: StateFlow<HeadingStatus> = _headingStatus.asStateFlow()

    /** Latest attitude that carries pitch and roll, whichever sensor supplied it. */
    private var latestAttitude: Mat3? = null

    private var running = false

    private val rotationMatrix = FloatArray(9)
    private val remapped = FloatArray(9)

    override fun start() {
        if (running) return
        running = true
        magneticRotation?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        gameRotation?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    override fun stop() {
        orientation.reset()
        if (!running) return
        running = false
        sensorManager.unregisterListener(this)
    }

    override fun applyHeadingFix(bearingDeg: Double, source: HeadingSource) {
        fusion.onFix(bearingDeg, source, clockMs())
        publish()
    }

    /**
     * Takes the shimmer out of the sensor stream. See [OrientationSmoother] -
     * this is the difference between a boundary that sits on the ground and one
     * that trembles a metre either side of it.
     */
    private val orientation = OrientationSmoother()

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        val now = clockMs()
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
        val raw = Mat3.fromRowMajor(remapToDisplay(rotationMatrix))

        // Exactly one stream is the carrier, and only the carrier is smoothed.
        //
        // This used to smooth whichever sample had just arrived, from either
        // sensor, into one shared filter - and that quietly destroyed the
        // filter. The two rotation vectors do not agree: the game vector's yaw
        // origin is arbitrary at boot, so the two attitudes sit tens of degrees
        // apart and the smoother saw a stream flipping between them a hundred
        // times a second. Its deviation measure - the thing that decides
        // "deliberate turn" from "jitter" - saturated permanently, pinning the
        // time constant at its most agile 0.05 s and turning the smoothing off.
        // Worse, every magnetic sample dragged the estimate a third of the way
        // toward a different attitude, so the value handed on for drawing wobbled
        // between the two at the interleave rate.
        //
        // Yaw hid the damage, because `withHeading` overwrites it downstream.
        // Pitch and roll did not, and pitch and roll are what tilt the ground
        // plane - which slides the whole overlay sideways across the field.
        val isCarrier = when (event.sensor.type) {
            Sensor.TYPE_GAME_ROTATION_VECTOR -> true
            // Without a game rotation vector the magnetic one carries instead:
            // worse, but never absent.
            Sensor.TYPE_ROTATION_VECTOR -> gameRotation == null
            else -> return
        }

        // The magnetic sample contributes a heading and nothing else. It never
        // touches the smoother and never becomes the drawn attitude.
        if (event.sensor.type == Sensor.TYPE_ROTATION_VECTOR) {
            fusion.onMagneticHeading(cameraHeadingDeg(raw), now)
        }

        if (!isCarrier) return

        // The heading fed to the fusion is taken from the *raw* sample: the
        // fusion has its own drift-trimming and lock logic, and filtering its
        // input twice would slow the response to a genuine turn without making
        // the result any steadier.
        latestAttitude = orientation.update(raw, now)
        fusion.onCarrierHeading(cameraHeadingDeg(raw), now)

        // Published only on the carrier tick. Publishing on both streams emitted
        // a new pose about a hundred times a second, and every emission rebuilds
        // the overlay - several hundred ground cells reprojected - for a sample
        // that did not change the attitude at all.
        publish()
    }

    /**
     * Rotates the sensor frame into the frame the screen is actually drawn in.
     *
     * The AR screen is locked to portrait, but "portrait" is the natural
     * orientation only on phones; on a natural-landscape device the sensor axes
     * are 90 degrees off the screen axes and the whole overlay would render on
     * its side.
     */
    private fun remapToDisplay(matrix: FloatArray): FloatArray {
        val (axisX, axisY) = when (display.rotation) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> return matrix
        }
        SensorManager.remapCoordinateSystem(matrix, axisX, axisY, remapped)
        return remapped
    }

    private fun publish() {
        val attitude = latestAttitude ?: return
        val now = clockMs()
        val estimate = fusion.estimate(now)
        val corrected = withHeading(attitude, estimate.headingDeg)

        _pose.value = DevicePose(
            deviceToEnu = corrected,
            headingDeg = estimate.headingDeg,
            pitchDeg = cameraPitchDeg(corrected),
            rollDeg = cameraRollDeg(corrected),
            timestampMs = now,
        )
        _headingStatus.value = HeadingStatus(
            source = estimate.source,
            confidence = estimate.confidence,
            ageSeconds = estimate.ageSeconds,
            expectedErrorDeg = estimate.expectedErrorDeg,
        )
    }

    private fun initialStatus(): HeadingStatus {
        val estimate = fusion.estimate(clockMs())
        return HeadingStatus(
            source = estimate.source,
            confidence = estimate.confidence,
            ageSeconds = estimate.ageSeconds,
            expectedErrorDeg = estimate.expectedErrorDeg,
        )
    }
}
