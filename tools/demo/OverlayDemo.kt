package com.fieldar.plotfinder.demo

import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.Enu
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.ScreenPoint
import com.fieldar.plotfinder.core.geo.bearingDeg
import com.fieldar.plotfinder.core.geo.deviceToEnuFromOrientation
import com.fieldar.plotfinder.core.geo.distanceM
import com.fieldar.plotfinder.core.heading.HeadingConfidence
import com.fieldar.plotfinder.core.heading.HeadingFusion
import com.fieldar.plotfinder.core.heading.HeadingSource
import com.fieldar.plotfinder.core.render.PlotOverlay
import com.fieldar.plotfinder.core.render.RenderMode
import com.fieldar.plotfinder.core.render.buildPlotOverlay
import com.fieldar.plotfinder.data.Plot
import com.fieldar.plotfinder.data.net.PlotDto
import com.fieldar.plotfinder.data.toEntity
import com.fieldar.plotfinder.data.toPlot
import com.fieldar.plotfinder.pose.HeadingStatus
import com.fieldar.plotfinder.sim.SimulationEngine
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.awt.BasicStroke
import java.awt.Color
import java.awt.Font
import java.awt.GradientPaint
import java.awt.Graphics2D
import java.awt.Rectangle
import java.awt.RenderingHints
import java.awt.geom.GeneralPath
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.tan

/**
 * Renders the simulation demo to PNGs, with no phone and no emulator.
 *
 * Every number on these frames comes from the shipping code: the plots are the
 * real API's JSON put through the app's own `PlotDto -> PlotEntity -> Plot`
 * mapping, the agent is a real [SimulationEngine], the heading states come from a
 * real [HeadingFusion], and the shapes come from `buildPlotOverlay`. Only two
 * things are substituted - a painted horizon stands in for the camera preview,
 * and Java2D draws the primitives that Compose would.
 *
 * Usage: OverlayDemoKt <plots.json> <output-dir>
 */

private const val WIDTH = 900
/** Camera viewport. The panels below it are chrome, not part of the projection. */
private const val CAM_H = 760
private const val PANEL_H = 430
private const val HEIGHT = CAM_H + PANEL_H

private val GREEN = Color(0x4A, 0xDE, 0x80)
private val AMBER = Color(0xF5, 0x9E, 0x0B)
private val GREY = Color(0x9C, 0xA3, 0xAF)
private val BLUE = Color(0x38, 0xBD, 0xF8)
private val PANEL = Color(0x0B, 0x0F, 0x14)

/** The optics the app falls back to when camera characteristics are unreadable. */
private val INTRINSICS = CameraIntrinsics(
    horizontalFovDeg = 52.0,
    viewportWidthPx = WIDTH,
    viewportHeightPx = CAM_H,
)

private const val TARGET_ID = "PLT-4472"

