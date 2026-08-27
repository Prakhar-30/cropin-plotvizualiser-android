package com.fieldar.plotfinder.ui.ar

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.geometry.Offset
import com.fieldar.plotfinder.core.geo.ScreenPoint
import com.fieldar.plotfinder.core.heading.HeadingConfidence
import com.fieldar.plotfinder.core.render.HealthOverlay
import com.fieldar.plotfinder.core.render.OverlayBand
import com.fieldar.plotfinder.core.render.PlotAlpha
import com.fieldar.plotfinder.core.render.PlotOverlay
import com.fieldar.plotfinder.core.render.RenderMode
import com.fieldar.plotfinder.core.render.plotColour
import com.fieldar.plotfinder.core.render.severityColour
import kotlin.math.min

/**
 * Draws a [PlotOverlay] on a 2D canvas composited over the camera preview.
 *
 * This is a projection problem, not a scene graph: every point has already been
 * reduced to screen coordinates by `core.render`, so all that is left is
 * strokes and fills. Pulling in a 3D engine to draw a translucent quadrilateral
 * would be several hundred times the dependency for the same pixels.
 */

private val UNRELIABLE_COLOUR = Color(0xFF9CA3AF)
private val LABEL_BACKGROUND = Color(0xCC0B0F14)

/**
 * Dark backing for strokes that must survive any background.
 *
 * Outdoor camera footage is mostly bright: sky, pale soil, corrugated fencing.
 * A coloured line on its own competes with whatever it crosses; the same line
 * over a dark halo reads against all of it, which is why road signs and map
 * labels have been drawn this way for a century.
 */
private val OUTLINE_BACKING = Color(0xFF0B0F14)

@Composable
fun ArOverlay(
    overlay: PlotOverlay?,
    /** The crop-health raster, already projected. Null when the layer is off. */
    health: HealthOverlay?,
    plotId: String,
    areaHectares: Double,
    /** Palette slot from the plot record, so neighbouring plots never match. */
    colourIndex: Int,
    confidence: HeadingConfidence,
    accuracyM: Double,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier = modifier) {
        drawCrosshair()
        if (overlay == null) return@Canvas

        // Grey and dim when the heading cannot be trusted. The overlay is still
        // drawn rather than hidden, because "roughly there, direction unknown"
        // is useful and a blank screen is not - but it must not look
        // authoritative, and it must not keep the plot's identity colour. That
        // colour says "this is plot 4, not plot 5", which is a claim about which
        // boundary you are looking at, and that claim is only ever as good as
        // the heading it was drawn with.
        val trusted = confidence != HeadingConfidence.UNRELIABLE
        val tint = if (trusted) Color(plotColour(colourIndex).argb) else UNRELIABLE_COLOUR

        // Three tiers, still - but the middle one was punishing the normal case.
        //
        // HOLDING was set to 0.6 on the assumption that a carried heading is an
        // exception. Field testing said otherwise: course-over-ground needs a
        // twenty-metre straight walk to re-lock, and an agent inspecting a small
        // plot walks *around* it, never across. The whole visit ran at HOLDING,
        // sixty to a hundred seconds since the last fix, so 0.6 was not a
        // warning about an unusual state - it was the permanent brightness of
        // the product, multiplied into everything else that fades.
        //
        // The honesty this was protecting is not lost: the heading chip states
        // the source, the age in seconds and the expected error in degrees, all
        // of which are more specific than a dimmer ever was. The dimming now
        // marks the genuinely untrustworthy case and only nudges the carried one.
        val alpha = when (confidence) {
            HeadingConfidence.LOCKED -> 1f
            HeadingConfidence.HOLDING -> 0.85f
            HeadingConfidence.UNRELIABLE -> 0.45f
        }

        // The raster goes down before anything else, because it lies on the
        // ground and everything else stands on it. Drawing it afterwards would
        // paint translucent colour over the walls and rails, which is what turns
        // a legible overlay into a wash.
        health?.let { drawHealthPatches(it, alpha) }

        // Walls next, in both modes: they are the boundary. Everything after
        // this draws on top of them.
        drawWalls(overlay, tint, alpha)

        when (overlay.mode) {
            RenderMode.FAR -> drawFarMode(overlay, tint, alpha)
            RenderMode.NEAR -> drawNearMode(overlay, tint, alpha)
        }

        // Hotspot markers stand above the walls on purpose: the marker is a
        // walk-to target, and a target hidden behind the fence between you and
        // it is no target at all.
        health?.let { drawHotspotMarkers(it, alpha) }

        overlay.offscreenBearingDeg?.let { drawEdgeArrow(it, tint, alpha) }

        overlay.label?.let { label ->
            val text = buildString {
                append(plotId)
                append("  ")
                append(String.format("%.2f ha", areaHectares))
                append("  ")
                append(String.format("%.0f m", label.distanceM))
                if (overlay.mode == RenderMode.NEAR) {
                    append(String.format("  ±%.0f m", accuracyM))
                }
            }
            drawLabel(text, label.at, tint, alpha)
        }
    }
}

