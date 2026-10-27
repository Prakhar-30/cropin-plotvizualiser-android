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

/** One plot of the scene: ground fill, boundary ring, colour. */
internal class ScenePlot(
    /** Ground fill, already triangulated: (east, north) per vertex. */
    val fill: FloatArray,
    /** The boundary, open ring: (east, north) per vertex. */
    val ring: FloatArray,
    /** Plot colour, 0xAARRGGBB. */
    val tint: Int,
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
    val wallHeight: Float,
    val postHeight: Float,
    val dropHeight: Float,
    /** Overall opacity from heading confidence. */
    val alpha: Float,
    val wallAlpha: Float,
    val fillAlpha: Float,
    val railAlpha: Float,
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
                ScenePlot(
                    fill = floats(plot["fill"]),
                    ring = floats(plot["ring"]),
                    tint = (plot["tint"] as? Number)?.toLong()?.toInt() ?: 0xFFFF3B30.toInt(),
                )
            }
            return OverlayScene(
                plots = plots,
                cells = floats(map["cells"]),
                drops = floats(map["drops"]),
                wallHeight = number("wallHeight", 2.6f),
                postHeight = number("postHeight", 2.5f),
                dropHeight = number("dropHeight", 4.5f),
                alpha = number("alpha", 1f),
                wallAlpha = number("wallAlpha", 0.28f),
                fillAlpha = number("fillAlpha", 0.18f),
                railAlpha = number("railAlpha", 1f),
            )
        }
    }
}