fun main(args: Array<String>) {
    val plotsFile = File(args[0])
    val outDir = File(args[1]).apply { mkdirs() }

    val json = Json { ignoreUnknownKeys = true }
    val plots: List<Plot> = json
        .decodeFromString(ListSerializer(PlotDto.serializer()), plotsFile.readText())
        .map { it.toEntity().toPlot() }

    val target = plots.first { it.id == TARGET_ID }
    val neighbours = plots.filter { it.id != TARGET_ID }

    println("target ${target.id} ${target.name}  ${"%.2f".format(target.areaHectares)} ha")
    println("neighbours ${neighbours.joinToString(", ") { it.id }}")

    // The agent arrives at the track south of the block. The plot is about 145 m
    // across, so this leaves roughly 115 m to its nearest edge - far mode, and a
    // realistic distance to be identifying a field from.
    val arrival = EnuFrame(target.centroid).toLatLng(Enu(east = -45.0, north = -175.0))
    val aim = bearingDeg(arrival, target.centroid)
    val atBoundary = EnuFrame(target.centroid).toLatLng(Enu(east = 0.0, north = -72.0))

    val frames = listOf(
        Frame(
            "01-arrival-unreliable.png",
            "Arrival at the track. Compass only.",
            "No walk yet, so heading is magnetometer-derived and the chip says so. The overlay " +
                "greys out rather than pretending. This one prompt turns the worst failure mode " +
                "into a two-second user action.",
            arrival, aim, lock = null, accuracyM = 9.0,
        ),
        Frame(
            "02-walk-locked-far.png",
            "After a 25 m walk. Heading locked from course over ground.",
            "Far mode: translucent fill on the ground plane, a vertical post at each corner, and " +
                "the label at the centroid. The green overlay sits exactly on the white dashed " +
                "outline, which is where the plot actually is.",
            arrival, aim, lock = Lock.WALK, accuracyM = 9.0,
        ),
        Frame(
            "03-heading-error-20.png",
            "Same spot. Heading error dialled to 20 degrees.",
            "The overlay swings off the target and lands over the neighbouring field. Nothing " +
                "about the drawing looks wrong - it is confident, crisp and completely misplaced. " +
                "This is the slide that explains the heading architecture.",
            arrival, aim, lock = Lock.WALK, accuracyM = 9.0, headingErrorDeg = 20.0,
        ),
        Frame(
            "04-gnss-error-20m.png",
            "Heading correct again. GNSS error dialled to 20 m instead.",
            "Barely moves. Position error shifts the overlay a few metres, which is invisible at " +
                "this range - which is exactly why the engineering effort went into heading and " +
                "not into a better receiver.",
            arrival, aim, lock = Lock.WALK, accuracyM = 9.0, gnssErrorM = 20.0,
        ),
        Frame(
            "05-near-mode.png",
            "Walked up to the southern boundary. Near mode.",
            "Inside 30 m of the nearest edge the fill is dropped and each boundary edge becomes a " +
                "band whose half-width is the live GNSS accuracy. A crisp line here would be a " +
                "false precision claim.",
            atBoundary, 0.0, lock = Lock.SNAP, accuracyM = 7.0,
        ),
        Frame(
            "06-near-mode-poor-fix.png",
            "Same spot, fix degraded to 18 m.",
            "The band widens to match. The drawing never claims more certainty than the fix " +
                "supports, and the figure is printed on the label.",
            atBoundary, 0.0, lock = Lock.SNAP, accuracyM = 18.0,
        ),
    )

    for (frame in frames) {
        ImageIO.write(render(frame, target, neighbours), "png", File(outDir, frame.file))
        println("wrote ${frame.file}")
    }
}

private enum class Lock { WALK, SNAP }

private class Frame(
    val file: String,
    val caption: String,
    val note: String,
    val position: LatLng,
    val aimDeg: Double,
    val lock: Lock?,
    val accuracyM: Double,
    val headingErrorDeg: Double = 0.0,
    val gnssErrorM: Double = 0.0,
)

/** Drives a real SimulationEngine into the state this frame describes. */
private fun engineFor(frame: Frame): Pair<SimulationEngine, HeadingStatus> {
    var now = 0L
    val engine = SimulationEngine(frame.position, HeadingFusion()) { now }

    engine.reportedAccuracyM = frame.accuracyM
    engine.gnssErrorM = frame.gnssErrorM
    engine.headingErrorDeg = frame.headingErrorDeg
    engine.teleport(frame.position)
    engine.aim(frame.aimDeg)

    // A walked segment and a landmark snap reach the fusion the same way, as a
    // fix carrying a source, so the demo can apply either directly.
    when (frame.lock) {
        Lock.WALK -> engine.applyHeadingFix(frame.aimDeg, HeadingSource.COURSE_OVER_GROUND)
        Lock.SNAP -> engine.applyHeadingFix(frame.aimDeg, HeadingSource.LANDMARK_SNAP)
        null -> Unit
    }
    now = 5_000
    engine.aim(frame.aimDeg)

    return engine to engine.headingStatus.value
}

/**
 * Renders one frame.
 *
 * The key separation: the **world** is drawn from the agent's true position and
 * true aim, because that is what the camera would really be showing, while the
 * **overlay** is drawn from what the app believes - the reported fix and the
 * fused heading, plus whatever error has been injected. Where the two disagree,
 * the gap between them is the error, drawn to scale.
 */