/**
 * Fills the graded ground cells.
 *
 * Each cell carries its own opacity from two sources multiplied together: the
 * severity band, so a critical patch is assertive where a healthy one is barely
 * there, and the distance fade, so the cell underfoot does not become a
 * coloured floor. Both live in `core.render`; this function only paints.
 *
 * No outline. A stroke around every cell turns a 500-cell raster into a grid of
 * boxes, and the eye follows the grid instead of the colour - the shape that
 * matters is the *patch*, which is many cells, not any one of them.
 */
private fun DrawScope.drawHealthPatches(health: HealthOverlay, confidenceAlpha: Float) {
    for (patch in health.patches) {
        val path = patch.corners.toPath() ?: continue
        val band = severityColour(patch.severity)
        drawPath(
            path,
            color = Color(band.argb),
            alpha = band.fillAlpha * patch.opacity * confidenceAlpha,
        )
    }
}

/**
 * Stands a stem at each hotspot centroid, ranked.
 *
 * A patch on the ground vanishes behind the crop the moment the agent is
 * standing in the field - waist-high cane hides everything painted at ankle
 * height. The stem is drawn tall for the same reason the boundary posts are:
 * it reads against the sky, so the target stays findable from inside the crop.
 */
private fun DrawScope.drawHotspotMarkers(health: HealthOverlay, confidenceAlpha: Float) {
    for (marker in health.markers) {
        val band = severityColour(marker.severity)
        val colour = Color(band.argb)

        // Dark backing first, then the stem. The markers stand against soil the
        // same colour as the old brown ramp, which is exactly where an
        // unbacked stroke goes missing.
        drawLine(
            color = OUTLINE_BACKING,
            start = Offset(marker.base.x, marker.base.y),
            end = Offset(marker.top.x, marker.top.y),
            strokeWidth = 14f,
            alpha = 0.5f * confidenceAlpha,
        )
        drawLine(
            color = colour,
            start = Offset(marker.base.x, marker.base.y),
            end = Offset(marker.top.x, marker.top.y),
            strokeWidth = 9f,
            alpha = 1.0f * confidenceAlpha,
        )

        // A ring around the disc, for the same reason.
        drawCircle(
            color = OUTLINE_BACKING,
            radius = 23f,
            center = Offset(marker.top.x, marker.top.y),
            alpha = 0.6f * confidenceAlpha,
        )
        drawCircle(
            color = colour,
            radius = 19f,
            center = Offset(marker.top.x, marker.top.y),
            alpha = 1.0f * confidenceAlpha,
        )

        // The rank inside the disc. It is the order to walk them in, and an
        // unnumbered marker leaves the agent to guess which patch is worst.
        val paint = android.graphics.Paint().apply {
            color = android.graphics.Color.WHITE
            textSize = 28f
            isFakeBoldText = true
            isAntiAlias = true
            textAlign = android.graphics.Paint.Align.CENTER
            this.alpha = (255 * confidenceAlpha).toInt()
        }
        drawContext.canvas.nativeCanvas.drawText(
            marker.rank.toString(),
            marker.top.x,
            marker.top.y + 10f,
            paint,
        )
    }
}

/**
 * Draws the standing boundary panels.
 *
 * `overlay.walls` arrives sorted farthest-first, and that order must be
 * preserved: translucent panels drawn near-to-far let the far side of the plot
 * bleed through the near side, which reads as a crease across the field.
 */
private fun DrawScope.drawWalls(overlay: PlotOverlay, tint: Color, alpha: Float) {
    for (wall in overlay.walls) {
        val path = wall.quad.toPath() ?: continue
        drawPath(path, color = tint, alpha = PlotAlpha.WALL_FILL * alpha * wall.opacity)
    }

    // The top rail is stroked after every panel is filled, so it is never
    // overpainted by the panel standing behind it.
    for (rail in overlay.rails) {
        // Drawn twice: a dark backing stroke, then the colour over it. A single
        // coloured line disappears wherever the background happens to share its
        // luminance, and a boundary that vanishes against one particular fence
        // is worse than one that is slightly heavier everywhere.
        drawLine(
            color = OUTLINE_BACKING,
            start = Offset(rail.from.x, rail.from.y),
            end = Offset(rail.to.x, rail.to.y),
            strokeWidth = 11f,
            alpha = 0.5f * alpha * rail.opacity,
        )
        drawLine(
            color = tint,
            start = Offset(rail.from.x, rail.from.y),
            end = Offset(rail.to.x, rail.to.y),
            strokeWidth = 7f,
            alpha = PlotAlpha.RAIL * alpha * rail.opacity,
        )
    }
}

