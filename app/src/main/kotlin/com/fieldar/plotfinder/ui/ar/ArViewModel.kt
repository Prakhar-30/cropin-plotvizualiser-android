package com.fieldar.plotfinder.ui.ar

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.fieldar.plotfinder.AppContainer
import com.fieldar.plotfinder.core.geo.CameraIntrinsics
import com.fieldar.plotfinder.core.geo.Enu
import com.fieldar.plotfinder.core.geo.EnuFrame
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.Mat3
import com.fieldar.plotfinder.core.geo.PositionStabilizer
import com.fieldar.plotfinder.core.geo.horizontalAngleOffsetDeg
import com.fieldar.plotfinder.core.heading.CourseOverGroundDetector
import com.fieldar.plotfinder.core.heading.HeadingConfidence
import com.fieldar.plotfinder.core.heading.HeadingSource
import com.fieldar.plotfinder.core.heading.LocationSample
import com.fieldar.plotfinder.core.heading.headingFromLandmarkSnap
import com.fieldar.plotfinder.core.render.HealthField
import com.fieldar.plotfinder.core.render.HealthLayer
import com.fieldar.plotfinder.core.render.HealthOverlay
import com.fieldar.plotfinder.core.render.PlotOverlay
import com.fieldar.plotfinder.core.render.buildHealthOverlay
import com.fieldar.plotfinder.core.render.buildPlotOverlay
import com.fieldar.plotfinder.data.Plot
import com.fieldar.plotfinder.data.PlotHealth
import com.fieldar.plotfinder.data.db.TelemetryEntity
import com.fieldar.plotfinder.pose.DevicePose
import com.fieldar.plotfinder.pose.HeadingStatus
import com.fieldar.plotfinder.sim.SimulationEngine
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class ArUiState(
    val plot: Plot? = null,
    val overlay: PlotOverlay? = null,
    val pose: DevicePose = DevicePose.UNKNOWN,
    val headingStatus: HeadingStatus? = null,
    val accuracyM: Double = 0.0,
    val hasFix: Boolean = false,
    /** True while the stabiliser judges the agent to be standing still. */
    val stationary: Boolean = false,
    /** The cached crop-health raster, or null if none has ever been pulled. */
    val health: PlotHealth? = null,
    /** What the agent asked to see. Not necessarily what is drawn - see below. */
    val healthLayer: HealthLayer = HealthLayer.STRESS,
    val healthOverlay: HealthOverlay? = null,
    val healthSyncing: Boolean = false,
    val message: String? = null,
) {
    /**
     * The layer actually drawn, after the heading veto.
     *
     * A boundary drawn on a bad heading is wrong about where a fence is, and the
     * agent can see the fence to check it. A health patch drawn on a bad heading
     * is wrong about which ground is failing, and there is nothing in the field
     * to check it against - stressed crop and healthy crop look alike from a
     * distance, which is the entire reason for showing the raster. So the
     * boundary degrades to grey and stays up, while this switches off rather
     * than sending someone to dig up a healthy corner.
     */
    val effectiveHealthLayer: HealthLayer
        get() = if (headingStatus?.confidence == HeadingConfidence.UNRELIABLE) {
            HealthLayer.OFF
        } else {
            healthLayer
        }

    /** True when the layer is on but the heading veto is suppressing it. */
    val healthVetoed: Boolean
        get() = healthLayer != HealthLayer.OFF && effectiveHealthLayer == HealthLayer.OFF
}

/**
 * Runs one AR session: pose in, overlay out, telemetry recorded.
 */
