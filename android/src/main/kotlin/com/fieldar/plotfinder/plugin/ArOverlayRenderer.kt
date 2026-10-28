package com.fieldar.plotfinder.plugin

import android.opengl.GLES20
import android.opengl.GLES30
import android.opengl.Matrix
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min

/** One plot of the scene: its boundary, flat on the ground, and its colour. */
internal class ScenePlot(
    /** The boundary, open ring: (east, north) per vertex. The ribbon's outer edge. */
    val ring: FloatArray,
    /** The boundary pulled inwards, vertex for vertex: the ribbon's inner edge. */
    val inner: FloatArray,
    /** Plot colour, 0xAARRGGBB. */
    val tint: Int,
    /** The plot the agent is in or nearest to: its line is drawn bolder. */
    val primary: Boolean,
)

/**
 * Every nearby plot, its moderate and critical ground cells and every drop
 * point, as Dart describes them, in one local metric frame: east, north and up
 * in metres from a fixed origin, true north up.
 *
 * Built when the nearby plots, the crop-condition index or the snapshots
 * change - never per frame. What moves per frame is only the camera, which
 * ARCore supplies.
 */
internal class OverlayScene(
    val plots: List<ScenePlot>,
    /** Moderate and critical ground cells, triangles: (east, north, r, g, b, a) per vertex. */
    val cells: FloatArray,
    /** Drop points: (east, north, r, g, b) per point. */
    val drops: FloatArray,
    val dropHeight: Float,
    /** Far plots, one marker each: (east, north, r, g, b), the plot's colour. */
    val markers: FloatArray,
    val markerHeight: Float,
    /** Overall opacity from heading confidence. */
    val alpha: Float,
    val ribbonAlpha: Float,
    val lineAlpha: Float,
) {
    companion object {
        private fun floats(v: Any?): FloatArray = when (v) {
            is FloatArray -> v
            is DoubleArray -> FloatArray(v.size) { v[it].toFloat() }
            is List<*> -> FloatArray(v.size) { (v[it] as Number).toFloat() }
            else -> FloatArray(0)
        }

        fun from(arguments: Any?): OverlayScene? {
            val map = arguments as? Map<*, *> ?: return null
            fun number(key: String, default: Float): Float = (map[key] as? Number)?.toFloat() ?: default
            val plots = (map["plots"] as? List<*>).orEmpty().mapNotNull { entry ->
                val plot = entry as? Map<*, *> ?: return@mapNotNull null
                val ring = floats(plot["ring"])
                ScenePlot(
                    ring = ring,
                    inner = floats(plot["inner"]).takeIf { it.size == ring.size } ?: ring,
                    tint = (plot["tint"] as? Number)?.toLong()?.toInt() ?: 0xFF0A84FF.toInt(),
                    primary = plot["primary"] as? Boolean ?: true,
                )
            }
            return OverlayScene(
                plots = plots,
                cells = floats(map["cells"]),
                drops = floats(map["drops"]),
                dropHeight = number("dropHeight", 4.5f),
                markers = floats(map["markers"]),
                markerHeight = number("markerHeight", 6f),
                alpha = number("alpha", 1f),
                ribbonAlpha = number("ribbonAlpha", 0.55f),
                lineAlpha = number("lineAlpha", 0.95f),
            )
        }
    }
}

/** GL buffers for one plot. */
private class PlotBuffers(
    val tintR: Float,
    val tintG: Float,
    val tintB: Float,
    val primary: Boolean,
    /** The ribbon, two triangles per edge. */
    val ribbon: FloatBuffer,
    val ribbonCount: Int,
    /** The line down the middle of the ribbon, as a loop. */
    val line: FloatBuffer,
    val lineCount: Int,
)

/** Upright pins - drop points, or far plots' markers - ready to draw. */
private class Pins(
    val stems: FloatBuffer,
    val heads: FloatBuffer,
    val headColors: FloatBuffer,
    val stemColors: FloatBuffer,
    val count: Int,
)

