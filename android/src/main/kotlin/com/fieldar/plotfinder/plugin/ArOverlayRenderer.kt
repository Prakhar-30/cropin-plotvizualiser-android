package com.fieldar.plotfinder.plugin

import android.opengl.GLES20
import android.opengl.GLES30
import android.opengl.Matrix
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * The plot, as Dart describes it, in a plot-local metric frame: east, north and
 * up in metres from the plot's centroid, with true north up.
 *
 * Built once per plot, health layer or heading-confidence change - never per
 * frame. What moves per frame is only the camera, which ARCore supplies.
 */
internal class OverlayScene(
    /** Ground fill, already triangulated: (east, north) per vertex. */
    val fill: FloatArray,
    /** The boundary, open ring: (east, north) per vertex. */
    val ring: FloatArray,
    /** Crop-health cells, triangulated: (east, north, r, g, b, a) per vertex. */
    val cells: FloatArray,
    val wallHeight: Float,
    val postHeight: Float,
    /** Plot colour, 0xAARRGGBB, already greyed out by Dart when untrusted. */
    val tint: Int,
    /** Overall opacity from heading confidence. */
    val alpha: Float,
    val wallAlpha: Float,
    val fillAlpha: Float,
    val railAlpha: Float,
) {
    companion object {
        fun from(arguments: Any?): OverlayScene? {
            val map = arguments as? Map<*, *> ?: return null
            fun floats(key: String): FloatArray = when (val v = map[key]) {
                is FloatArray -> v
                is DoubleArray -> FloatArray(v.size) { v[it].toFloat() }
                is List<*> -> FloatArray(v.size) { (v[it] as Number).toFloat() }
                else -> FloatArray(0)
            }
            fun number(key: String, default: Float): Float = (map[key] as? Number)?.toFloat() ?: default
            return OverlayScene(
                fill = floats("fill"),
                ring = floats("ring"),
                cells = floats("cells"),
                wallHeight = number("wallHeight", 2.6f),
                postHeight = number("postHeight", 2.5f),
                tint = (map["tint"] as? Number)?.toLong()?.toInt() ?: 0xFFFF3B30.toInt(),
                alpha = number("alpha", 1f),
                wallAlpha = number("wallAlpha", 0.28f),
                fillAlpha = number("fillAlpha", 0.18f),
                railAlpha = number("railAlpha", 1f),
            )
        }
    }
}

/**
 * Draws the plot in the same GL frame as ARCore's camera image.
 *
 * This is the fix for the overlay swimming as the phone turns. Drawn on the
 * Flutter canvas, the overlay always lagged the picture under it by the trip
 * through the event channel and the next Flutter frame - one or two frames, so
 * at an ordinary 30 degrees per second of hand motion the boundary trailed the
 * scene by one or two degrees and slid back when the hand stopped. Here it is
 * projected with the view and projection matrices of the very frame the camera
 * image came from, so the two cannot disagree.
 *
 * It also makes occlusion possible. Where ARCore's Depth API is available, each
 * fragment of the overlay is compared with the measured depth of the scene at
 * that pixel; a person, a tree or a wall standing nearer than the boundary hides
 * it - not completely, but down to a faint ghost, so the boundary is never lost
 * behind the crop it encloses ("X-ray" rendering).
 */
internal class ArOverlayRenderer {
    private var program = 0
    private var aPosition = 0
    private var aColor = 0
    private var uMvp = 0
    private var uModelView = 0
    private var uFadeStart = 0
    private var uFadeEnd = 0
    private var uFadeFloor = 0
    private var uAlpha = 0
    private var uUseDepth = 0
    private var uDepth = 0
    private var uViewport = 0
    private var uUvOrigin = 0
    private var uUvX = 0
    private var uUvY = 0
    private var uGhost = 0

    private var lineWidthMax = 1f

