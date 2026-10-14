package com.fieldar.plotfinder.plugin

import android.content.Context
import android.hardware.display.DisplayManager
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.View
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class ArCoreViewFactory(private val plugin: PlotFinderPlugin) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = ArCoreView(context, plugin)
}

/**
 * The camera preview and visual-inertial tracking, from one ARCore session.
 *
 * ARCore is used for three on-device things, none needing a network or Street
 * View - none of what the README rules out for farmland:
 *  - **motion tracking**, the visual-inertial odometry that follows the phone
 *    through space from the camera image and the IMU;
 *  - **horizontal planes**, only to find the real floor, so the plot lies on
 *    the ground rather than at an assumed 1.6 m below the phone;
 *  - **depth**, where the device supports it, so people, trees and walls in
 *    front of the boundary hide it.
 *
 * The plot itself is drawn here, by [ArOverlayRenderer], in the same GL frame
 * as the camera image and with that frame's own camera matrices - so it cannot
 * lag the picture. Dart supplies the plot geometry once and its geo-placement
 * whenever that changes; Flutter draws only the label and chrome on top.
 *
 * What it gives the Dart side, once a frame: the camera pose, the projection,
 * the floor height and whether depth is active.
 */
class ArCoreView(private val context: Context, private val plugin: PlotFinderPlugin) :
    PlatformView,
    GLSurfaceView.Renderer {

    private val surface = GLSurfaceView(context).apply {
        preserveEGLContextOnPause = true
        // ES 3 for the two-byte depth texture; every ARCore device has it.
        setEGLContextClientVersion(3)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        setRenderer(this@ArCoreView)
        renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
    }

    private val background = BackgroundRenderer()
    private val overlay = ArOverlayRenderer()
    private val view = FloatArray(16)
    private val main = Handler(Looper.getMainLooper())
    private val projection = FloatArray(16)

    @Volatile private var session: Session? = null
    @Volatile private var viewportWidth = 0
    @Volatile private var viewportHeight = 0
    @Volatile private var geometryDirty = true
    private var paused = true
    private var depthEnabled = false

    /** Where the plot sits in the session; see [ArOverlayRenderer.draw]. */
    @Volatile private var placement: FloatArray? = null

    /**
     * The ground's height in ARCore's world. Until a floor plane is found it
     * is assumed [ASSUMED_EYE_HEIGHT_M] below where the phone first tracked.
     */
    private var floorY = Float.NaN
    private var floorDetected = false
    private var frameCount = 0L

    init {
        session = openSession()
        plugin.attachArView(this)
        resume()
    }

    private fun openSession(): Session? = try {
        Session(context).also { s ->
            val config = Config(s).apply {
                focusMode = Config.FocusMode.AUTO
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                planeFindingMode = Config.PlaneFindingMode.HORIZONTAL
                lightEstimationMode = Config.LightEstimationMode.DISABLED
                depthMode = if (s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                    Config.DepthMode.AUTOMATIC
                } else {
                    Config.DepthMode.DISABLED
                }
            }
            s.configure(config)
            depthEnabled = config.depthMode == Config.DepthMode.AUTOMATIC
        }
    } catch (e: Exception) {
        Log.w(TAG, "ARCore session unavailable", e)
        plugin.emitArError("session: ${e.javaClass.simpleName}")
        null
    }

    fun resume() {
        if (!paused) return
        val s = session ?: return
        try {
            s.resume()
            surface.onResume()
            paused = false
            geometryDirty = true
        } catch (e: Exception) {
            Log.w(TAG, "ARCore resume failed", e)
            plugin.emitArError("resume: ${e.javaClass.simpleName}")
        }
    }

    fun pause() {
        if (paused) return
        paused = true
        surface.onPause()
        session?.pause()
    }

    override fun getView(): View = surface

    fun setScene(scene: OverlayScene?) {
        surface.queueEvent { overlay.setScene(scene) }
    }

    fun setPlacement(next: FloatArray?) {
        placement = next
    }

    override fun dispose() {
        plugin.detachArView(this)
        pause()
        session?.close()
        session = null
    }

    // --- GL thread ---------------------------------------------------------------

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        background.create()
        overlay.create()
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        viewportWidth = width
        viewportHeight = height
        geometryDirty = true
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        if (paused || viewportWidth == 0) return
        try {
            if (geometryDirty) {
                s.setDisplayGeometry(displayRotation(), viewportWidth, viewportHeight)
                geometryDirty = false
            }
            s.setCameraTextureName(background.textureId)
            val frame = s.update()
            background.draw(frame)
            val camera = frame.camera
            if (camera.trackingState == TrackingState.TRACKING) {
                val pose = camera.pose
                updateFloor(s, pose.ty())
                overlay.updateDepth(frame, depthEnabled)
                camera.getViewMatrix(view, 0)
                camera.getProjectionMatrix(projection, 0, NEAR_M, FAR_M)
                overlay.draw(
                    view, projection, placement, floorY, pose.tx(), pose.tz(),
                    viewportWidth, viewportHeight,
                )
            }
            emit(frame)
        } catch (e: Exception) {
            // One bad frame - a camera hiccup, a session mid-pause - is not
            // worth tearing the view down for. The next frame tries again.
            Log.w(TAG, "ARCore frame failed", e)
        }
    }

    /**
     * Finds the floor: the lowest upward-facing plane a reasonable way below
     * the phone. Tables and benches are planes too, which is why it is the
     * lowest one and not the nearest. Checked twice a second - plane lists do
     * not change faster than that.
     */
    private fun updateFloor(s: Session, cameraY: Float) {
        if (floorY.isNaN()) floorY = cameraY - ASSUMED_EYE_HEIGHT_M
        if (frameCount++ % 15L != 0L) return
        var lowest = Float.NaN
        for (plane in s.getAllTrackables(Plane::class.java)) {
            if (plane.trackingState != TrackingState.TRACKING) continue
            if (plane.subsumedBy != null) continue
            if (plane.type != Plane.Type.HORIZONTAL_UPWARD_FACING) continue
            if (plane.extentX * plane.extentZ < MIN_FLOOR_AREA_M2) continue
            val y = plane.centerPose.ty()
            if (y > cameraY - MIN_FLOOR_DROP_M) continue
            if (lowest.isNaN() || y < lowest) lowest = y
        }
        if (lowest.isNaN()) return
        // Eased in rather than jumped to, so a refined plane estimate does not
        // make the whole plot hop.
        floorY = if (floorDetected) floorY + 0.3f * (lowest - floorY) else lowest
        floorDetected = true
    }

    /**
     * Sends `[state, timestampMs, tx, ty, tz, qx, qy, qz, qw, p0, p5, width,
     * height, failure, floorY, floorDetected, depthActive]` to Dart. One flat array, because it crosses the channel
     * thirty times a second.
     *
     * The timestamp is elapsedRealtime, the clock the location fixes use.
     */
    private fun emit(frame: Frame) {
        val camera = frame.camera
        val pose = camera.displayOrientedPose
        camera.getProjectionMatrix(projection, 0, NEAR_M, FAR_M)
        val t = pose.translation
        val q = pose.rotationQuaternion
        val event = doubleArrayOf(
            when (camera.trackingState) {
                TrackingState.TRACKING -> 1.0
                TrackingState.PAUSED -> 0.0
                else -> -1.0
            },
            SystemClock.elapsedRealtime().toDouble(),
            t[0].toDouble(), t[1].toDouble(), t[2].toDouble(),
            q[0].toDouble(), q[1].toDouble(), q[2].toDouble(), q[3].toDouble(),
            projection[0].toDouble(), projection[5].toDouble(),
            viewportWidth.toDouble(), viewportHeight.toDouble(),
            failureCode(camera.trackingFailureReason).toDouble(),
            if (floorY.isNaN()) Double.NaN else floorY.toDouble(),
            if (floorDetected) 1.0 else 0.0,
            if (overlay.depthActive) 1.0 else 0.0,
        )
        main.post { plugin.emitArFrame(event) }
    }

    private fun failureCode(reason: TrackingFailureReason): Int = when (reason) {
        TrackingFailureReason.NONE -> 0
        TrackingFailureReason.BAD_STATE -> 1
        TrackingFailureReason.INSUFFICIENT_LIGHT -> 2
        TrackingFailureReason.EXCESSIVE_MOTION -> 3
        TrackingFailureReason.INSUFFICIENT_FEATURES -> 4
        TrackingFailureReason.CAMERA_UNAVAILABLE -> 5
        else -> 1
    }

    private fun displayRotation(): Int =
        (context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)
            ?.getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: 0

    private companion object {
        const val TAG = "PlotFinder"
        const val NEAR_M = 0.1f
        const val FAR_M = 500f
        const val ASSUMED_EYE_HEIGHT_M = 1.6f
        const val MIN_FLOOR_DROP_M = 0.8f
        const val MIN_FLOOR_AREA_M2 = 0.25f
    }
}