/**
 * Draws the plots and the drop points in the same GL frame as ARCore's camera
 * image.
 *
 * Drawn on the Flutter canvas, the overlay always lagged the picture under it
 * by the trip through the event channel and the next Flutter frame, so the
 * boundary trailed every turn of the hand. Here it is projected with the view
 * and projection matrices of the very frame the camera image came from.
 *
 * Where ARCore's Depth API is available, each fragment is compared with the
 * measured depth of the scene at that pixel; something clearly nearer - a
 * person, a tree, a wall - hides it, not completely but down to a ghost, so a
 * boundary is never lost behind the crop it encloses ("X-ray" rendering).
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
    private var uPointSize = 0
    private var uRound = 0
    private var uZoom = 0

    private var lineWidthMax = 1f
    private var pointSizeMax = 1f

    private var depthTexture = 0
    private var depthAvailableAt = 0L
    private val uvTransform = FloatArray(6)
    private val uvIn = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f)

    private var scene: OverlayScene? = null
    private var plots: List<PlotBuffers> = emptyList()
    private var cellPositions: FloatBuffer? = null
    private var cellColors: FloatBuffer? = null
    private var cellVertexCount = 0
    private var drops: Pins? = null
    private var markers: Pins? = null

    private val model = FloatArray(16)
    private val modelView = FloatArray(16)
    private val mvp = FloatArray(16)


    fun create() {
        program = GLES20.glCreateProgram().also { p ->
            GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, VERTEX))
            GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT))
            // Position on attribute 0: some drivers draw nothing when attribute
            // 0 is a disabled array, and colour is often a constant here.
            GLES20.glBindAttribLocation(p, 0, "a_Position")
            GLES20.glBindAttribLocation(p, 1, "a_Color")
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
        uPointSize = GLES20.glGetUniformLocation(program, "u_PointSize")
        uRound = GLES20.glGetUniformLocation(program, "u_Round")
        uZoom = GLES20.glGetUniformLocation(program, "u_Zoom")

        val range = FloatArray(2)
        GLES20.glGetFloatv(GLES20.GL_ALIASED_LINE_WIDTH_RANGE, range, 0)
        lineWidthMax = max(1f, range[1])
        GLES20.glGetFloatv(GLES20.GL_ALIASED_POINT_SIZE_RANGE, range, 0)
        pointSizeMax = max(1f, range[1])

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
            plots = emptyList()
            cellVertexCount = 0
            drops = null
            markers = null
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
     * from true east-north into the session's east-north, and where the scene's
     * origin sits in it. [floorY] is the ground's height in ARCore's world.
     */
    fun draw(
        view: FloatArray,
        projection: FloatArray,
        placement: FloatArray?,
        floorY: Float,
        viewportWidth: Int,
        viewportHeight: Int,
        zoom: Float = 1f,
    ) {
        val s = scene ?: return
        if (placement == null || placement.size < 6 || program == 0) return

        val a = placement[0]
        val b = placement[1]
        val c = placement[2]
        val d = placement[3]
        // Column-major. Input is (east, north, up, 1) in the scene frame; output
        // is ARCore's world, where x is session east, -z session north, y up.
        model[0] = a; model[1] = 0f; model[2] = -c; model[3] = 0f
        model[4] = b; model[5] = 0f; model[6] = -d; model[7] = 0f
        model[8] = 0f; model[9] = 1f; model[10] = 0f; model[11] = 0f
        model[12] = placement[4]; model[13] = floorY; model[14] = -placement[5]; model[15] = 1f
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
        GLES20.glUniform1f(uZoom, zoom)
        GLES20.glUniform1f(uPointSize, 1f)
        GLES20.glUniform1i(uRound, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, depthTexture)
        GLES20.glUniform1i(uDepth, 0)

        // Ground first - the graded cells, then every plot's boundary line over
        // them - because everything else stands on it. No tinted plot floor: the
        // only colour on the ground is crop condition.
        GLES20.glUniform1f(uGhost, SURFACE_GHOST)
        noFade()
        if (cellVertexCount > 0) {
            GLES20.glUniform1f(uAlpha, s.alpha)
            drawArrays(cellPositions!!, cellColors, GLES20.GL_TRIANGLES, 0, cellVertexCount)
        }
        // Each plot's boundary: the ribbon from the boundary into the plot, then
        // the line down its middle on a dark backing so it reads against bright
        // sky and pale soil alike. Ribbons lie inside their own plot only, so
        // neighbours never cover one another.
        for (p in plots) {
            if (p.ribbonCount == 0) continue
            color(p.tintR, p.tintG, p.tintB, s.ribbonAlpha * s.alpha)
            drawArrays(p.ribbon, null, GLES20.GL_TRIANGLES, 0, p.ribbonCount)
        }
        GLES20.glUniform1f(uGhost, LINE_GHOST)
        for (p in plots) {
            if (p.lineCount < 2) continue
            lineWidth(if (p.primary) 11f else 9f)
            color(0.04f, 0.06f, 0.08f, 0.5f * s.alpha)
            drawArrays(p.line, null, GLES20.GL_LINE_LOOP, 0, p.lineCount)
            lineWidth(if (p.primary) 7f else 5f)
            color(p.tintR, p.tintG, p.tintB, s.lineAlpha * s.alpha)
            drawArrays(p.line, null, GLES20.GL_LINE_LOOP, 0, p.lineCount)
        }

        // Far plots' markers, then the drop points over everything: a stem from
        // the ground and a round head on top. A drop point is a walk-to target,
        // the thing to find; a marker stands in for a plot too far off to draw.
        noFade()
        GLES20.glUniform1f(uGhost, LINE_GHOST)
        markers?.let { drawPins(it, s.alpha, stemPx = 8f, headPx = MARKER_HEAD_SIZE_PX) }
        drops?.let { drawPins(it, s.alpha, stemPx = 6f, headPx = HEAD_SIZE_PX) }

        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDepthMask(true)
    }

    private fun drawPins(pins: Pins, alpha: Float, stemPx: Float, headPx: Float) {
        if (pins.count == 0) return
        lineWidth(stemPx + 4f)
        color(0.04f, 0.06f, 0.08f, 0.55f * alpha)
        drawArrays(pins.stems, null, GLES20.GL_LINES, 0, pins.count * 2)
        lineWidth(stemPx)
        GLES20.glUniform1f(uAlpha, alpha)
        drawArrays(pins.stems, pins.stemColors, GLES20.GL_LINES, 0, pins.count * 2)

        GLES20.glUniform1i(uRound, 1)
        GLES20.glUniform1f(uPointSize, min(headPx + 10f, pointSizeMax))
        color(0.04f, 0.06f, 0.08f, 0.7f * alpha)
        drawArrays(pins.heads, null, GLES20.GL_POINTS, 0, pins.count)
        GLES20.glUniform1f(uPointSize, min(headPx, pointSizeMax))
        GLES20.glUniform1f(uAlpha, alpha)
        drawArrays(pins.heads, pins.headColors, GLES20.GL_POINTS, 0, pins.count)
        GLES20.glUniform1i(uRound, 0)
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
        plots = s.plots.map { buildPlot(it) }

        // Graded cells lie just above the floor, under the boundary lines.
        cellVertexCount = s.cells.size / 6
        val cellXyz = FloatArray(cellVertexCount * 3)
        val cellRgba = FloatArray(cellVertexCount * 4)
        for (i in 0 until cellVertexCount) {
            cellXyz[i * 3] = s.cells[i * 6]
            cellXyz[i * 3 + 1] = s.cells[i * 6 + 1]
            cellXyz[i * 3 + 2] = 0.025f
            System.arraycopy(s.cells, i * 6 + 2, cellRgba, i * 4, 4)
        }
        cellPositions = buffer(cellXyz)
        cellColors = buffer(cellRgba)

        drops = buildPins(s.drops, s.dropHeight)
        markers = buildPins(s.markers, s.markerHeight)
    }

    /**
     * Pins from (east, north, r, g, b) per pin: a stem as a line from the ground
     * to [height], a head as one point at the top, both in the pin's colour.
     */
    private fun buildPins(data: FloatArray, height: Float): Pins {
        val count = data.size / 5
        val stems = FloatArray(count * 6)
        val heads = FloatArray(count * 3)
        val headColors = FloatArray(count * 4)
        val stemColors = FloatArray(count * 8)
        for (i in 0 until count) {
            val e = data[i * 5]
            val n = data[i * 5 + 1]
            val r = data[i * 5 + 2]
            val g = data[i * 5 + 3]
            val b = data[i * 5 + 4]
            System.arraycopy(floatArrayOf(e, n, 0f, e, n, height), 0, stems, i * 6, 6)
            System.arraycopy(floatArrayOf(e, n, height), 0, heads, i * 3, 3)
            System.arraycopy(floatArrayOf(r, g, b, 1f), 0, headColors, i * 4, 4)
            System.arraycopy(floatArrayOf(r, g, b, 0.95f, r, g, b, 0.95f), 0, stemColors, i * 8, 8)
        }
        return Pins(buffer(stems), buffer(heads), buffer(headColors), buffer(stemColors), count)
    }

    private fun buildPlot(p: ScenePlot): PlotBuffers {
        // Just above the floor so nothing fights the measured floor in the depth
        // test, and above the graded cells.
        val n = p.ring.size / 2
        val edges = if (n >= 3) n else 0
        val ribbon = FloatArray(edges * 18)
        for (i in 0 until edges) {
            val j = (i + 1) % n
            val ae = p.ring[i * 2]; val an = p.ring[i * 2 + 1]
            val be = p.ring[j * 2]; val bn = p.ring[j * 2 + 1]
            val ce = p.inner[j * 2]; val cn = p.inner[j * 2 + 1]
            val de = p.inner[i * 2]; val dn = p.inner[i * 2 + 1]
            System.arraycopy(
                floatArrayOf(ae, an, RIBBON_Z, be, bn, RIBBON_Z, ce, cn, RIBBON_Z, ae, an, RIBBON_Z, ce, cn, RIBBON_Z, de, dn, RIBBON_Z),
                0, ribbon, i * 18, 18,
            )
        }
        // The middle of the ribbon: halfway between each outer and inner vertex.
        val line = FloatArray(n * 3)
        for (i in 0 until n) {
            line[i * 3] = (p.ring[i * 2] + p.inner[i * 2]) / 2f
            line[i * 3 + 1] = (p.ring[i * 2 + 1] + p.inner[i * 2 + 1]) / 2f
            line[i * 3 + 2] = LINE_Z
        }
        return PlotBuffers(
            tintR = ((p.tint shr 16) and 0xFF) / 255f,
            tintG = ((p.tint shr 8) and 0xFF) / 255f,
            tintB = (p.tint and 0xFF) / 255f,
            primary = p.primary,
            ribbon = buffer(ribbon),
            ribbonCount = edges * 6,
            line = buffer(line),
            lineCount = n,
        )
    }

    private fun compile(type: Int, source: String): Int = GLES20.glCreateShader(type).also {
        GLES20.glShaderSource(it, source)
        GLES20.glCompileShader(it)
    }

    private companion object {
        /**
         * Opacity left on overlay that something real stands in front of. Lines
         * keep more than surfaces: the boundary line and the drop points are how things
         * are found, and must stay findable through a crop row or a passer-by.
         */
        const val SURFACE_GHOST = 0.35f
        const val LINE_GHOST = 0.6f

        /** Heights above the floor: cells at 0.025, then the ribbon, then its line. */
        const val RIBBON_Z = 0.03f
        const val LINE_Z = 0.035f

        /** A drop point's head at 10 m; it shrinks with distance in the shader. */
        const val HEAD_SIZE_PX = 44f

        /** A far plot's marker head, a size up from a drop point's. */
        const val MARKER_HEAD_SIZE_PX = 60f

        fun buffer(values: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(max(4, values.size * 4)).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(values)
                rewind()
            }

        val VERTEX = """
            uniform mat4 u_Mvp;
            uniform mat4 u_ModelView;
            uniform float u_PointSize;
            attribute vec3 a_Position;
            attribute vec4 a_Color;
            varying vec4 v_Color;
            varying float v_ViewDepth;
            varying float v_Distance;
            void main() {
                // The scene frame is (east, north, up); the model matrix takes
                // it to ARCore's world.
                vec4 local = vec4(a_Position.x, a_Position.y, a_Position.z, 1.0);
                vec4 eye = u_ModelView * local;
                v_ViewDepth = -eye.z;
                v_Distance = length(eye.xyz);
                v_Color = a_Color;
                // Points shrink with distance, but not below a third of their
                // size, so a drop point 200 m off is still a dot, not nothing.
                gl_PointSize = u_PointSize * clamp(10.0 / max(v_Distance, 0.1), 0.35, 1.3);
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
            uniform int u_Round;
            uniform vec2 u_Viewport;
            uniform vec2 u_UvOrigin;
            uniform vec2 u_UvX;
            uniform vec2 u_UvY;
            uniform float u_FadeStart;
            uniform float u_FadeEnd;
            uniform float u_FadeFloor;
            uniform float u_Alpha;
            uniform float u_Ghost;
            uniform float u_Zoom;
            varying vec4 v_Color;
            varying float v_ViewDepth;
            varying float v_Distance;
            void main() {
                if (u_Round == 1) {
                    vec2 c = gl_PointCoord - vec2(0.5);
                    if (dot(c, c) > 0.25) discard;
                }
                float t = clamp((v_Distance - u_FadeEnd) / (u_FadeStart - u_FadeEnd), 0.0, 1.0);
                float fade = u_FadeFloor + (1.0 - u_FadeFloor) * t;
                float visible = 1.0;
                if (u_UseDepth == 1) {
                    vec2 view = vec2(gl_FragCoord.x / u_Viewport.x, 1.0 - gl_FragCoord.y / u_Viewport.y);
                    // Zoomed in, a pixel shows a point nearer the centre of the
                    // unzoomed view, which is the frame the depth image maps to.
                    view = vec2(0.5) + (view - vec2(0.5)) / u_Zoom;
                    vec2 uv = u_UvOrigin + u_UvX * view.x + u_UvY * view.y;
                    vec2 bytes = texture2D(u_Depth, uv).rg;
                    float real = (bytes.r * 255.0 + bytes.g * 255.0 * 256.0) / 1000.0;
                    if (real > 0.0) {
                        // Only something clearly in front occludes: nearer than
                        // 80% of the overlay's distance starts to, nearer than
                        // 60% fully does. A person 2 m away hides a boundary at
                        // 16 m; the crop row just inside it, or the floor the
                        // fill lies on, does not.
                        float ratio = real / max(v_ViewDepth, 0.01);
                        float hidden = clamp((0.8 - ratio) / 0.2, 0.0, 1.0);
                        visible = mix(1.0, u_Ghost, hidden);
                    }
                }
                gl_FragColor = vec4(v_Color.rgb, v_Color.a * fade * visible * u_Alpha);
            }
        """.trimIndent()
    }
}
