package com.fieldar.plotfinder.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Dark only. The app is used outdoors in daylight against a camera preview, and
 * a light chrome would wash the overlay out at exactly the moment it matters.
 */
private val Scheme = darkColorScheme(
    primary = Color(0xFF4ADE80),
    onPrimary = Color(0xFF06210F),
    secondary = Color(0xFFF59E0B),
    background = Color(0xFF0B0F14),
    onBackground = Color(0xFFE5E7EB),
    surface = Color(0xFF121821),
    onSurface = Color(0xFFE5E7EB),
    onSurfaceVariant = Color(0xFF9CA3AF),
    error = Color(0xFFF87171),
)

@Composable
fun PlotFinderTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Scheme, content = content)
}
