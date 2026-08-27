package com.fieldar.plotfinder.location

import com.fieldar.plotfinder.core.heading.LocationSample
import kotlinx.coroutines.flow.StateFlow

/**
 * Where the agent is.
 *
 * Kept behind an interface for the same reason [com.fieldar.plotfinder.pose.PoseSource]
 * is: simulation mode substitutes a joystick for the GNSS receiver without any
 * code above this line knowing.
 */
interface LocationSource {
    /** Null until the first fix arrives. */
    val location: StateFlow<LocationSample?>

    fun start()
    fun stop()
}
