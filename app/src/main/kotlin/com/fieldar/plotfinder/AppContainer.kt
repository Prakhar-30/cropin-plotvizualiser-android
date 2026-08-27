package com.fieldar.plotfinder

import android.content.Context
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.data.PlotRepository
import com.fieldar.plotfinder.data.TelemetryRepository
import com.fieldar.plotfinder.data.db.AppDatabase
import com.fieldar.plotfinder.data.net.ApiFactory
import com.fieldar.plotfinder.location.FusedLocationSource
import com.fieldar.plotfinder.location.LocationSource
import com.fieldar.plotfinder.pose.PoseSource
import com.fieldar.plotfinder.pose.SensorPoseSource
import com.fieldar.plotfinder.sim.SimulationEngine

/**
 * Hand-rolled dependency wiring.
 *
 * One app, one graph, three consumers - a DI framework here would be more
 * machinery than the thing it wires.
 */
class AppContainer(private val context: Context) {

    private val database by lazy { AppDatabase.get(context) }
    private val api by lazy { ApiFactory.create() }

    val plots by lazy { PlotRepository(database.plots(), database.health(), api) }
    val telemetry by lazy { TelemetryRepository(database.telemetry(), api) }

    /**
     * Simulation is a debug-build capability only. Release builds have no
     * joystick and no error sliders, so there is no way to put fabricated
     * positions in front of an agent who thinks they are real.
     */
    val simulationAvailable: Boolean = BuildConfig.DEBUG

    private var simulation: SimulationEngine? = null

    /**
     * A location source on its own, for screens that want a distance but have no
     * use for attitude - the plot list, chiefly. Kept separate so browsing the
     * list does not spin up the rotation sensors.
     */
    fun createLocationSource(): LocationSource = FusedLocationSource(context)

    /**
     * Builds the pose and location pair for one AR session.
     *
     * They are created together because in simulation they are the same object:
     * one simulated agent has one position and one heading, and handing out two
     * independent fakes would let them disagree.
     */
    fun createSensors(simulated: Boolean, simulationOrigin: LatLng): Sensors =
        if (simulated && simulationAvailable) {
            val engine = SimulationEngine(simulationOrigin)
            simulation = engine
            Sensors(pose = engine, location = engine, simulation = engine)
        } else {
            simulation = null
            Sensors(
                pose = SensorPoseSource(context),
                location = createLocationSource(),
                simulation = null,
            )
        }

    data class Sensors(
        val pose: PoseSource,
        val location: LocationSource,
        /** Non-null only in simulation, and only in a debug build. */
        val simulation: SimulationEngine?,
    )
}
