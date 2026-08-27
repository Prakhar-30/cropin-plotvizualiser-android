package com.fieldar.plotfinder.ui.plots

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.fieldar.plotfinder.AppContainer
import com.fieldar.plotfinder.core.geo.LatLng
import com.fieldar.plotfinder.core.geo.distanceM
import com.fieldar.plotfinder.data.Plot
import com.fieldar.plotfinder.data.SyncResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** A cached plot plus how far the agent currently is from it. */
data class PlotListItem(val plot: Plot, val distanceM: Double?)

data class PlotListState(
    val items: List<PlotListItem> = emptyList(),
    val syncing: Boolean = false,
    val lastSyncMessage: String? = null,
    val hasFix: Boolean = false,
)

/**
 * The cached plot list.
 *
 * Rows come from Room and appear whether or not there is signal; syncing is an
 * explicit button, never a precondition for seeing anything.
 */
class PlotListViewModel(private val container: AppContainer) : ViewModel() {

    private val locationSource = container.createLocationSource()

    private val _state = MutableStateFlow(PlotListState())
    val state: StateFlow<PlotListState> = _state.asStateFlow()

    private var plots: List<Plot> = emptyList()
    private var here: LatLng? = null

    init {
        viewModelScope.launch {
            container.plots.observePlots().collect { cached ->
                plots = cached
                recompute()
            }
        }
        viewModelScope.launch {
            locationSource.location.collect { sample ->
                here = sample?.position
                _state.value = _state.value.copy(hasFix = sample != null)
                recompute()
            }
        }
        locationSource.start()
    }

    override fun onCleared() {
        locationSource.stop()
    }

    // Plots are drawn in the web tool and only ever read here. The phone used
    // to be able to drop a test square, which was a scaffold for trying the app
    // before the API was reachable; it is gone now that there is a hosted
    // backend, and gone deliberately. Two places that can create a boundary
    // means two definitions of what a boundary is, and the one on a phone -
    // eyeballed, unverified, standing in the middle of the field - is the one
    // that would end up in a dispute.
    /** Pulls fresh plots around the agent, or everything if there is no fix yet. */
    fun sync() {
        if (_state.value.syncing) return
        _state.value = _state.value.copy(syncing = true, lastSyncMessage = null)
        viewModelScope.launch {
            val message = when (val result = container.plots.sync(around = here)) {
                is SyncResult.Success -> if (result.widenedToEverything) {
                    "No plots within 5 km — cached all ${result.plotCount} instead"
                } else {
                    "Cached ${result.plotCount} plot(s)"
                }
                // Offline is the expected state at a rural site, so this reads as
                // a status line rather than an error.
                is SyncResult.Failed ->
                    "No connection (${result.reason}) — showing ${plots.size} cached plot(s)"
            }
            container.telemetry.syncPending()
            _state.value = _state.value.copy(syncing = false, lastSyncMessage = message)
        }
    }

    private fun recompute() {
        val from = here
        _state.value = _state.value.copy(
            items = plots
                .map { PlotListItem(it, from?.let { origin -> distanceM(origin, it.centroid) }) }
                .sortedBy { it.distanceM ?: Double.MAX_VALUE },
        )
    }

    companion object {
        fun factory(container: AppContainer) = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                PlotListViewModel(container) as T
        }
    }
}