/**
 * Draws the camera image ARCore writes into an external OES texture, cropped
 * to fill the view exactly as ARCore's projection assumes.
 */
private class BackgroundRenderer {
    var textureId = -1
        private set

    private var program = 0
    private var positionAttrib = 0
    private var texCoordAttrib = 0

    private val quad: FloatBuffer = floatBuffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val texCoords: FloatBuffer = floatBuffer(FloatArray(8))

    fun create() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        val target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
        GLES20.glBindTexture(target, textureId)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)

        program = GLES20.glCreateProgram().also { p ->
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, VERTEX))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT))
            GLES20.glLinkProgram(p)
        }
        positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
        texCoordAttrib = GLES20.glGetAttribLocation(program, "a_TexCoord")
    }

    fun draw(frame: Frame) {
        if (frame.hasDisplayGeometryChanged()) {
            quad.rewind()
            texCoords.rewind()
            frame.transformCoordinates2d(
                Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
                quad,
                Coordinates2d.TEXTURE_NORMALIZED,
                texCoords,
            )
        }
        // No image yet: nothing valid in the texture.
        if (frame.timestamp == 0L) return

        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthMask(false)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glUseProgram(program)
        quad.rewind()
        texCoords.rewind()
        GLES20.glVertexAttribPointer(positionAttrib, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glVertexAttribPointer(texCoordAttrib, 2, GLES20.GL_FLOAT, false, 0, texCoords)
        GLES20.glEnableVertexAttribArray(positionAttrib)
        GLES20.glEnableVertexAttribArray(texCoordAttrib)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(positionAttrib)
        GLES20.glDisableVertexAttribArray(texCoordAttrib)
        GLES20.glDepthMask(true)
    }

    private fun shader(type: Int, source: String): Int = GLES20.glCreateShader(type).also {
        GLES20.glShaderSource(it, source)
        GLES20.glCompileShader(it)
    }

    private companion object {
        val VERTEX = """
            attribute vec4 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = a_Position;
                v_TexCoord = a_TexCoord;
            }
        """.trimIndent()

        val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 v_TexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, v_TexCoord);
            }
        """.trimIndent()

        fun floatBuffer(values: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(values)
                rewind()
            }
    }
}