/** GL buffers for one plot. */
private class PlotBuffers(
    val tintR: Float,
    val tintG: Float,
    val tintB: Float,
    val fill: FloatBuffer,
    val fillCount: Int,
    val outline: FloatBuffer,
    val outlineCount: Int,
    val walls: FloatBuffer,
    val rails: FloatBuffer,
    val posts: FloatBuffer,
    val edgeCount: Int,
    /** (east, north) of each edge's midpoint, for far-to-near sorting. */
    val edgeMid: FloatArray,
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
    private var dropStems: FloatBuffer? = null
    private var dropHeads: FloatBuffer? = null
    private var dropColors: FloatBuffer? = null
    private var stemColors: FloatBuffer? = null
    private var dropCount = 0

    private val model = FloatArray(16)
    private val modelView = FloatArray(16)
    private val mvp = FloatArray(16)

    /** (plot index, edge index, distance) for every wall, re-sorted each frame. */
    private val wallOrder = ArrayList<Triple<Int, Int, Float>>()

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
            dropCount = 0
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
        GLES20.glUniform1f(uPointSize, 1f)
        GLES20.glUniform1i(uRound, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, depthTexture)
        GLES20.glUniform1i(uDepth, 0)

        // Ground first - every plot's fill, the graded cells on it, then the
        // outlines - because everything else stands on it.
        GLES20.glUniform1f(uGhost, SURFACE_GHOST)
        noFade()
        for (p in plots) {
            if (p.fillCount > 0) {
                color(p.tintR, p.tintG, p.tintB, s.fillAlpha * s.alpha)
                drawArrays(p.fill, null, GLES20.GL_TRIANGLES, 0, p.fillCount)
            }
        }
        if (cellVertexCount > 0) {
            GLES20.glUniform1f(uAlpha, s.alpha)
            drawArrays(cellPositions!!, cellColors, GLES20.GL_TRIANGLES, 0, cellVertexCount)
        }
        for (p in plots) {
            if (p.outlineCount > 1) {
                lineWidth(4f)
                color(p.tintR, p.tintG, p.tintB, 0.9f * s.alpha)
                drawArrays(p.outline, null, GLES20.GL_LINE_LOOP, 0, p.outlineCount)
            }
        }

        // Walls of every plot together, farthest first: translucent panels
        // composited in any other order let a far wall paint over a near one,
        // which reads as a fold - and with several plots, as plots overlapping.
        sortWalls(cameraX, cameraZ)
        fade(WALL_FADE_END_M, WALL_FADE_START_M, WALL_FADE_FLOOR)
        for ((plotIndex, edge, _) in wallOrder) {
            val p = plots[plotIndex]
            color(p.tintR, p.tintG, p.tintB, s.wallAlpha * s.alpha)
            drawArrays(p.walls, null, GLES20.GL_TRIANGLES, edge * 6, 6)
        }

        // Rails and posts over every panel, each on a dark backing so they read
        // against bright sky and pale soil alike.
        fade(WALL_FADE_END_M, WALL_FADE_START_M, MIN_RAIL_OPACITY)
        GLES20.glUniform1f(uGhost, LINE_GHOST)
        for (p in plots) {
            if (p.edgeCount == 0) continue
            lineWidth(11f)
            color(0.04f, 0.06f, 0.08f, 0.5f * s.alpha)
            drawArrays(p.rails, null, GLES20.GL_LINES, 0, p.edgeCount * 2)
            drawArrays(p.posts, null, GLES20.GL_LINES, 0, p.edgeCount * 2)
            lineWidth(7f)
            color(p.tintR, p.tintG, p.tintB, s.railAlpha * s.alpha)
            drawArrays(p.rails, null, GLES20.GL_LINES, 0, p.edgeCount * 2)
            drawArrays(p.posts, null, GLES20.GL_LINES, 0, p.edgeCount * 2)
        }

        // Drop points last, over everything: a stem from the ground to above
        // the walls, and a round head on top. A drop point is a walk-to target,
        // and a target hidden behind the fence between you and it is none.
        if (dropCount > 0) {
            noFade()
            GLES20.glUniform1f(uGhost, LINE_GHOST)
            lineWidth(10f)
            color(0.04f, 0.06f, 0.08f, 0.55f * s.alpha)
            drawArrays(dropStems!!, null, GLES20.GL_LINES, 0, dropCount * 2)
            lineWidth(6f)
            GLES20.glUniform1f(uAlpha, s.alpha)
            drawArrays(dropStems!!, stemColors, GLES20.GL_LINES, 0, dropCount * 2)

            GLES20.glUniform1i(uRound, 1)
            GLES20.glUniform1f(uPointSize, min(HEAD_SIZE_PX + 10f, pointSizeMax))
            color(0.04f, 0.06f, 0.08f, 0.7f * s.alpha)
            drawArrays(dropHeads!!, null, GLES20.GL_POINTS, 0, dropCount)
            GLES20.glUniform1f(uPointSize, min(HEAD_SIZE_PX, pointSizeMax))
            GLES20.glUniform1f(uAlpha, s.alpha)
            drawArrays(dropHeads!!, dropColors, GLES20.GL_POINTS, 0, dropCount)
            GLES20.glUniform1i(uRound, 0)
        }

        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDepthMask(true)
    }

    private fun sortWalls(cameraX: Float, cameraZ: Float) {
        wallOrder.clear()
        for ((plotIndex, p) in plots.withIndex()) {
            for (edge in 0 until p.edgeCount) {
                val e = p.edgeMid[edge * 2]
                val n = p.edgeMid[edge * 2 + 1]
                val wx = model[0] * e + model[4] * n + model[12]
                val wz = model[2] * e + model[6] * n + model[14]
                wallOrder.add(Triple(plotIndex, edge, hypot(wx - cameraX, wz - cameraZ)))
            }
        }
        wallOrder.sortByDescending { it.third }
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
        plots = s.plots.map { buildPlot(it, s) }

        // Graded cells lie just above the plot fill, so the two never fight.
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

        // Drop points: a stem as a line from the ground to the top, a head as
        // one point at the top. Both coloured by the point's zone.
        dropCount = s.drops.size / 5
        val stems = FloatArray(dropCount * 6)
        val heads = FloatArray(dropCount * 3)
        val headColors = FloatArray(dropCount * 4)
        val stemColorArray = FloatArray(dropCount * 8)
        for (i in 0 until dropCount) {
            val e = s.drops[i * 5]
            val n = s.drops[i * 5 + 1]
            val r = s.drops[i * 5 + 2]
            val g = s.drops[i * 5 + 3]
            val b = s.drops[i * 5 + 4]
            System.arraycopy(floatArrayOf(e, n, 0f, e, n, s.dropHeight), 0, stems, i * 6, 6)
            System.arraycopy(floatArrayOf(e, n, s.dropHeight), 0, heads, i * 3, 3)
            System.arraycopy(floatArrayOf(r, g, b, 1f), 0, headColors, i * 4, 4)
            System.arraycopy(floatArrayOf(r, g, b, 0.95f, r, g, b, 0.95f), 0, stemColorArray, i * 8, 8)
        }
        dropStems = buffer(stems)
        dropHeads = buffer(heads)
        dropColors = buffer(headColors)
        stemColors = buffer(stemColorArray)
    }

    private fun buildPlot(p: ScenePlot, s: OverlayScene): PlotBuffers {
        // Ground surfaces sit a hair above the floor so they never fight the
        // measured floor in the depth test.
        val fillCount = p.fill.size / 2
        val fill = FloatArray(fillCount * 3)
        for (i in 0 until fillCount) {
            fill[i * 3] = p.fill[i * 2]; fill[i * 3 + 1] = p.fill[i * 2 + 1]; fill[i * 3 + 2] = 0.02f
        }
        val n = p.ring.size / 2
        val outline = FloatArray(n * 3)
        for (i in 0 until n) {
            outline[i * 3] = p.ring[i * 2]; outline[i * 3 + 1] = p.ring[i * 2 + 1]; outline[i * 3 + 2] = 0.03f
        }

        val edgeCount = if (n >= 2) n else 0
        val walls = FloatArray(edgeCount * 18)
        val rails = FloatArray(edgeCount * 6)
        val posts = FloatArray(edgeCount * 6)
        val edgeMid = FloatArray(edgeCount * 2)
        val h = s.wallHeight
        for (i in 0 until edgeCount) {
            val ae = p.ring[i * 2]
            val an = p.ring[i * 2 + 1]
            val be = p.ring[((i + 1) % n) * 2]
            val bn = p.ring[((i + 1) % n) * 2 + 1]
            System.arraycopy(
                floatArrayOf(ae, an, 0f, be, bn, 0f, be, bn, h, ae, an, 0f, be, bn, h, ae, an, h),
                0, walls, i * 18, 18,
            )
            System.arraycopy(floatArrayOf(ae, an, h, be, bn, h), 0, rails, i * 6, 6)
            System.arraycopy(floatArrayOf(ae, an, 0f, ae, an, s.postHeight), 0, posts, i * 6, 6)
            edgeMid[i * 2] = (ae + be) / 2f
            edgeMid[i * 2 + 1] = (an + bn) / 2f
        }
        return PlotBuffers(
            tintR = ((p.tint shr 16) and 0xFF) / 255f,
            tintG = ((p.tint shr 8) and 0xFF) / 255f,
            tintB = (p.tint and 0xFF) / 255f,
            fill = buffer(fill),
            fillCount = fillCount,
            outline = buffer(outline),
            outlineCount = n,
            walls = buffer(walls),
            rails = buffer(rails),
            posts = buffer(posts),
            edgeCount = edgeCount,
            edgeMid = edgeMid,
        )
    }

    private fun compile(type: Int, source: String): Int = GLES20.glCreateShader(type).also {
        GLES20.glShaderSource(it, source)
        GLES20.glCompileShader(it)
    }

    private companion object {
        /**
         * Opacity left on overlay that something real stands in front of. Lines
         * keep more than surfaces: the rail and the drop points are how things
         * are found, and must stay findable through a crop row or a passer-by.
         */
        const val SURFACE_GHOST = 0.35f
        const val LINE_GHOST = 0.6f

        /** Walls never fade below this, so a boundary 3 m away is still a wall. */
        const val WALL_FADE_FLOOR = 0.3f

        const val WALL_FADE_START_M = 8f
        const val WALL_FADE_END_M = 1.5f
        const val MIN_RAIL_OPACITY = 0.75f

        /** A drop point's head at 10 m; it shrinks with distance in the shader. */
        const val HEAD_SIZE_PX = 44f

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
