package com.fieldar.plotfinder

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.fieldar.plotfinder.ui.ar.ArScreen
import com.fieldar.plotfinder.ui.ar.ArViewModel
import com.fieldar.plotfinder.ui.ar.SimulationPanel
import com.fieldar.plotfinder.ui.detail.PlotDetailScreen
import com.fieldar.plotfinder.ui.plots.PlotListScreen
import com.fieldar.plotfinder.ui.plots.PlotListViewModel
import com.fieldar.plotfinder.ui.theme.PlotFinderTheme

class MainActivity : ComponentActivity() {

    private lateinit var container: AppContainer

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        container = AppContainer(applicationContext)

        setContent {
            PlotFinderTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    PermissionGate { PlotFinderApp(container) }
                }
            }
        }
    }
}

/**
 * Camera and location are both hard requirements: without them there is no
 * preview to draw on and nothing to anchor the local frame to. Asking once at
 * the top keeps every screen below free of permission branches.
 */
@Composable
private fun PermissionGate(content: @Composable () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val required = listOf(Manifest.permission.CAMERA, Manifest.permission.ACCESS_FINE_LOCATION)

    fun granted() = required.all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    var hasPermissions by remember { mutableStateOf(granted()) }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { hasPermissions = granted() }

    LaunchedEffect(Unit) {
        if (!hasPermissions) launcher.launch(required.toTypedArray())
    }

    if (hasPermissions) {
        content()
    } else {
        Column(modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp)) {
            Text("Plot Finder needs the camera and your location")
            Text(
                text = "The camera is the view the boundary is drawn on, and the location " +
                    "anchors it to the ground. Neither leaves the device.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
            Button(
                onClick = { launcher.launch(required.toTypedArray()) },
                modifier = Modifier.padding(top = 16.dp),
            ) {
                Text("Grant permissions")
            }
        }
    }
}

private object Routes {
    const val LIST = "plots"
    const val DETAIL = "plots/{plotId}"
    const val AR = "ar/{plotId}?simulated={simulated}"

    fun detail(plotId: String) = "plots/$plotId"
    fun ar(plotId: String, simulated: Boolean) = "ar/$plotId?simulated=$simulated"
}

@Composable
private fun PlotFinderApp(container: AppContainer) {
    val navController = rememberNavController()
    val listViewModel: PlotListViewModel = viewModel(
        factory = PlotListViewModel.factory(container),
    )
    val listState by listViewModel.state.collectAsState()

    NavHost(navController = navController, startDestination = Routes.LIST) {

        composable(Routes.LIST) {
            PlotListScreen(
                state = listState,
                onSync = listViewModel::sync,
                onOpenPlot = { navController.navigate(Routes.detail(it)) },
            )
        }


        composable(
            route = Routes.DETAIL,
            arguments = listOf(navArgument("plotId") { type = NavType.StringType }),
        ) { entry ->
            val plotId = entry.arguments?.getString("plotId").orEmpty()
            val item = listState.items.firstOrNull { it.plot.id == plotId }
            PlotDetailScreen(
                plot = item?.plot,
                distanceM = item?.distanceM,
                simulationAvailable = container.simulationAvailable,
                onFindPlot = { simulated -> navController.navigate(Routes.ar(plotId, simulated)) },
                onBack = { navController.popBackStack() },
            )
        }

        composable(
            route = Routes.AR,
            arguments = listOf(
                navArgument("plotId") { type = NavType.StringType },
                navArgument("simulated") {
                    type = NavType.BoolType
                    defaultValue = false
                },
            ),
        ) { entry ->
            val plotId = entry.arguments?.getString("plotId").orEmpty()
            val simulated = entry.arguments?.getBoolean("simulated") ?: false

            val arViewModel: ArViewModel = viewModel(
                key = "ar-$plotId-$simulated",
                factory = ArViewModel.factory(container, plotId, simulated),
            )
            val arState by arViewModel.state.collectAsState()
            val simulation = arViewModel.simulation

            ArScreen(
                state = arState,
                onSnap = { arViewModel.snapToAccessPoint() },
                onCycleHealth = arViewModel::cycleHealthLayer,
                onDismissMessage = arViewModel::dismissMessage,
                onViewportMeasured = arViewModel::onViewportMeasured,
                onStart = arViewModel::start,
                onStop = arViewModel::stop,
                simulationPanel = simulation?.let { engine ->
                    { SimulationPanel(engine = engine) }
                },
            )
        }
    }
}