private fun render(frame: Frame, target: Plot, neighbours: List<Plot>): BufferedImage {
    val (engine, status) = engineFor(frame)
    val reported = engine.location.value!!
    val believed = engine.pose.value

    val truthFrame = EnuFrame(engine.truePosition)
    val truthPose = deviceToEnuFromOrientation(engine.trueHeadingDeg, engine.pitchDeg)
    val believedFrame = EnuFrame(reported.position)

    fun overlayOf(plot: Plot, truth: Boolean): PlotOverlay = buildPlotOverlay(
        ring = plot.ring,
        centroid = plot.centroid,
        agent = if (truth) engine.truePosition else reported.position,
        frame = if (truth) truthFrame else believedFrame,
        deviceToEnu = if (truth) truthPose else believed.deviceToEnu,
        intrinsics = INTRINSICS,
        gnssAccuracyM = reported.accuracyM,
    )

    val image = BufferedImage(WIDTH, HEIGHT, BufferedImage.TYPE_INT_RGB)
    val g = image.createGraphics()
    g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
    g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON)
    g.color = PANEL
    g.fillRect(0, 0, WIDTH, HEIGHT)

    g.clip = Rectangle(0, 0, WIDTH, CAM_H)
    drawHorizon(g, engine.pitchDeg)

    // The fields as the camera actually sees them.
    for (plot in neighbours) drawTruth(g, overlayOf(plot, truth = true), BLUE, plot.id)
    drawTruth(g, overlayOf(target, truth = true), Color.WHITE, "${target.id} actual")

    // What the app draws on top of them.
    val overlay = overlayOf(target, truth = false)
    val trusted = status.confidence != HeadingConfidence.UNRELIABLE
    val tint = if (trusted) GREEN else GREY
    val alpha = if (trusted) 1f else 0.4f

    when (overlay.mode) {
        RenderMode.FAR -> drawFar(g, overlay, tint, alpha)
        RenderMode.NEAR -> drawNear(g, overlay, tint, alpha)
    }
    overlay.label?.let { label ->
        val text = buildString {
            append(target.id)
            append("   ")
            append("%.2f ha".format(target.areaHectares))
            append("   ")
            append("%.0f m".format(label.distanceM))
            if (overlay.mode == RenderMode.NEAR) append("   +/-%.0f m".format(reported.accuracyM))
        }
        drawLabel(g, text, label.at.x, label.at.y, tint, alpha)
    }

    drawCrosshair(g)
    drawHeadingChip(g, status)
    drawModeBadge(g, overlay, reported.accuracyM)
    g.clip = null

    drawPlanView(g, 28, CAM_H + 30, 290, engine, target, neighbours, believed.headingDeg, reported.position)
    drawCaption(g, frame, engine, target, reported.position, overlay, believed.headingDeg)

    g.dispose()
    return image
}

/* ------------------------------------------------------------------ camera */

private fun drawHorizon(g: Graphics2D, pitchDeg: Double) {
    val horizonY = (CAM_H / 2.0 + INTRINSICS.focalPx * tan(Math.toRadians(pitchDeg)))
        .coerceIn(0.0, CAM_H.toDouble())
    g.paint = GradientPaint(
        0f, 0f, Color(0x5B, 0x7A, 0x99),
        0f, horizonY.toFloat().coerceAtLeast(1f), Color(0xB4, 0xC7, 0xD8),
    )
    g.fillRect(0, 0, WIDTH, horizonY.roundToInt())
    g.paint = GradientPaint(
        0f, horizonY.toFloat(), Color(0x8F, 0x8E, 0x60),
        0f, CAM_H.toFloat(), Color(0x4A, 0x4A, 0x2F),
    )
    g.fillRect(0, horizonY.roundToInt(), WIDTH, CAM_H - horizonY.roundToInt())
}

/** How a plot really appears in the camera image, before any overlay is drawn. */
private fun drawTruth(g: Graphics2D, overlay: PlotOverlay, colour: Color, id: String) {
    val path = pathOf(overlay.fill) ?: return
    g.color = colour.withAlpha(0.13f)
    g.fill(path)
    g.color = colour.withAlpha(0.6f)
    g.stroke = BasicStroke(2f, BasicStroke.CAP_BUTT, BasicStroke.JOIN_MITER, 10f, floatArrayOf(7f, 5f), 0f)
    g.draw(path)
    overlay.label?.let {
        g.color = colour.withAlpha(0.8f)
        g.font = Font(Font.SANS_SERIF, Font.PLAIN, 12)
        g.drawString(id, it.at.x - 28f, it.at.y + 18f)
    }
}

