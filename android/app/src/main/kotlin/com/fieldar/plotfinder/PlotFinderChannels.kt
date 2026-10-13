package com.fieldar.plotfinder

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.display.DisplayManager
import android.location.Location
import android.os.Build
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.Surface
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The three things the Dart side needs from Android that no Flutter plugin
 * hands over faithfully. Everything here is plumbing; every decision made with
 * these values - smoothing, heading fusion, projection - lives in Dart.
 *
 *  - **Rotation vectors.** Both `TYPE_ROTATION_VECTOR` (knows magnetic north)
 *    and `TYPE_GAME_ROTATION_VECTOR` (gyro + accel, no magnetometer), already
 *    turned into rotation matrices and remapped to the display. Plugins expose
 *    raw accelerometer/gyro/magnetometer streams, which would mean re-deriving
 *    Android's own sensor fusion in Dart and getting it subtly different.
 *  - **Camera geometry.** Physical sensor size and focal length from
 *    `CameraCharacteristics`. The FOV is the scale factor on every projected
 *    point, and the camera plugin does not expose it.
 *  - **Fixes from the fused provider**, with `hasBearing()` passed through as a
 *    null. Course over ground must reject a fix that cannot say which way it is
 *    moving rather than read it as "due north".
 */
class PlotFinderChannels(private val context: Context) {

    private var methods: MethodChannel? = null
    private var rotation: EventChannel? = null
    private var location: EventChannel? = null

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val magneticRotation: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val gameRotation: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)

    // Read through DisplayManager rather than WindowManager or `Context.display`:
    // this is an application context, and those two either need a visual context
    // or are deprecated in a way that throws on newer Android.
    private val display: Display? = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
        .getDisplay(Display.DEFAULT_DISPLAY)

    private var rotationListener: SensorEventListener? = null
    private var locationCallback: LocationCallback? = null
    private val fused = LocationServices.getFusedLocationProviderClient(context)

    fun register(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, "plotfinder/platform").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "cameraGeometry" -> result.success(readCameraGeometry())
                    "deviceInfo" -> result.success(deviceInfo())
                    else -> result.notImplemented()
                }
            }
        }
        rotation = EventChannel(messenger, "plotfinder/rotation").apply {
            setStreamHandler(RotationHandler())
        }
        location = EventChannel(messenger, "plotfinder/location").apply {
            setStreamHandler(LocationHandler())
        }
    }

    fun dispose() {
        stopRotation()
        stopLocation()
        methods?.setMethodCallHandler(null)
        rotation?.setStreamHandler(null)
        location?.setStreamHandler(null)
    }

    // --- camera ---------------------------------------------------------------

    /**
     * The rear camera's physical sensor and focal length, or null.
     *
     * Raw millimetres rather than a finished FOV, because which axis of the
     * sensor the screen width shows - and how much of it the preview crops -
     * depends on the preview the Dart side ends up with. See `CameraGeometry`.
     */
    private fun readCameraGeometry(): Map<String, Any>? {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return null
        return runCatching {
            val id = manager.cameraIdList.first { cameraId ->
                manager.getCameraCharacteristics(cameraId)
                    .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            }
            val characteristics = manager.getCameraCharacteristics(id)
            val size = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)!!
            val focalMm = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)!!.first()
            Log.i(TAG, "camera id=$id sensor=${size.width}x${size.height}mm focal=${focalMm}mm")
            mapOf(
                "sensorWidthMm" to size.width.toDouble(),
                "sensorHeightMm" to size.height.toDouble(),
                "focalMm" to focalMm.toDouble(),
            )
        }.getOrElse {
            Log.w(TAG, "camera characteristics unreadable - Dart will use the fallback FOV", it)
            null
        }
    }

    private fun deviceInfo(): Map<String, String> {
        val version = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: ""
        return mapOf(
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "appVersion" to version,
        )
    }

    // --- rotation -------------------------------------------------------------

    private inner class RotationHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stopRotation()
            val matrix = FloatArray(9)
            val remapped = FloatArray(9)
            val listener = object : SensorEventListener {
                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

                override fun onSensorChanged(event: SensorEvent) {
                    val isGame = event.sensor.type == Sensor.TYPE_GAME_ROTATION_VECTOR
                    SensorManager.getRotationMatrixFromVector(matrix, event.values)
                    val out = remapToDisplay(matrix, remapped)
                    events.success(
                        mapOf(
                            "game" to isGame,
                            // Without a game rotation vector the magnetic one
                            // carries instead: worse, but never absent.
                            "carrier" to (isGame || gameRotation == null),
                            "m" to DoubleArray(9) { out[it].toDouble() },
                        ),
                    )
                }
            }
            rotationListener = listener
            magneticRotation?.let { sensorManager.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME) }
            gameRotation?.let { sensorManager.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME) }
        }

        override fun onCancel(arguments: Any?) = stopRotation()
    }

    private fun stopRotation() {
        rotationListener?.let { sensorManager.unregisterListener(it) }
        rotationListener = null
    }

    /**
     * Rotates the sensor frame into the frame the screen is actually drawn in.
     *
     * The app is locked to portrait, but "portrait" is the natural orientation
     * only on phones; on a natural-landscape device the sensor axes are 90
     * degrees off the screen axes and the whole overlay would render on its side.
     */
    private fun remapToDisplay(matrix: FloatArray, out: FloatArray): FloatArray {
        val (axisX, axisY) = when (display?.rotation) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> return matrix
        }
        SensorManager.remapCoordinateSystem(matrix, axisX, axisY, out)
        return out
    }

    // --- location -------------------------------------------------------------

    /**
     * Phone GNSS, at one fix per second.
     *
     * One fix per second is not a battery choice, it is what course over ground
     * needs: a 20 m segment at walking pace is about fifteen seconds, so anything
     * slower than 1 Hz would leave too few samples to tell a straight line from
     * a curve.
     */
    private inner class LocationHandler : EventChannel.StreamHandler {
        @SuppressLint("MissingPermission")
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stopLocation()
            val granted = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                events.error("no_permission", "ACCESS_FINE_LOCATION not granted", null)
                return
            }
            val callback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    result.lastLocation?.let { events.success(it.toMap()) }
                }
            }
            locationCallback = callback
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_MS)
                .setMinUpdateIntervalMillis(INTERVAL_MS)
                .setWaitForAccurateLocation(false)
                .build()
            fused.requestLocationUpdates(request, callback, Looper.getMainLooper())
        }

        override fun onCancel(arguments: Any?) = stopLocation()
    }

    private fun stopLocation() {
        locationCallback?.let { fused.removeLocationUpdates(it) }
        locationCallback = null
    }

    /**
     * `hasBearing()` is false when the receiver cannot tell which way you are
     * moving, which is exactly the case the course-over-ground detector must
     * reject rather than guess at - so the null is passed through rather than
     * defaulted. Speed and accuracy go through as null too; the Dart side owns
     * the defaults.
     */
    private fun Location.toMap(): Map<String, Any?> = mapOf(
        "lat" to latitude,
        "lng" to longitude,
        "bearing" to if (hasBearing()) bearing.toDouble() else null,
        "speed" to if (hasSpeed()) speed.toDouble() else null,
        "accuracy" to if (hasAccuracy()) accuracy.toDouble() else null,
        "timestampMs" to elapsedRealtimeNanos / 1_000_000,
    )

    private companion object {
        const val TAG = "PlotFinder"
        const val INTERVAL_MS = 1_000L
    }
}
