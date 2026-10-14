package com.fieldar.plotfinder.plugin

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.display.DisplayManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The few things the Dart side needs from Android that no Flutter plugin hands
 * over faithfully. Everything here is plumbing; every decision made with these
 * values - smoothing, heading fusion, projection - lives in Dart.
 *
 *  - **Acceleration magnitude**, for counting steps, stamped on the same clock
 *    as the fixes so the two can be fused.
 *  - **Rotation vectors.** Both `TYPE_ROTATION_VECTOR` (knows magnetic north)
 *    and `TYPE_GAME_ROTATION_VECTOR` (gyro + accel, no magnetometer), already
 *    turned into rotation matrices and remapped to the display.
 *  - **Camera geometry.** Physical sensor size and focal length from
 *    `CameraCharacteristics`, which set the FOV the whole projection scales on.
 *  - **Fixes** with `hasBearing()` passed through as a null, so course over
 *    ground rejects a fix that cannot say which way it is moving.
 *  - **Permissions**, camera and fine location.
 *
 * Written to be embedded in someone else's app, so it depends on nothing but
 * the Android framework and the Flutter embedding. In particular it does not
 * use Google Play Services location: a host app that pins a different major
 * version of it would have Gradle force one version on everyone, and 20.x and
 * 21.x are binary-incompatible - a failure that compiles cleanly and crashes at
 * runtime. The framework's own fused provider (API 31+) or GPS provider gives
 * the same 1 Hz fixes outdoors, which is where this is used.
 */
class PlotFinderPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private var methods: MethodChannel? = null
    private var rotation: EventChannel? = null
    private var location: EventChannel? = null
    private var acceleration: EventChannel? = null

    private var activity: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null

    private var sensorManager: SensorManager? = null
    private var magneticRotation: Sensor? = null
    private var gameRotation: Sensor? = null
    private var rotationListener: SensorEventListener? = null
    private var accelerometer: Sensor? = null
    private var accelerationListener: SensorEventListener? = null

    private var locationManager: LocationManager? = null
    private var locationListener: LocationListener? = null

    // --- lifecycle -------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        magneticRotation = sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        gameRotation = sensorManager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

        val messenger = binding.binaryMessenger
        methods = MethodChannel(messenger, "$CHANNEL/platform").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "cameraGeometry" -> result.success(readCameraGeometry())
                    "deviceInfo" -> result.success(deviceInfo())
                    "hasPermissions" -> result.success(hasPermissions())
                    "requestPermissions" -> requestPermissions(result)
                    "openAppSettings" -> result.success(openAppSettings())
                    else -> result.notImplemented()
                }
            }
        }
        rotation = EventChannel(messenger, "$CHANNEL/rotation").apply { setStreamHandler(RotationHandler()) }
        location = EventChannel(messenger, "$CHANNEL/location").apply { setStreamHandler(LocationHandler()) }
        acceleration = EventChannel(messenger, "$CHANNEL/acceleration").apply {
            setStreamHandler(AccelerationHandler())
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopRotation()
        stopLocation()
        stopAcceleration()
        methods?.setMethodCallHandler(null)
        rotation?.setStreamHandler(null)
        location?.setStreamHandler(null)
        acceleration?.setStreamHandler(null)
        methods = null
        rotation = null
        location = null
        acceleration = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    // --- permissions -----------------------------------------------------------

    private fun granted(permission: String): Boolean =
        // Before API 23 permissions are granted at install time.
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun hasPermissions(): Boolean =
        granted(Manifest.permission.CAMERA) && granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun requestPermissions(result: MethodChannel.Result) {
        val host: Activity? = activity?.activity
        if (hasPermissions() || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(hasPermissions())
            return
        }
        if (host == null || pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        host.requestPermissions(
            arrayOf(
                Manifest.permission.CAMERA,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        // Only ever answer our own request: the host app's requests come
        // through this same listener chain.
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        pendingPermission?.success(hasPermissions())
        pendingPermission = null
        return true
    }

    /** Once Android stops showing the dialog, the setting is the only way back. */
    private fun openAppSettings(): Boolean = runCatching {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    }.getOrDefault(false)

    // --- camera ----------------------------------------------------------------

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

    @Suppress("DEPRECATION")
    private fun deviceInfo(): Map<String, String> {
        val version = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: ""
        return mapOf(
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "appVersion" to version,
        )
    }

    // --- rotation --------------------------------------------------------------

    private inner class RotationHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stopRotation()
            val manager = sensorManager ?: return
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
            magneticRotation?.let { manager.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME) }
            gameRotation?.let { manager.registerListener(listener, it, SensorManager.SENSOR_DELAY_GAME) }
        }

        override fun onCancel(arguments: Any?) = stopRotation()
    }

    private fun stopRotation() {
        rotationListener?.let { sensorManager?.unregisterListener(it) }
        rotationListener = null
    }

    /**
     * Rotates the sensor frame into the frame the screen is actually drawn in.
     *
     * The AR screen is locked to portrait, but "portrait" is the natural
     * orientation only on phones; on a natural-landscape device the sensor axes
     * are 90 degrees off the screen axes and the whole overlay would render on
     * its side. Read through DisplayManager because this is an application
     * context.
     */
    private fun remapToDisplay(matrix: FloatArray, out: FloatArray): FloatArray {
        val display = (context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)
            ?.getDisplay(Display.DEFAULT_DISPLAY)
        val (axisX, axisY) = when (display?.rotation) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> return matrix
        }
        SensorManager.remapCoordinateSystem(matrix, axisX, axisY, out)
        return out
    }

    // --- acceleration ----------------------------------------------------------

    /**
     * Magnitude of the raw accelerometer, gravity included, for step counting.
     *
     * Only the magnitude crosses the channel: it does not depend on how the
     * phone is held, and it is one number instead of three at 50 Hz. Each
     * event is `[timestampMs, magnitude]`, with the timestamp from the sensor
     * event itself - nanoseconds since boot, the same clock as
     * `Location.elapsedRealtimeNanos` - so a step and a fix can be ordered
     * against each other exactly.
     */
    private inner class AccelerationHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stopAcceleration()
            val manager = sensorManager ?: return
            val sensor = accelerometer ?: return
            val listener = object : SensorEventListener {
                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

                override fun onSensorChanged(event: SensorEvent) {
                    val x = event.values[0]
                    val y = event.values[1]
                    val z = event.values[2]
                    events.success(
                        doubleArrayOf(
                            (event.timestamp / 1_000_000L).toDouble(),
                            Math.sqrt((x * x + y * y + z * z).toDouble()),
                        ),
                    )
                }
            }
            accelerationListener = listener
            manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_GAME)
        }

        override fun onCancel(arguments: Any?) = stopAcceleration()
    }

    private fun stopAcceleration() {
        accelerationListener?.let { sensorManager?.unregisterListener(it) }
        accelerationListener = null
    }

    // --- location --------------------------------------------------------------

    /**
     * Phone GNSS, at one fix per second.
     *
     * One fix per second is not a battery choice, it is what course over ground
     * needs: a 20 m segment at walking pace is about fifteen seconds, so anything
     * slower than 1 Hz would leave too few samples to tell a straight line from
     * a curve.
     */
    private inner class LocationHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            stopLocation()
            val manager = locationManager
            if (manager == null) {
                events.error("no_location", "no LocationManager on this device", null)
                return
            }
            if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
                events.error("no_permission", "ACCESS_FINE_LOCATION not granted", null)
                return
            }
            // Every callback is overridden, not left to the interface defaults:
            // those defaults only exist from API 30, and on older devices the
            // framework calling a missing one is an AbstractMethodError.
            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    events.success(location.toMap())
                }

                @Deprecated("Required below API 30")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

                override fun onProviderEnabled(provider: String) = Unit

                override fun onProviderDisabled(provider: String) = Unit
            }
            locationListener = listener
            try {
                manager.requestLocationUpdates(provider(manager), INTERVAL_MS, 0f, listener, Looper.getMainLooper())
            } catch (e: SecurityException) {
                events.error("no_permission", e.message, null)
            } catch (e: IllegalArgumentException) {
                events.error("no_provider", e.message, null)
            }
        }

        override fun onCancel(arguments: Any?) = stopLocation()
    }

    /** The platform's fused provider where it exists (API 31+), GNSS otherwise. */
    private fun provider(manager: LocationManager): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            manager.allProviders.contains(LocationManager.FUSED_PROVIDER)
        ) {
            LocationManager.FUSED_PROVIDER
        } else {
            LocationManager.GPS_PROVIDER
        }

    private fun stopLocation() {
        locationListener?.let { locationManager?.removeUpdates(it) }
        locationListener = null
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
        const val CHANNEL = "com.fieldar.plot_finder"
        const val INTERVAL_MS = 1_000L

        /** Must fit in 16 bits for hosts still using fragment-based requests. */
        const val PERMISSION_REQUEST_CODE = 0x5046
    }
}