private fun DrawScope.drawFarMode(overlay: PlotOverlay, tint: Color, alpha: Float) {
    val path = overlay.fill.toPath() ?: return

    // Demoted to a hint. The walls carry the boundary; this only says which side
    // of it the crop is on.
    drawPath(path, color = tint, alpha = PlotAlpha.GROUND_FILL * alpha)
    drawPath(path, color = tint, alpha = PlotAlpha.OUTLINE * alpha, style = Stroke(width = 3f))

    // Vertical posts at the corners. Posts read against the horizon and stay
    // legible when heading is a few degrees off, where a flat outline alone
    // becomes hard to match to anything on the ground.
    for (post in overlay.posts) {
        drawLine(
            color = OUTLINE_BACKING,
            start = Offset(post.base.x, post.base.y),
            end = Offset(post.top.x, post.top.y),
            strokeWidth = 12f,
            alpha = 0.5f * alpha,
        )
        drawLine(
            color = tint,
            start = Offset(post.base.x, post.base.y),
            end = Offset(post.top.x, post.top.y),
            strokeWidth = 8f,
            alpha = 1.0f * alpha,
        )
        drawCircle(
            color = tint,
            radius = 10f,
            center = Offset(post.top.x, post.top.y),
            alpha = 1.0f * alpha,
        )
    }
}

private fun DrawScope.drawNearMode(overlay: PlotOverlay, tint: Color, alpha: Float) {
    // No fill inside 30 m: claiming an area implies knowing where its edges are
    // to better than the fix allows.
    for (band in overlay.bands) {
        val path = band.toPath() ?: continue
        drawPath(path, color = tint, alpha = 0.22f * alpha)
        drawPath(path, color = tint, alpha = 0.5f * alpha, style = Stroke(width = 2f))
    }
}

private fun DrawScope.drawEdgeArrow(relativeBearingDeg: Double, tint: Color, alpha: Float) {
    // The plot is out of frame; point at it from the edge of the screen rather
    // than leaving the agent to sweep the horizon.
    val centre = Offset(size.width / 2f, size.height / 2f)
    val radius = min(size.width, size.height) * 0.38f

    rotate(degrees = relativeBearingDeg.toFloat(), pivot = centre) {
        translate(left = centre.x, top = centre.y - radius) {
            val arrow = Path().apply {
                moveTo(0f, -28f)
                lineTo(22f, 18f)
                lineTo(0f, 6f)
                lineTo(-22f, 18f)
                close()
            }
            drawPath(arrow, color = tint, alpha = 0.9f * alpha)
        }
    }
}

private fun DrawScope.drawCrosshair() {
    val centre = Offset(size.width / 2f, size.height / 2f)
    val arm = 22f
    val colour = Color.White.copy(alpha = 0.75f)
    drawLine(colour, Offset(centre.x - arm, centre.y), Offset(centre.x + arm, centre.y), 2f)
    drawLine(colour, Offset(centre.x, centre.y - arm), Offset(centre.x, centre.y + arm), 2f)
    drawCircle(colour, radius = 3f, center = centre)
}

private fun DrawScope.drawLabel(text: String, at: ScreenPoint, tint: Color, alpha: Float) {
    val paint = android.graphics.Paint().apply {
        color = android.graphics.Color.WHITE
        textSize = 34f
        isAntiAlias = true
        textAlign = android.graphics.Paint.Align.CENTER
        this.alpha = (255 * alpha).toInt()
    }
    val width = paint.measureText(text)
    val padding = 14f

    drawRoundRect(
        color = LABEL_BACKGROUND,
        topLeft = Offset(at.x - width / 2f - padding, at.y - 48f),
        size = androidx.compose.ui.geometry.Size(width + padding * 2, 52f),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(8f, 8f),
        alpha = alpha,
    )
    drawContext.canvas.nativeCanvas.drawText(text, at.x, at.y - 12f, paint)
    drawCircle(color = tint, radius = 5f, center = Offset(at.x, at.y), alpha = alpha)
}

private fun List<ScreenPoint>.toPath(): Path? {
    if (size < 3) return null
    return Path().apply {
        moveTo(this@toPath[0].x, this@toPath[0].y)
        for (i in 1 until this@toPath.size) lineTo(this@toPath[i].x, this@toPath[i].y)
        close()
    }
}

private fun OverlayBand.toPath(): Path? = corners.toPath()
