package com.fieldar.plotfinder.ui.plots

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldar.plotfinder.ui.formatDistance
import com.fieldar.plotfinder.ui.formatHectares

/** Screen 1: cached plots, nearest first, with a sync button. */
@Composable
fun PlotListScreen(
    state: PlotListState,
    onSync: () -> Unit,
    onOpenPlot: (String) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
        Text("Plots", fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        Text(
            text = if (state.hasFix) {
                "${state.items.size} cached, nearest first"
            } else {
                "${state.items.size} cached — waiting for a fix to sort by distance"
            },
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(
                onClick = onSync,
                enabled = !state.syncing,
                modifier = Modifier.weight(1f),
            ) {
                Text(if (state.syncing) "Syncing…" else "Sync", maxLines = 1)
            }
        }

        state.lastSyncMessage?.let {
            Text(
                text = it,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
        }

        if (state.items.isEmpty()) {
            Text(
                text = "Nothing cached yet. Tap Sync while you still have signal — the " +
                    "field will not have any.\n\nPlots are drawn in the web tool; " +
                    "this app finds them.",
                modifier = Modifier.padding(top = 24.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            return@Column
        }

        LazyColumn(modifier = Modifier.padding(top = 12.dp)) {
            items(state.items, key = { it.plot.id }) { item ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenPlot(item.plot.id) }
                        .padding(vertical = 12.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(item.plot.name, fontWeight = FontWeight.Medium)
                        Text(
                            text = item.distanceM?.let(::formatDistance) ?: "—",
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                    Text(
                        text = "${item.plot.id}  ·  ${formatHectares(item.plot.areaSqM)}",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                HorizontalDivider()
            }
        }
    }
}
