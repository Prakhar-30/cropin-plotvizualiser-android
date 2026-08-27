package com.fieldar.plotfinder.ui.detail

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.openRing
import com.fieldar.plotfinder.data.Plot
import com.fieldar.plotfinder.ui.formatCacheAge
import com.fieldar.plotfinder.ui.formatDistance
import com.fieldar.plotfinder.ui.formatIsoDate
import com.fieldar.plotfinder.ui.formatHectares
import com.fieldar.plotfinder.ui.formatLatLng

/**
 * Screen 2: what the agent reads before setting off.
 *
 * The thumbnail is drawn from the cached ring rather than fetched as a map tile.
 * A tile would be a blank grey square at the exact moment it is needed - the
 * agent is standing at the roadside with no data - whereas the shape is already
 * on the device and is the thing that lets them recognise the field.
 */
@Composable
fun PlotDetailScreen(
    plot: Plot?,
    distanceM: Double?,
    simulationAvailable: Boolean,
    onFindPlot: (simulated: Boolean) -> Unit,
    onBack: () -> Unit,
) {
    if (plot == null) {
        Column(modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
            TextButton(onClick = onBack) { Text("Back") }
            Text("This plot is not in the offline cache.")
        }
        return
    }

    // Scrollable: at a large system font scale the action buttons fall below the
    // fold, and an unreachable "Find this plot" makes the screen useless.
    Column(
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        TextButton(onClick = onBack) { Text("Back") }

        Text(plot.name, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        Text(
            text = "${plot.id}  ·  ${formatHectares(plot.areaSqM)}" +
                (distanceM?.let { "  ·  ${formatDistance(it)} away" } ?: ""),
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        PlotSketch(
            plot = plot,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1.4f)
                .padding(vertical = 16.dp),
        )

        DetailRow("Access point", formatLatLng(plot.accessPoint.lat, plot.accessPoint.lng))
        DetailRow("Landmark", plot.landmarkNote.ifBlank { "none recorded" })
        DetailRow("Centroid", formatLatLng(plot.centroid.lat, plot.centroid.lng))
        DetailRow("Corners", plot.cornerCount.toString())
        DetailRow("Surveyed", formatIsoDate(plot.createdAt))
        DetailRow("Cached", formatCacheAge(plot.syncedAtMs))

        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Button(onClick = { onFindPlot(false) }) { Text("Find this plot") }
            if (simulationAvailable) {
                TextButton(onClick = { onFindPlot(true) }) { Text("Simulate") }
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Column(modifier = Modifier.padding(vertical = 6.dp)) {
        Text(label, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = 14.sp)
    }
}

/**
 * Plan view of the boundary with the access point marked, drawn in metres and
 * scaled to fit. Purely offline.
 */
@Composable
private fun PlotSketch(plot: Plot, modifier: Modifier = Modifier) {
    val frame = EnuFrame(plot.centroid)
    val ring = openRing(plot.ring.map { frame.toEnu(it) })
    val access = frame.toEnu(plot.accessPoint)
    if (ring.size < 3) return

    val points = ring + access
    val minE = points.minOf { it.east }
    val maxE = points.maxOf { it.east }
    val minN = points.minOf { it.north }
    val maxN = points.maxOf { it.north }

    Canvas(modifier = modifier) {
        val padding = 24f
        val spanE = (maxE - minE).coerceAtLeast(1.0)
        val spanN = (maxN - minN).coerceAtLeast(1.0)
        // One scale for both axes, so the sketch keeps the plot's real shape.
        val scale = minOf(
            (size.width - padding * 2) / spanE,
            (size.height - padding * 2) / spanN,
        )
        val offsetX = (size.width - (spanE * scale).toFloat()) / 2f
        val offsetY = (size.height - (spanN * scale).toFloat()) / 2f

        // North is up, so the north axis is inverted against screen y.
        fun toScreen(east: Double, north: Double) = Offset(
            x = offsetX + ((east - minE) * scale).toFloat(),
            y = size.height - offsetY - ((north - minN) * scale).toFloat(),
        )

        val path = Path().apply {
            val first = toScreen(ring[0].east, ring[0].north)
            moveTo(first.x, first.y)
            for (i in 1 until ring.size) {
                val p = toScreen(ring[i].east, ring[i].north)
                lineTo(p.x, p.y)
            }
            close()
        }

        drawPath(path, color = Color(0xFF38BDF8), alpha = 0.18f)
        drawPath(path, color = Color(0xFF38BDF8), style = Stroke(width = 3f))

        for (vertex in ring) {
            drawCircle(
                color = Color(0xFF38BDF8),
                radius = 5f,
                center = toScreen(vertex.east, vertex.north),
            )
        }
        drawCircle(
            color = Color(0xFFF59E0B),
            radius = 9f,
            center = toScreen(access.east, access.north),
        )
    }
}