private fun drawFar(g: Graphics2D, overlay: PlotOverlay, tint: Color, alpha: Float) {
    pathOf(overlay.fill)?.let { path ->
        g.color = tint.withAlpha(0.22f * alpha)
        g.fill(path)
        g.color = tint.withAlpha(0.95f * alpha)
        g.stroke = BasicStroke(3f)
        g.draw(path)
    }
    g.stroke = BasicStroke(5f, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND)
    for (post in overlay.posts) {
        g.color = tint.withAlpha(0.95f * alpha)
        g.drawLine(post.base.x.toInt(), post.base.y.toInt(), post.top.x.toInt(), post.top.y.toInt())
        g.fillOval(post.top.x.toInt() - 6, post.top.y.toInt() - 6, 12, 12)
    }
}

private fun drawNear(g: Graphics2D, overlay: PlotOverlay, tint: Color, alpha: Float) {
    for (band in overlay.bands) {
        val path = pathOf(band.corners) ?: continue
        g.color = tint.withAlpha(0.26f * alpha)
        g.fill(path)
        g.color = tint.withAlpha(0.6f * alpha)
        g.stroke = BasicStroke(2f)
        g.draw(path)
    }
}

private fun drawLabel(g: Graphics2D, text: String, x: Float, y: Float, tint: Color, alpha: Float) {
    g.font = Font(Font.SANS_SERIF, Font.BOLD, 15)
    val width = g.fontMetrics.stringWidth(text)
    g.color = Color(PANEL.red, PANEL.green, PANEL.blue, (215 * alpha).toInt())
    g.fillRoundRect((x - width / 2 - 12).toInt(), (y - 44).toInt(), width + 24, 28, 8, 8)
    g.color = Color(255, 255, 255, (255 * alpha).toInt())
    g.drawString(text, x - width / 2, y - 25)
    g.color = tint.withAlpha(alpha)
    g.fillOval((x - 5).toInt(), (y - 5).toInt(), 10, 10)
}

private fun drawCrosshair(g: Graphics2D) {
    g.color = Color(255, 255, 255, 190)
    g.stroke = BasicStroke(2f)
    val cx = WIDTH / 2
    val cy = CAM_H / 2
    g.drawLine(cx - 18, cy, cx + 18, cy)
    g.drawLine(cx, cy - 18, cx, cy + 18)
}

/* ------------------------------------------------------------------ chrome */

private fun drawHeadingChip(g: Graphics2D, status: HeadingStatus) {
    val (dot, title, detail) = when (status.confidence) {
        HeadingConfidence.LOCKED -> Triple(
            GREEN,
            "Locked",
            "${status.source.name.lowercase().replace('_', ' ')}   +/-${status.expectedErrorDeg.toInt()} deg",
        )

        HeadingConfidence.HOLDING -> Triple(
            AMBER, "Holding", "gyro-carried   ${status.ageSeconds}s since fix",
        )

        HeadingConfidence.UNRELIABLE -> Triple(
            GREY, "Unreliable", "compass only - walk a few steps to lock direction",
        )
    }
    panel(g, 16, 16, 470, 60)
    g.color = dot
    g.fillOval(30, 33, 13, 13)
    g.color = Color.WHITE
    g.font = Font(Font.SANS_SERIF, Font.BOLD, 16)
    g.drawString(title, 52, 45)
    g.color = Color(0xB6, 0xBE, 0xC9)
    g.font = Font(Font.SANS_SERIF, Font.PLAIN, 12)
    g.drawString(detail, 30, 66)
}

private fun drawModeBadge(g: Graphics2D, overlay: PlotOverlay, accuracyM: Double) {
    panel(g, WIDTH - 210, 16, 194, 60)
    g.color = Color.WHITE
    g.font = Font(Font.SANS_SERIF, Font.BOLD, 16)
    g.drawString(overlay.mode.name, WIDTH - 194, 40)
    g.color = Color(0xB6, 0xBE, 0xC9)
    g.font = Font(Font.SANS_SERIF, Font.PLAIN, 12)
    g.drawString("${overlay.edgeDistanceM.toInt()} m to edge", WIDTH - 194, 60)
    g.drawString("fix +/-${accuracyM.toInt()} m", WIDTH - 92, 40)
}

private fun panel(g: Graphics2D, x: Int, y: Int, w: Int, h: Int) {
    g.color = Color(PANEL.red, PANEL.green, PANEL.blue, 215)
    g.fillRoundRect(x, y, w, h, 12, 12)
}

