package com.fieldar.plotfinder.ui.ar

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Log
import android.util.SizeF
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import kotlin.math.atan2
import kotlin.math.min

/**
 * The camera preview, and the field of view it is actually showing.
 *
 * The FOV is read from `CameraCharacteristics` rather than assumed. A hardcoded
 * 60 degrees is wrong on most phones - real rear cameras run from roughly 60 to
 * 80 degrees horizontally - and the error goes straight into the projection as a
 * scale factor on every screen position, spreading or squeezing the whole plot
 * outline about the centre of the image.
 */
data class CameraGeometry(
    /** Field of view of the sensor's short axis, in degrees. */
    val sensorShortFovDeg: Double,
    /** Long side over short side, e.g. 4/3 or 16/9. */
    val sensorAspect: Double,
) {
    /**
     * FOV across the width of a portrait viewport.
     *
     * The preview is the sensor rotated a quarter turn, so the screen's *width*
     * shows the sensor's *short* axis. Getting this the wrong way round is a
     * silent 20-degree error that looks plausible until the overlay is compared
     * with a real boundary.
     */
    val portraitHorizontalFovDeg: Double get() = sensorShortFovDeg

    /** Aspect ratio of the preview when the phone is held upright. */
    val portraitAspect: Double get() = 1.0 / sensorAspect

    companion object {
        /**
         * Fallback when the characteristics are unreadable. Chosen at the wide
         * end of typical so the overlay errs towards spreading out rather than
         * bunching up, and flagged rather than silently assumed.
         */
        val FALLBACK = CameraGeometry(
            sensorShortFovDeg = 52.0,
            sensorAspect = 4.0 / 3.0,
        )
    }
}

/** Log tag for the handful of values worth reading over adb on a real device. */
const val LOG_TAG = "PlotFinder"

/** Reads the rear camera's real geometry, or returns the flagged fallback. */
fun readCameraGeometry(context: Context): CameraGeometry {
    val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        ?: return CameraGeometry.FALLBACK

    return runCatching {
        val id = manager.cameraIdList.first { cameraId ->
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        }
        val characteristics = manager.getCameraCharacteristics(id)
        val size: SizeF = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)!!
        val focalMm = characteristics
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)!!
            .first()

        val long = maxOf(size.width, size.height).toDouble()
        val short = min(size.width, size.height).toDouble()
        val geometry = CameraGeometry(
            sensorShortFovDeg = fovDeg(short, focalMm.toDouble()),
            sensorAspect = long / short,
        )
        // The single number the whole projection scales on. Worth being able to
        // read off a real device rather than inferring it from a wrong overlay.
        Log.i(
            LOG_TAG,
            "camera id=%s sensor=%.2fx%.2fmm focal=%.2fmm -> portrait hFOV=%.1f deg aspect=%.3f"
                .format(
                    id, size.width, size.height, focalMm,
                    geometry.portraitHorizontalFovDeg, geometry.portraitAspect,
                ),
        )
        geometry
    }.getOrElse {
        Log.w(LOG_TAG, "camera characteristics unreadable - using fallback FOV", it)
        CameraGeometry.FALLBACK
    }
}

private fun fovDeg(sensorExtentMm: Double, focalMm: Double): Double =
    Math.toDegrees(2.0 * atan2(sensorExtentMm / 2.0, focalMm))

/**
 * CameraX preview filling its parent.
 *
 * The caller sizes the parent to the camera's own aspect ratio, so `FILL_CENTER`
 * has nothing to crop. That matters more than it sounds: a cropped preview shows
 * a narrower field of view than the characteristics report, and the projection
 * would then be scaled wrongly across the whole image.
 */
@Composable
fun CameraPreview(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val previewView = PreviewView(ctx).apply {
                scaleType = PreviewView.ScaleType.FILL_CENTER
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            }
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val provider = providerFuture.get()
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }
                provider.unbindAll()
                runCatching {
                    provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview)
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        },
    )
}
