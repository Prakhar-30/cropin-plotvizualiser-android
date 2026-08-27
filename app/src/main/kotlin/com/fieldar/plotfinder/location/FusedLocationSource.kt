package com.fieldar.plotfinder.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import androidx.core.content.ContextCompat
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.heading.LocationSample
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Phone GNSS, at one fix per second.
 *
 * One fix per second is not a battery choice, it is what course over ground
 * needs: bearings are only meaningful while walking, and a 20 m segment at
 * walking pace is about fifteen seconds, so anything slower than 1 Hz would
 * leave too few samples to tell a straight line from a curve.
 *
 * No external receiver, no RTK, no NTRIP - phone only, by constraint.
 */
class FusedLocationSource(private val context: Context) : LocationSource {

    private val client = LocationServices.getFusedLocationProviderClient(context)

    private val _location = MutableStateFlow<LocationSample?>(null)
    override val location: StateFlow<LocationSample?> = _location.asStateFlow()

    private var running = false

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.lastLocation?.let { _location.value = it.toSample() }
        }
    }

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    override fun start() {
        if (running || !hasPermission()) return
        running = true
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_MS)
            .setMinUpdateIntervalMillis(INTERVAL_MS)
            .setWaitForAccurateLocation(false)
            .build()
        client.requestLocationUpdates(request, callback, context.mainLooper)
    }

    override fun stop() {
        if (!running) return
        running = false
        client.removeLocationUpdates(callback)
    }

    private companion object {
        const val INTERVAL_MS = 1_000L
    }
}

/**
 * `hasBearing()` is false when the receiver cannot tell which way you are
 * moving, which is exactly the case the course-over-ground detector must reject
 * rather than guess at - so the null is passed through rather than defaulted.
 */
fun Location.toSample(): LocationSample = LocationSample(
    position = LatLng(latitude, longitude),
    bearingDeg = if (hasBearing()) bearing.toDouble() else null,
    speedMps = if (hasSpeed()) speed.toDouble() else 0.0,
    accuracyM = if (hasAccuracy()) accuracy.toDouble() else DEFAULT_ACCURACY_M,
    timestampMs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        elapsedRealtimeNanos / 1_000_000
    } else {
        time
    },
)

/**
 * Assumed accuracy when a fix does not report one. Deliberately pessimistic:
 * this number sets the width of the near-mode band, and a band that is too wide
 * is an honest statement while one that is too narrow is a false claim.
 */
const val DEFAULT_ACCURACY_M = 15.0
