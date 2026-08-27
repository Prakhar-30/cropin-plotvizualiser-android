package com.fieldar.plotfinder.ui.ar

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldar.plotfinder.core.heading.HeadingConfidence
import com.fieldar.plotfinder.core.render.HealthLayer
import com.fieldar.plotfinder.core.render.SEVERITY_COLOURS
import com.fieldar.plotfinder.ui.formatHectares

/**
 * Camera, overlay, heading chip, mode indicator, snap button.
 *
 * The preview and the canvas share one box sized to the camera's own aspect
 * ratio. That is deliberate: a full-bleed preview would be cropped, and a
 * cropped preview shows a narrower field of view than the characteristics
 * report, which silently scales every projected point.
 */
@Composable
fun ArScreen(
    state: ArUiState,
    onSnap: () -> Unit,
    onCycleHealth: () -> Unit,
    onDismissMessage: () -> Unit,
    onViewportMeasured: (widthPx: Int, heightPx: Int, horizontalFovDeg: Double) -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    simulationPanel: (@Composable () -> Unit)? = null,
) {
    val context = LocalContext.current
    val geometry = remember { readCameraGeometry(context) }
    val density = LocalDensity.current

    DisposableEffect(Unit) {
        onStart()
        onDispose { onStop() }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {

        BoxWithConstraints(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            // Largest box with the camera's aspect ratio that fits the screen.
            val availableW = with(density) { maxWidth.toPx() }
            val availableH = with(density) { maxHeight.toPx() }
            // Everything here stays in Float: `toPx()` returns Float, and mixing
            // it with the Double aspect ratio does not compile.
            val aspect = geometry.portraitAspect.toFloat()
            val fittedW = minOf(availableW, availableH * aspect)
            val fittedH = fittedW / aspect

            LaunchedEffect(fittedW, fittedH) {
                onViewportMeasured(
                    fittedW.toInt(),
                    fittedH.toInt(),
                    geometry.portraitHorizontalFovDeg,
                )
            }

            Box(
                modifier = with(density) {
                    Modifier.size(width = fittedW.toDp(), height = fittedH.toDp())
                },
            ) {
                CameraPreview(modifier = Modifier.fillMaxSize())
                ArOverlay(
                    overlay = state.overlay,
                    health = state.healthOverlay,
                    plotId = state.plot?.id.orEmpty(),
                    areaHectares = state.plot?.areaHectares ?: 0.0,
                    colourIndex = state.plot?.colourIndex ?: 0,
                    confidence = state.headingStatus?.confidence ?: HeadingConfidence.UNRELIABLE,
                    accuracyM = state.accuracyM,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        // Chip and badge share one row so they cannot overlap: at a large system
        // font scale the chip's text grows into the badge if both are absolutely
        // positioned against opposite corners.
        Row(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .safeDrawingPadding()
                .padding(12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            state.headingStatus?.let { status ->
                HeadingChip(status = status, modifier = Modifier.weight(1f, fill = false))
            }
            ModeBadge(state)
        }

        Column(
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().safeDrawingPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            state.message?.let { message ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color(0xCC0B0F14))
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(message, color = Color.White, fontSize = 13.sp)
                    TextButton(onClick = onDismissMessage) { Text("Dismiss") }
                }
            }

            state.plot?.let { plot ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color(0xCC0B0F14))
                        .padding(12.dp),
                ) {
                    HealthControls(state = state, onCycleHealth = onCycleHealth)

                    Text(
                        "Access point: ${plot.landmarkNote.ifBlank { "no landmark note recorded" }}",
                        color = Color(0xFFB6BEC9),
                        fontSize = 12.sp,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                    Button(onClick = onSnap, modifier = Modifier.padding(top = 8.dp)) {
                        Text("Aim at it and tap to pin heading")
                    }
                }
            }

            simulationPanel?.invoke()
        }
    }
}

/**
 * The crop-health toggle, its legend, and every caveat attached to it.
 *
 * The caveats are not decoration. This overlay paints ground brown and tells a
 * field agent to walk there, and there are three separate ways it can be saying
 * something it does not know: the values may be synthetic rather than measured,
 * the heading may be too poor to place them, or the raster may simply not be
 * cached. Each of those has to be visible at the moment the colour is, because
 * a confident-looking overlay is believed.
 */
@Composable
private fun HealthControls(state: ArUiState, onCycleHealth: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        OutlinedButton(onClick = onCycleHealth) {
            Text(
                text = when {
                    state.healthSyncing -> "Fetching health..."
                    else -> state.healthLayer.label
                },
                fontSize = 13.sp,
            )
        }

        Column(modifier = Modifier.padding(start = 10.dp)) {
            val health = state.health
            when {
                state.healthLayer == HealthLayer.OFF -> Text(
                    "Crop health hidden",
                    color = Color(0xFF8A94A0),
                    fontSize = 11.sp,
                )

                health == null -> Text(
                    "No raster cached - tap Sync on the plot list",
                    color = Color(0xFFF59E0B),
                    fontSize = 11.sp,
                )

                // The veto, spelled out. "Nothing is drawn" and "nothing is
                // wrong" look identical on a camera feed, so the reason has to
                // be stated or the agent will read an empty field as a healthy
                // one.
                state.healthVetoed -> Text(
                    "Health hidden until heading is trusted - pin it below",
                    color = Color(0xFFF59E0B),
                    fontSize = 11.sp,
                )

                else -> {
                    val patches = health.hotspots.size
                    Text(
                        text = "${health.indexName.uppercase()} ${health.capturedOn} · " +
                            "$patches patch${if (patches == 1) "" else "es"} · " +
                            "${formatHectares(health.stressedAreaSqM)} stressed",
                        color = Color(0xFFB6BEC9),
                        fontSize = 11.sp,
                    )

                    // Says out loud that healthy ground is being withheld. An
                    // agent who does not know the filter is on reads bare
                    // ground between two brown patches as unsurveyed.
                    val hidden = state.healthOverlay?.hiddenCellCount ?: 0
                    if (hidden > 0) {
                        Text(
                            "$hidden healthy cells hidden - tap for all",
                            color = Color(0xFF8A94A0),
                            fontSize = 10.sp,
                        )
                    }

                    if (health.synthetic) {
                        // The server's own wording, not a second copy of it
                        // written here. If the note ever changes because real
                        // imagery landed, this changes with it.
                        Text(
                            health.note.ifBlank { "Synthetic values - not measured imagery" },
                            color = Color(0xFFF59E0B),
                            fontSize = 10.sp,
                        )
                    }
                }
            }
        }
    }

    if (state.healthLayer != HealthLayer.OFF && state.health != null && !state.healthVetoed) {
        SeverityLegend(minSeverity = state.healthLayer.minSeverity)
    }
}

/**
 * The colour key, showing only the bands this layer actually draws.
 *
 * Listing a band that is currently hidden would have the agent hunting the
 * field for a green that is not on screen.
 */
@Composable
private fun SeverityLegend(minSeverity: Int) {
    Row(
        modifier = Modifier.padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (band in SEVERITY_COLOURS) {
            if (band.level < minSeverity) continue
            Row(
                modifier = Modifier.padding(end = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(modifier = Modifier.size(11.dp).background(Color(band.argb)))
                Text(
                    band.label,
                    color = Color(0xFFB6BEC9),
                    fontSize = 10.sp,
                    modifier = Modifier.padding(start = 5.dp),
                )
            }
        }
    }
}

/** Which render mode is live, and how far the nearest edge is. */
@Composable
private fun ModeBadge(state: ArUiState, modifier: Modifier = Modifier) {
    val overlay = state.overlay ?: return
    Column(
        modifier = modifier
            .background(Color(0xCC0B0F14))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalAlignment = Alignment.End,
    ) {
        Text(
            text = if (overlay.mode == com.fieldar.plotfinder.core.render.RenderMode.FAR) {
                "FAR"
            } else {
                "NEAR"
            },
            color = Color.White,
            fontSize = 13.sp,
        )
        Text(
            text = "${overlay.edgeDistanceM.toInt()} m to edge",
            color = Color(0xFFB6BEC9),
            fontSize = 11.sp,
        )
        if (!state.hasFix) {
            Text("waiting for GNSS", color = Color(0xFFF59E0B), fontSize = 11.sp)
        }
    }
}