class ArViewModel(
    private val container: AppContainer,
    private val plotId: String,
    simulated: Boolean,
) : ViewModel() {

    private val _state = MutableStateFlow(ArUiState())
    val state: StateFlow<ArUiState> = _state.asStateFlow()

    private val courseOverGround = CourseOverGroundDetector()

    /**
     * Smooths the agent's position so a stationary agent gets a stationary
     * overlay. Applied to the render path only - see [onLocation].
     */
    private val stabilizer = PositionStabilizer()
    private val sensors = container.createSensors(simulated, SIMULATION_ORIGIN)
    val simulation: SimulationEngine? = sensors.simulation

    /**
     * The local metric frame, re-anchored whenever the agent walks far enough.
     * Held here rather than rebuilt per frame so that a single origin serves
     * every point in one drawing pass - two points converted against different
     * origins would be metres apart for no reason.
     */
    private var frame: EnuFrame? = null

    private var intrinsics: CameraIntrinsics? = null
    private var lastLocation: LocationSample? = null

    /**
     * The health raster in metres, built once per frame anchor.
     *
     * Rebuilt only when [frame] changes, which is when the agent has walked far
     * enough to re-anchor - not on every pose sample. Converting a few hundred
     * cells from degrees is trigonometry per corner, and doing that at sensor
     * rate is the difference between a smooth overlay and a stuttering one.
     */
    private var healthField: HealthField? = null

    /** The filtered position everything is drawn against. */
    private var agentPosition: LatLng? = null

    /** Worst single-update overlay shift seen while standing still, for telemetry. */
    private var worstStationaryShiftM = 0.0
    private var frameAnchoredAtMs = 0L
    private val sessionStartedAtMs = System.currentTimeMillis()
    private val sessionId = java.util.UUID.randomUUID().toString()
    private var telemetryJob: Job? = null

    init {
        viewModelScope.launch {
            val plot = container.plots.findById(plotId)
            _state.value = _state.value.copy(
                plot = plot,
                message = if (plot == null) "Plot $plotId is not in the offline cache" else null,
            )
            // Simulation starts the agent a realistic walk away from the plot,
            // so far mode is what you see first. The stabiliser is reset first:
            // a teleport is not a GNSS observation, and filtering it against an
            // estimate anchored somewhere else would have it gated as a wild
            // outlier - which is exactly what happened, leaving the overlay
            // stranded 97 km away because the simulator publishes a fix only on
            // an event and never sent a second one to break the hold.
            if (plot != null) {
                stabilizer.reset()
                simulation?.teleport(simulationStartFor(plot))
                // The raster is loaded after the plot, never before: the
                // boundary is what the agent came for and must not wait on it.
                loadHealth()

                // A plot cached before this feature existed has a boundary and
                // no raster, and the layer defaults to on - so without this the
                // agent opens AR, sees no colour, and concludes the field is
                // healthy. One quiet attempt fixes that. Quiet because it is
                // speculative: failing to reach the network here is the normal
                // rural case and is not worth a banner.
                if (_state.value.health == null) refreshHealth(announce = false)
            }
        }

        viewModelScope.launch {
            sensors.location.location.collect { sample -> if (sample != null) onLocation(sample) }
        }
        viewModelScope.launch {
            sensors.pose.pose.collect { pose -> onPose(pose) }
        }
        viewModelScope.launch {
            sensors.pose.headingStatus.collect { status ->
                _state.value = _state.value.copy(headingStatus = status)
            }
        }
    }

    fun start() {
        sensors.pose.start()
        sensors.location.start()
        telemetryJob = viewModelScope.launch { container.telemetry.syncPending() }
    }

    fun stop() {
        sensors.pose.stop()
        sensors.location.stop()
        recordTelemetry()
        telemetryJob?.cancel()
    }

    /** The viewport is only known once Compose has laid the canvas out. */
    fun onViewportMeasured(widthPx: Int, heightPx: Int, horizontalFovDeg: Double) {
        if (widthPx <= 0 || heightPx <= 0) return
        val next = CameraIntrinsics(horizontalFovDeg, widthPx, heightPx)
        if (next != intrinsics) {
            android.util.Log.i(
                LOG_TAG,
                "viewport %dx%d hFOV=%.1f deg -> focal=%.1f px"
                    .format(widthPx, heightPx, horizontalFovDeg, next.focalPx),
            )
        }
        intrinsics = next
        rebuildOverlay()
    }

    /**
     * Landmark snap: the agent has the crosshair on the plot's access point.
     *
     * Both endpoints are known, so the true bearing is computable outright - one
     * tap and the heading is pinned to within a couple of degrees, no walking
     * required. [crosshairXPx] allows for a crosshair that is not dead centre.
     */
    fun snapToAccessPoint(crosshairXPx: Double? = null) {
        val plot = _state.value.plot ?: return
        val agent = lastLocation?.position ?: run {
            _state.value = _state.value.copy(message = "Waiting for a GNSS fix before snapping")
            return
        }
        val offsetDeg = crosshairXPx?.let { x ->
            intrinsics?.let { horizontalAngleOffsetDeg(x, it) }
        } ?: 0.0

        val heading = headingFromLandmarkSnap(agent, plot.accessPoint, offsetDeg)
        if (heading == null) {
            _state.value = _state.value.copy(
                message = "Too close to the access point to snap - aim at something further off",
            )
            return
        }
        sensors.pose.applyHeadingFix(heading, HeadingSource.LANDMARK_SNAP)
        _state.value = _state.value.copy(message = "Heading pinned to the access point")
    }

    /** Cycles off - problem areas - all cells. */
    fun cycleHealthLayer() {
        val next = _state.value.healthLayer.next()
        _state.value = _state.value.copy(healthLayer = next)
        if (next != HealthLayer.OFF && _state.value.health == null) {
            refreshHealth()
        } else {
            rebuildOverlay()
        }
    }

    /**
     * Pulls this plot's raster from the API on demand.
     *
     * Needed because a plot cached before this feature existed has a boundary
     * and no raster, and making the agent re-sync every plot in the district to
     * colour one field would be an absurd way to spend their signal.
     */
    fun refreshHealth(announce: Boolean = true) {
        if (_state.value.healthSyncing) return
        _state.value = _state.value.copy(healthSyncing = true)
        viewModelScope.launch {
            container.plots.syncHealth(plotId)
            loadHealth()
            // Judged on what is now cached, not on what the call returned: a
            // fetch that failed against a raster already on disk is not a
            // problem the agent needs to hear about.
            val failed = _state.value.health == null
            _state.value = _state.value.copy(
                healthSyncing = false,
                message = if (announce && failed) {
                    "No crop health cached for this plot, and no signal to fetch it"
                } else {
                    _state.value.message
                },
            )
        }
    }

    private suspend fun loadHealth() {
        _state.value = _state.value.copy(health = container.plots.healthFor(plotId))
        // The metric conversion belongs to the old raster; keeping it would
        // draw the previous cells under the new data.
        healthField = null
        rebuildOverlay()
    }

    fun dismissMessage() {
        _state.value = _state.value.copy(message = null)
    }

    private fun onLocation(sample: LocationSample) {
        lastLocation = sample

        // A walked segment is the one heading source no magnetic disturbance can
        // touch, so every fix is offered to the detector - and it is offered the
        // RAW fix, deliberately. The stabiliser's whole job is to suppress
        // apparent movement, which is precisely the signal course-over-ground
        // measures; feeding it filtered positions would shorten every segment
        // and bias the bearing towards whatever the filter already believed.
        courseOverGround.add(sample)?.let { locked ->
            sensors.pose.applyHeadingFix(locked, HeadingSource.COURSE_OVER_GROUND)
        }

        val stabilized = stabilizer.update(
            position = sample.position,
            accuracyM = sample.accuracyM,
            speedMps = sample.speedMps,
            timestampMs = sample.timestampMs,
        )
        agentPosition = stabilized.position

        if (stabilized.stationary) {
            worstStationaryShiftM = maxOf(worstStationaryShiftM, stabilized.shiftM)
        }

        val current = frame
        if (current == null || current.needsReanchor(stabilized.position)) {
            frame = EnuFrame(stabilized.position)
            frameAnchoredAtMs = System.currentTimeMillis()
            // Every cached metre is measured from the old origin. Keeping them
            // would offset the whole raster by however far the agent walked.
            healthField = null
        }

        _state.value = _state.value.copy(
            accuracyM = sample.accuracyM,
            hasFix = true,
            stationary = stabilized.stationary,
        )
        rebuildOverlay()
    }

    private fun onPose(pose: DevicePose) {
        _state.value = _state.value.copy(pose = pose)
        rebuildOverlay()
    }

    private fun rebuildOverlay() {
        val plot = _state.value.plot ?: return
        val frame = this.frame ?: return
        val intrinsics = this.intrinsics ?: return
        val agent = agentPosition ?: return
        val pose = _state.value.pose

        _state.value = _state.value.copy(
            overlay = buildPlotOverlay(
                ring = plot.ring,
                centroid = plot.centroid,
                agent = agent,
                frame = frame,
                deviceToEnu = pose.deviceToEnu,
                intrinsics = intrinsics,
                gnssAccuracyM = _state.value.accuracyM,
            ),
            healthOverlay = buildHealth(frame, agent, pose.deviceToEnu, intrinsics),
        )
    }

    /**
     * Projects the health raster against the same eye and frame as the boundary.
     *
     * Both take the camera from the *stabilised* agent fix through this one
     * frame, so the raster and the boundary move together or not at all.
     * Deriving the eye separately here is precisely what would let the brown
     * ground drift outside the plot that is supposed to contain it.
     */
    private fun buildHealth(
        frame: EnuFrame,
        agent: LatLng,
        deviceToEnu: Mat3,
        intrinsics: CameraIntrinsics,
    ): HealthOverlay? {
        val layer = _state.value.effectiveHealthLayer
        if (layer == HealthLayer.OFF) return null
        val health = _state.value.health ?: return null

        val field = healthField?.takeIf { it.matches(frame) }
            ?: HealthField(health.cells, health.hotspots, frame).also { healthField = it }
        if (field.isEmpty) return null

        return buildHealthOverlay(
            field = field,
            eye = frame.toEnu(agent),
            enuToDevice = deviceToEnu.transpose(),
            intrinsics = intrinsics,
            layer = layer,
        )
    }

    /** One row per session, written on the way out. No UI, by design. */
    private fun recordTelemetry() {
        val snapshot = _state.value
        val location = lastLocation ?: return
        val status = snapshot.headingStatus ?: return
        val mode = snapshot.overlay?.mode?.name ?: "NONE"

        val now = System.currentTimeMillis()
        viewModelScope.launch {
            container.telemetry.record(
                TelemetryEntity(
                    timestampMs = now,
                    sessionId = sessionId,
                    plotId = plotId,
                    lat = location.position.lat,
                    lng = location.position.lng,
                    reportedAccuracyM = location.accuracyM,
                    headingDeg = snapshot.pose.headingDeg,
                    headingSource = status.source.name,
                    headingConfidence = status.confidence.name,
                    renderMode = mode,
                    anchorShiftM = worstStationaryShiftM,
                    anchorAgeS = if (frameAnchoredAtMs == 0L) {
                        0.0
                    } else {
                        (now - frameAnchoredAtMs) / 1000.0
                    },
                    deviceModel = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                    appVersion = com.fieldar.plotfinder.BuildConfig.VERSION_NAME,
                    sessionDurationMs = now - sessionStartedAtMs,
                ),
            )
            container.telemetry.syncPending()
        }
    }

    /** Drops the agent about 127 m south-west of the plot, a plausible road arrival. */
    private fun simulationStartFor(plot: Plot) =
        EnuFrame(plot.centroid).toLatLng(Enu(east = -90.0, north = -90.0))

    companion object {
        /** Used only until the plot loads and the agent is placed relative to it. */
        val SIMULATION_ORIGIN = LatLng(12.7862, 76.7201)

        fun factory(container: AppContainer, plotId: String, simulated: Boolean) =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    ArViewModel(container, plotId, simulated) as T
            }
    }
}
