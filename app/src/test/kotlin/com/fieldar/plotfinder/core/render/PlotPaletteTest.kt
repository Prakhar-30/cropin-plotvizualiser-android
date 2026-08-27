package com.fieldar.plotfinder.core.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The palette is generated from palette.json, so these check the contract the
 * renderer relies on rather than the specific hues.
 */
class PlotPaletteTest {

    @Test
    fun `every slot is fully opaque ARGB`() {
        // Alpha must be baked in at 0xFF: the renderer applies PlotAlpha per
        // surface, and a colour carrying its own transparency would multiply
        // twice and wash the boundary out.
        for (colour in PLOT_COLOURS) {
            val alpha = (colour.argb ushr 24) and 0xFF
            assertEquals("slot ${colour.index} (${colour.name}) is not opaque", 0xFF, alpha)
        }
    }

    @Test
    fun `slots are distinct and densely indexed`() {
        assertEquals(PLOT_COLOURS.size, PLOT_COLOURS.map { it.argb }.toSet().size)
        assertEquals(PLOT_COLOURS.indices.toList(), PLOT_COLOURS.map { it.index })
    }

    @Test
    fun `an out of range colour index wraps rather than throwing`() {
        // A plot arriving with a bad slot must still be drawn. This is the whole
        // reason plotColour does modular arithmetic instead of indexing.
        assertEquals(PLOT_COLOURS[0], plotColour(0))
        assertEquals(PLOT_COLOURS[1], plotColour(PLOT_COLOURS.size + 1))
        assertEquals(PLOT_COLOURS[PLOT_COLOURS.size - 1], plotColour(-1))
    }

    @Test
    fun `no slot is green`() {
        // Green boundaries vanish against a green crop and against satellite
        // imagery of farmland, which is the one background this app always has.
        for (colour in PLOT_COLOURS) {
            val r = (colour.argb ushr 16) and 0xFF
            val g = (colour.argb ushr 8) and 0xFF
            val b = colour.argb and 0xFF
            assertTrue(
                "slot ${colour.index} (${colour.name}) is dominated by green",
                !(g > r + 40 && g > b + 40),
            )
        }
    }
}