/**
 * Bird's-eye inset.
 *
 * The camera view above is physically honest, which at 100 m means a flat plot is
 * nearly edge-on and collapses towards the horizon - precisely why the design
 * calls for vertical posts rather than relying on the fill. The plan view is here
 * so a reader can check what that camera view is claiming.
 */
private fun drawPlanView(
    g: Graphics2D,
    x: Int,
    y: Int,
    size: Int,
    engine: SimulationEngine,
    target: Plot,
    neighbours: List<Plot>,
    believedHeadingDeg: Double,
    reported: LatLng,
) {
    val frame = EnuFrame(target.centroid)
    val trueHeadingDeg = engine.trueHeadingDeg
    val points = ((neighbours + target).flatMap { it.ring } + engine.truePosition + reported)
        .map { frame.toEnu(it) }
    val minE = points.minOf { it.east } - 25
    val maxE = points.maxOf { it.east } + 25
    val minN = points.minOf { it.north } - 25
    val maxN = points.maxOf { it.north } + 25
    val scale = minOf(size / (maxE - minE), size / (maxN - minN))

    fun sx(p: LatLng) = (x + (frame.toEnu(p).east - minE) * scale)
    fun sy(p: LatLng) = (y + size - (frame.toEnu(p).north - minN) * scale)

    g.color = Color(0x12, 0x18, 0x21)
    g.fillRoundRect(x - 14, y - 14, size + 28, size + 28, 10, 10)

    fun ring(plot: Plot, colour: Color, fill: Float) {
        val path = GeneralPath()
        plot.ring.forEachIndexed { i, position ->
            if (i == 0) path.moveTo(sx(position), sy(position)) else path.lineTo(sx(position), sy(position))
        }
        path.closePath()
        g.color = colour.withAlpha(fill)
        g.fill(path)
        g.color = colour.withAlpha(0.85f)
        g.stroke = BasicStroke(1.5f)
        g.draw(path)
    }

    for (plot in neighbours) ring(plot, BLUE, 0.10f)
    ring(target, GREEN, 0.30f)

    // Where the overlay actually sends the agent.
    //
    // A heading error of d means the app renders every world point d degrees off
    // its true bearing, so on the ground the whole plot appears rotated by -d
    // about the agent - and any position error shifts it as well. Drawing that
    // perceived footprint makes "it landed on the neighbour" a fact you can see
    // rather than a claim in a caption.
    val perceived =
        perceivedRing(target, engine.truePosition, reported, believedHeadingDeg, trueHeadingDeg)
    if (perceived != null) {
        val path = GeneralPath()
        perceived.forEachIndexed { i, position ->
            if (i == 0) path.moveTo(sx(position), sy(position)) else path.lineTo(sx(position), sy(position))
        }
        path.closePath()
        g.color = AMBER.withAlpha(0.22f)
        g.fill(path)
        g.color = AMBER
        g.stroke = BasicStroke(2f, BasicStroke.CAP_BUTT, BasicStroke.JOIN_MITER, 10f, floatArrayOf(6f, 4f), 0f)
        g.draw(path)
    }

    // Where the phone believes it is pointing, as a field-of-view wedge.
    val ax = sx(reported)
    val ay = sy(reported)
    val reach = size * 0.95
    val half = INTRINSICS.horizontalFovDeg / 2.0
    val wedge = GeneralPath()
    wedge.moveTo(ax, ay)
    var a = -half
    while (a <= half + 0.01) {
        val r = Math.toRadians(believedHeadingDeg + a)
        wedge.lineTo(ax + reach * sin(r), ay - reach * cos(r))
        a += 2.0
    }
    wedge.closePath()
    g.color = GREEN.withAlpha(0.15f)
    g.fill(wedge)

    g.color = Color.WHITE
    g.fillOval((sx(engine.truePosition) - 4).toInt(), (sy(engine.truePosition) - 4).toInt(), 9, 9)
    g.color = AMBER
    g.fillOval((ax - 4).toInt(), (ay - 4).toInt(), 9, 9)

    g.font = Font(Font.SANS_SERIF, Font.PLAIN, 11)
    g.color = Color(0x8A, 0x93, 0x9E)
    g.drawString("green = the plot   amber dashed = where the overlay puts it", x - 8, y + size + 26)
    g.drawString("white dot = true position   amber dot = reported fix", x - 8, y + size + 42)
}

