package com.fieldar.plotfinder.ui.ar

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldar.plotfinder.sim.SimulationEngine
import kotlin.math.hypot

/**
 * Debug-only controls that drive the overlay from a desk.
 *
 * Worth the code several times over: the failure modes this app exists to
 * handle only occur in a field, and "drive to a farm and walk 20 m" is not a
 * debug cycle. The error sliders also make the demo reproducible on command -
 * dial heading error to 20 degrees and watch the boundary settle over the
 * neighbouring plot, which is the argument for the whole heading architecture in
 * one gesture.
 *
 * Compiled into debug builds only; see [com.fieldar.plotfinder.AppContainer].
 */
@Composable
fun SimulationPanel(
    engine: SimulationEngine,
    modifier: Modifier = Modifier,
) {
    var heading by remember { mutableStateOf(0f) }
    var gnssError by remember { mutableStateOf(0f) }
    var headingError by remember { mutableStateOf(0f) }
    var accuracy by remember { mutableStateOf(6f) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
            .background(Color(0xE60B0F14))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("SIMULATION", color = Color(0xFFF59E0B), fontSize = 11.sp)

        Row(verticalAlignment = Alignment.CenterVertically) {
            WalkPad(
                onWalk = { east, north -> engine.move(east, north) },
                modifier = Modifier.size(96.dp),
            )
            Column(modifier = Modifier.padding(start = 14.dp)) {
                LabelledSlider(
                    label = "Aim  ${heading.toInt()}°",
                    value = heading,
                    range = 0f..359f,
                ) {
                    heading = it
                    engine.aim(it.toDouble())
                }
                LabelledSlider(
                    label = "Heading error  ${headingError.toInt()}°",
                    value = headingError,
                    range = 0f..45f,
                ) {
                    headingError = it
                    engine.headingErrorDeg = it.toDouble()
                    engine.refresh()
                }
            }
        }

        LabelledSlider(
            label = "GNSS error  ${gnssError.toInt()} m",
            value = gnssError,
            range = 0f..30f,
        ) {
            gnssError = it
            engine.gnssErrorM = it.toDouble()
            engine.refresh()
        }
        LabelledSlider(
            label = "Reported accuracy  ${accuracy.toInt()} m",
            value = accuracy,
            range = 1f..30f,
        ) {
            accuracy = it
            engine.reportedAccuracyM = it.toDouble()
            engine.refresh()
        }
    }
}

@Composable
private fun LabelledSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
) {
    Column {
        Text(label, color = Color(0xFFB6BEC9), fontSize = 11.sp)
        Slider(value = value, onValueChange = onChange, valueRange = range)
    }
}

/**
 * Thumb pad that walks the simulated agent.
 *
 * Movement is world-absolute: dragging up walks north regardless of where the
 * phone is aimed, which keeps "walk to lock a heading" separable from "turn to
 * look at the plot" while debugging.
 */
@Composable
private fun WalkPad(onWalk: (eastMps: Double, northMps: Double) -> Unit, modifier: Modifier = Modifier) {
    var knob by remember { mutableStateOf(Offset.Zero) }
    val maxSpeedMps = 1.6

    Box(
        modifier = modifier
            .clip(CircleShape)
            .background(Color(0x33FFFFFF))
            .pointerInput(Unit) {
                val radius = size.width / 2f
                detectDragGestures(
                    onDragEnd = {
                        knob = Offset.Zero
                        onWalk(0.0, 0.0)
                    },
                ) { change, drag ->
                    change.consume()
                    val next = knob + drag
                    val length = hypot(next.x, next.y)
                    knob = if (length > radius) next * (radius / length) else next
                    onWalk(
                        (knob.x / radius) * maxSpeedMps,
                        // Screen y grows downward; dragging up must walk north.
                        (-knob.y / radius) * maxSpeedMps,
                    )
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(Color(0xFFF59E0B)),
        )
        Text("walk", color = Color(0xFF0B0F14), fontSize = 9.sp)
    }
}