    private var depthTexture = 0
    private var depthAvailableAt = 0L
    private val uvTransform = FloatArray(6)
    private val uvIn = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f)

    private var scene: OverlayScene? = null
    private var fillVerts: FloatBuffer? = null
    private var fillCount = 0
    private var outlineVerts: FloatBuffer? = null
    private var outlineCount = 0
    private var wallVerts: FloatBuffer? = null
    private var railVerts: FloatBuffer? = null
    private var postVerts: FloatBuffer? = null
    private var edgeCount = 0
    private var edgeMid = FloatArray(0)
    private var cellPositions: FloatBuffer? = null
    private var cellColors: FloatBuffer? = null
    private var cellCount = 0

    private val model = FloatArray(16)
    private val modelView = FloatArray(16)
    private val mvp = FloatArray(16)
    private val edgeOrder = ArrayList<Int>()

    fun create() {
        program = GLES20.glCreateProgram().also { p ->
            GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, VERTEX))
            GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT))
            GLES20.glLinkProgram(p)
        }
        aPosition = GLES20.glGetAttribLocation(program, "a_Position")
        aColor = GLES20.glGetAttribLocation(program, "a_Color")
        uMvp = GLES20.glGetUniformLocation(program, "u_Mvp")
        uModelView = GLES20.glGetUniformLocation(program, "u_ModelView")
        uFadeStart = GLES20.glGetUniformLocation(program, "u_FadeStart")
        uFadeEnd = GLES20.glGetUniformLocation(program, "u_FadeEnd")
        uFadeFloor = GLES20.glGetUniformLocation(program, "u_FadeFloor")
        uAlpha = GLES20.glGetUniformLocation(program, "u_Alpha")
        uUseDepth = GLES20.glGetUniformLocation(program, "u_UseDepth")
        uDepth = GLES20.glGetUniformLocation(program, "u_Depth")
        uViewport = GLES20.glGetUniformLocation(program, "u_Viewport")
        uUvOrigin = GLES20.glGetUniformLocation(program, "u_UvOrigin")
        uUvX = GLES20.glGetUniformLocation(program, "u_UvX")
        uUvY = GLES20.glGetUniformLocation(program, "u_UvY")
        uGhost = GLES20.glGetUniformLocation(program, "u_Ghost")

        val range = FloatArray(2)
        GLES20.glGetFloatv(GLES20.GL_ALIASED_LINE_WIDTH_RANGE, range, 0)
        lineWidthMax = max(1f, range[1])

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        depthTexture = textures[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, depthTexture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        // Nearest, never linear: the two bytes of a depth sample must not be
        // blended with a neighbour's, or the high byte smears across edges.
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)

        scene?.let { build(it) }
    }

    fun setScene(next: OverlayScene?) {
        scene = next
        if (next == null) {
            edgeCount = 0
            fillCount = 0
            cellCount = 0
            outlineCount = 0
        } else if (program != 0) {
            build(next)
        }
    }

    /** True while a depth image arrived within the last second. */
    val depthActive: Boolean
        get() = System.nanoTime() - depthAvailableAt < 1_000_000_000L

    /**
     * Uploads this frame's depth image, when the session has one.
     *
     * The 16-bit millimetre values go up as a two-channel byte texture and are
     * reassembled in the shader: ES 3 has no filterable 16-bit integer format
     * that every ARCore device supports, and RG8 is exactly two bytes.
     */
    fun updateDepth(frame: Frame, depthEnabled: Boolean) {
        // Every frame, not only when the display geometry changes: that flag is
        // set on the very first frames, which arrive before tracking does and
        // so before this is ever called. Three points; it costs nothing.
        frame.transformCoordinates2d(
            Coordinates2d.VIEW_NORMALIZED,
            uvIn,
            Coordinates2d.TEXTURE_NORMALIZED,
            uvTransform,
        )
        if (!depthEnabled) return
        try {
            frame.acquireDepthImage16Bits().use { image ->
                val plane = image.planes[0]
                val buffer = plane.buffer.order(ByteOrder.nativeOrder())
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, depthTexture)
                GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 2)
                GLES20.glPixelStorei(GLES30.GL_UNPACK_ROW_LENGTH, plane.rowStride / plane.pixelStride)
                GLES20.glTexImage2D(
                    GLES20.GL_TEXTURE_2D, 0, GLES30.GL_RG8, image.width, image.height, 0,
                    GLES30.GL_RG, GLES20.GL_UNSIGNED_BYTE, buffer,
                )
                GLES20.glPixelStorei(GLES30.GL_UNPACK_ROW_LENGTH, 0)
                GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 4)
                depthAvailableAt = System.nanoTime()
            }
        } catch (_: Exception) {
            // NotYetAvailable for the first second or so; a dropped frame later.
        }
    }

    /**
     * Draws the scene. [placement] is `[a, b, c, d, tx, tn]`: the 2x2 rotation
     * from true east-north into the session's east-north, and where the plot's
     * origin sits in it. [floorY] is the ground's height in ARCore's world.
     */
    fun draw(
        view: FloatArray,
        projection: FloatArray,
        placement: FloatArray?,
        floorY: Float,
        cameraX: Float,
        cameraZ: Float,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        val s = scene ?: return
        if (placement == null || placement.size < 6 || program == 0) return

        val a = placement[0]
        val b = placement[1]
        val c = placement[2]
        val d = placement[3]
        val tx = placement[4]
        val tn = placement[5]
        // Column-major. Input is (east, north, up, 1) in the plot frame; output
        // is ARCore's world, where x is session east, -z session north, y up.
        model[0] = a; model[1] = 0f; model[2] = -c; model[3] = 0f
        model[4] = b; model[5] = 0f; model[6] = -d; model[7] = 0f
        model[8] = 0f; model[9] = 1f; model[10] = 0f; model[11] = 0f
        model[12] = tx; model[13] = floorY; model[14] = -tn; model[15] = 1f
        Matrix.multiplyMM(modelView, 0, view, 0, model, 0)
        Matrix.multiplyMM(mvp, 0, projection, 0, modelView, 0)

        GLES20.glUseProgram(program)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDisable(GLES20.GL_CULL_FACE)
        GLES20.glDepthMask(false)
        GLES20.glEnable(GLES20.GL_BLEND)
        // Destination alpha is left alone: the surface stays opaque under Flutter.
        GLES20.glBlendFuncSeparate(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA, GLES20.GL_ZERO, GLES20.GL_ONE)

        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0)
        GLES20.glUniformMatrix4fv(uModelView, 1, false, modelView, 0)
        GLES20.glUniform2f(uViewport, viewportWidth.toFloat(), viewportHeight.toFloat())
        GLES20.glUniform2f(uUvOrigin, uvTransform[0], uvTransform[1])
        GLES20.glUniform2f(uUvX, uvTransform[2] - uvTransform[0], uvTransform[3] - uvTransform[1])
        GLES20.glUniform2f(uUvY, uvTransform[4] - uvTransform[0], uvTransform[5] - uvTransform[1])
        GLES20.glUniform1i(uUseDepth, if (depthActive) 1 else 0)
        GLES20.glUniform1f(uGhost, GHOST_ALPHA)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, depthTexture)
        GLES20.glUniform1i(uDepth, 0)

        val tintR = ((s.tint shr 16) and 0xFF) / 255f
        val tintG = ((s.tint shr 8) and 0xFF) / 255f
        val tintB = (s.tint and 0xFF) / 255f

        // Ground first - cells, then the plot fill and its outline - because
        // everything else stands on it.
        if (cellCount > 0) {
            fade(0f, CELL_FADE_START_M, CELL_FADE_FLOOR)
            GLES20.glUniform1f(uAlpha, s.alpha)
            drawArrays(cellPositions!!, cellColors, GLES20.GL_TRIANGLES, 0, cellCount)
        }
        noFade()
        if (fillCount > 0) {
            color(tintR, tintG, tintB, s.fillAlpha * s.alpha)
            drawArrays(fillVerts!!, null, GLES20.GL_TRIANGLES, 0, fillCount)
        }
        if (outlineCount > 1) {
            lineWidth(4f)
            color(tintR, tintG, tintB, 0.9f * s.alpha)
            drawArrays(outlineVerts!!, null, GLES20.GL_LINE_LOOP, 0, outlineCount)
        }

        if (edgeCount > 0) {
            // Walls farthest first: translucent panels composited in ring order
            // let the far side paint over the near one, which reads as a fold.
            sortEdges(cameraX, cameraZ)
            fade(WALL_FADE_END_M, WALL_FADE_START_M, 0f)
            color(tintR, tintG, tintB, s.wallAlpha * s.alpha)
            for (i in edgeOrder) drawArrays(wallVerts!!, null, GLES20.GL_TRIANGLES, i * 6, 6)

            // Rails and posts last, over every panel, each on a dark backing so
            // they read against bright sky and pale soil alike.
            fade(WALL_FADE_END_M, WALL_FADE_START_M, MIN_RAIL_OPACITY)
            lineWidth(11f)
            color(0.04f, 0.06f, 0.08f, 0.5f * s.alpha)
            drawArrays(railVerts!!, null, GLES20.GL_LINES, 0, edgeCount * 2)
            drawArrays(postVerts!!, null, GLES20.GL_LINES, 0, edgeCount * 2)
            lineWidth(7f)
            color(tintR, tintG, tintB, s.railAlpha * s.alpha)
            drawArrays(railVerts!!, null, GLES20.GL_LINES, 0, edgeCount * 2)
            drawArrays(postVerts!!, null, GLES20.GL_LINES, 0, edgeCount * 2)
        }

        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDepthMask(true)
    }

    private fun sortEdges(cameraX: Float, cameraZ: Float) {
        edgeOrder.clear()
        for (i in 0 until edgeCount) edgeOrder.add(i)
        val distances = FloatArray(edgeCount) { i ->
            val e = edgeMid[i * 2]
            val n = edgeMid[i * 2 + 1]
            val wx = model[0] * e + model[4] * n + model[12]
            val wz = model[2] * e + model[6] * n + model[14]
            hypot(wx - cameraX, wz - cameraZ)
        }
        edgeOrder.sortByDescending { distances[it] }
    }

    private fun fade(end: Float, start: Float, floor: Float) {
        GLES20.glUniform1f(uFadeEnd, end)
        GLES20.glUniform1f(uFadeStart, max(start, end + 0.01f))
        GLES20.glUniform1f(uFadeFloor, floor)
    }

    private fun noFade() = fade(-2f, -1f, 1f)

    private fun color(r: Float, g: Float, b: Float, a: Float) {
        GLES20.glUniform1f(uAlpha, 1f)
        GLES20.glVertexAttrib4f(aColor, r, g, b, min(1f, max(0f, a)))
    }

    private fun lineWidth(physicalPx: Float) = GLES20.glLineWidth(min(physicalPx, lineWidthMax))

    private fun drawArrays(positions: FloatBuffer, colors: FloatBuffer?, mode: Int, first: Int, count: Int) {
        positions.position(0)
        GLES20.glVertexAttribPointer(aPosition, 3, GLES20.GL_FLOAT, false, 0, positions)
        GLES20.glEnableVertexAttribArray(aPosition)
        if (colors != null) {
            colors.position(0)
            GLES20.glVertexAttribPointer(aColor, 4, GLES20.GL_FLOAT, false, 0, colors)
            GLES20.glEnableVertexAttribArray(aColor)
        } else {
            GLES20.glDisableVertexAttribArray(aColor)
        }
        GLES20.glDrawArrays(mode, first, count)
        GLES20.glDisableVertexAttribArray(aPosition)
        if (colors != null) GLES20.glDisableVertexAttribArray(aColor)
    }

    private fun build(s: OverlayScene) {
        // Ground surfaces sit a hair above the floor so they never fight the
        // measured floor in the depth test.
        fillCount = s.fill.size / 2
        fillVerts = buffer(FloatArray(fillCount * 3).also { out ->
            for (i in 0 until fillCount) {
                out[i * 3] = s.fill[i * 2]; out[i * 3 + 1] = s.fill[i * 2 + 1]; out[i * 3 + 2] = 0.02f
            }
        })

        val n = s.ring.size / 2
        outlineCount = n
        outlineVerts = buffer(FloatArray(n * 3).also { out ->
            for (i in 0 until n) {
                out[i * 3] = s.ring[i * 2]; out[i * 3 + 1] = s.ring[i * 2 + 1]; out[i * 3 + 2] = 0.03f
            }
        })

        edgeCount = if (n >= 2) n else 0
        val walls = FloatArray(edgeCount * 6 * 3)
        val rails = FloatArray(edgeCount * 2 * 3)
        val posts = FloatArray(edgeCount * 2 * 3)
        edgeMid = FloatArray(edgeCount * 2)
        val h = s.wallHeight
        for (i in 0 until edgeCount) {
            val ae = s.ring[i * 2]
            val an = s.ring[i * 2 + 1]
            val be = s.ring[((i + 1) % n) * 2]
            val bn = s.ring[((i + 1) % n) * 2 + 1]
            val quad = floatArrayOf(
                ae, an, 0f, be, bn, 0f, be, bn, h,
                ae, an, 0f, be, bn, h, ae, an, h,
            )
            System.arraycopy(quad, 0, walls, i * 18, 18)
            System.arraycopy(floatArrayOf(ae, an, h, be, bn, h), 0, rails, i * 6, 6)
            System.arraycopy(floatArrayOf(ae, an, 0f, ae, an, s.postHeight), 0, posts, i * 6, 6)
            edgeMid[i * 2] = (ae + be) / 2f
            edgeMid[i * 2 + 1] = (an + bn) / 2f
        }
        wallVerts = buffer(walls)
        railVerts = buffer(rails)
        postVerts = buffer(posts)

        cellCount = s.cells.size / 6
        val positions = FloatArray(cellCount * 3)
        val colors = FloatArray(cellCount * 4)
        for (i in 0 until cellCount) {
            positions[i * 3] = s.cells[i * 6]
            positions[i * 3 + 1] = s.cells[i * 6 + 1]
            positions[i * 3 + 2] = 0.01f
            System.arraycopy(s.cells, i * 6 + 2, colors, i * 4, 4)
        }
        cellPositions = buffer(positions)
        cellColors = buffer(colors)
    }

    private fun compile(type: Int, source: String): Int = GLES20.glCreateShader(type).also {
        GLES20.glShaderSource(it, source)
        GLES20.glCompileShader(it)
    }

    private companion object {
        /** Opacity left on an overlay fragment that something real stands in front of. */
        const val GHOST_ALPHA = 0.22f

        const val WALL_FADE_START_M = 8f
        const val WALL_FADE_END_M = 1.5f
        const val MIN_RAIL_OPACITY = 0.75f
        const val CELL_FADE_START_M = 6f
        const val CELL_FADE_FLOOR = 0.62f

        fun buffer(values: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(max(4, values.size * 4)).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(values)
                rewind()
            }

        val VERTEX = """
            uniform mat4 u_Mvp;
            uniform mat4 u_ModelView;
            attribute vec3 a_Position;
            attribute vec4 a_Color;
            varying vec4 v_Color;
            varying float v_ViewDepth;
            varying float v_Distance;
            void main() {
                // The plot frame is (east, north, up); the model matrix takes
                // it to ARCore's world.
                vec4 local = vec4(a_Position.x, a_Position.y, a_Position.z, 1.0);
                vec4 eye = u_ModelView * local;
                v_ViewDepth = -eye.z;
                v_Distance = length(eye.xyz);
                v_Color = a_Color;
                gl_Position = u_Mvp * local;
            }
        """.trimIndent()

        val FRAGMENT = """
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
            uniform sampler2D u_Depth;
            uniform int u_UseDepth;
            uniform vec2 u_Viewport;
            uniform vec2 u_UvOrigin;
            uniform vec2 u_UvX;
            uniform vec2 u_UvY;
            uniform float u_FadeStart;
            uniform float u_FadeEnd;
            uniform float u_FadeFloor;
            uniform float u_Alpha;
            uniform float u_Ghost;
            varying vec4 v_Color;
            varying float v_ViewDepth;
            varying float v_Distance;
            void main() {
                float t = clamp((v_Distance - u_FadeEnd) / (u_FadeStart - u_FadeEnd), 0.0, 1.0);
                float fade = u_FadeFloor + (1.0 - u_FadeFloor) * t;
                float visible = 1.0;
                if (u_UseDepth == 1) {
                    vec2 view = vec2(gl_FragCoord.x / u_Viewport.x, 1.0 - gl_FragCoord.y / u_Viewport.y);
                    vec2 uv = u_UvOrigin + u_UvX * view.x + u_UvY * view.y;
                    vec2 bytes = texture2D(u_Depth, uv).rg;
                    float real = (bytes.r * 255.0 + bytes.g * 255.0 * 256.0) / 1000.0;
                    if (real > 0.0) {
                        // Depth is noisier with range, so the tolerance grows
                        // with it: the ground fill lying on a measured floor
                        // must not flicker in and out.
                        float tolerance = 0.25 + 0.08 * v_ViewDepth;
                        float hidden = clamp((v_ViewDepth - real - tolerance) / (0.5 * tolerance), 0.0, 1.0);
                        visible = mix(1.0, u_Ghost, hidden);
                    }
                }
                gl_FragColor = vec4(v_Color.rgb, v_Color.a * fade * visible * u_Alpha);
            }
        """.trimIndent()
    }
}