/**
 * The target's footprint as the overlay actually presents it on the ground, or
 * null when the app's model and reality agree closely enough to be one shape.
 */
private fun perceivedRing(
    target: Plot,
    truePosition: LatLng,
    reported: LatLng,
    believedHeadingDeg: Double,
    trueHeadingDeg: Double,
): List<LatLng>? {
    val headingErrorDeg = believedHeadingDeg - trueHeadingDeg
    val positionErrorM = distanceM(truePosition, reported)
    if (kotlin.math.abs(headingErrorDeg) < 0.5 && positionErrorM < 1.0) return null

    val believedFrame = EnuFrame(reported)
    val trueFrame = EnuFrame(truePosition)
    val d = Math.toRadians(-headingErrorDeg)

    return target.ring.map { vertex ->
        // Vector from where the app thinks the agent is...
        val v = believedFrame.toEnu(vertex)
        // ...re-aimed by the heading error, then planted at where the agent is.
        trueFrame.toLatLng(
            Enu(
                east = v.east * cos(d) + v.north * sin(d),
                north = -v.east * sin(d) + v.north * cos(d),
            ),
        )
    }
}

private fun drawCaption(
    g: Graphics2D,
    frame: Frame,
    engine: SimulationEngine,
    target: Plot,
    reported: LatLng,
    overlay: PlotOverlay,
    believedHeadingForCaption: Double,
) {
    val left = 360
    val available = WIDTH - left - 28
    g.color = Color.WHITE
    g.font = Font(Font.SANS_SERIF, Font.BOLD, 18)
    val captionBottom = drawWrapped(g, frame.caption, left, CAM_H + 50, available)

    g.color = Color(0xB6, 0xBE, 0xC9)
    g.font = Font(Font.SANS_SERIF, Font.PLAIN, 14)
    drawWrapped(g, frame.note, left, captionBottom + 30, available)

    g.color = AMBER
    g.font = Font(Font.MONOSPACED, Font.PLAIN, 12)
    g.drawString(
        "sim   heading error %2.0f deg   gnss error %2.0f m   accuracy %2.0f m".format(
            engine.headingErrorDeg, engine.gnssErrorM, engine.reportedAccuracyM,
        ),
        left, CAM_H + 320,
    )
    g.color = Color(0x8A, 0x93, 0x9E)
    g.drawString(
        "true %.5f, %.5f   reported %.5f, %.5f   off by %.1f m".format(
            engine.truePosition.lat, engine.truePosition.lng,
            reported.lat, reported.lng,
            distanceM(engine.truePosition, reported),
        ),
        left, CAM_H + 344,
    )
    g.drawString(
        "aim  true %.0f deg   believed %.0f deg".format(
            engine.trueHeadingDeg,
            believedHeadingForCaption,
        ),
        left, CAM_H + 368,
    )
    g.drawString(
        "%s   centroid %.0f m   nearest edge %.0f m   mode %s".format(
            target.id,
            distanceM(reported, target.centroid),
            overlay.edgeDistanceM,
            overlay.mode.name,
        ),
        left, CAM_H + 392,
    )
}

/** Wraps text into the width available beside the plan view; returns the last baseline. */
private fun drawWrapped(g: Graphics2D, text: String, x: Int, y: Int, maxWidth: Int): Int {
    val lineHeight = g.fontMetrics.height + 4
    var line = ""
    var cursorY = y
    for (word in text.split(' ')) {
        val candidate = if (line.isEmpty()) word else "$line $word"
        if (g.fontMetrics.stringWidth(candidate) > maxWidth) {
            g.drawString(line, x, cursorY)
            cursorY += lineHeight
            line = word
        } else {
            line = candidate
        }
    }
    if (line.isNotEmpty()) g.drawString(line, x, cursorY)
    return cursorY
}

private fun pathOf(points: List<ScreenPoint>): GeneralPath? {
    if (points.size < 3) return null
    val path = GeneralPath()
    path.moveTo(points[0].x.toDouble(), points[0].y.toDouble())
    for (i in 1 until points.size) path.lineTo(points[i].x.toDouble(), points[i].y.toDouble())
    path.closePath()
    return path
}

private fun Color.withAlpha(a: Float) = Color(red, green, blue, (a.coerceIn(0f, 1f) * 255).toInt())
