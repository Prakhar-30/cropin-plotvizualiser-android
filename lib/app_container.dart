import 'core/geo/enu.dart';
import 'data/db/app_database.dart';
import 'config.dart';
import 'data/net/plot_api.dart';
import 'data/plot_repository.dart';
import 'data/telemetry_repository.dart';
import 'location/location_source.dart';
import 'platform/native_platform.dart';
import 'pose/pose_source.dart';
import 'pose/sensor_pose_source.dart';
import 'sim/simulation_engine.dart';

/// Hand-rolled dependency wiring.
///
/// One app, one graph, three consumers - a DI framework here would be more
/// machinery than the thing it wires.
class AppContainer {
  AppContainer._(this._database, this._api, this.platform, this.deviceInfo, this.config);

  static Future<AppContainer> create(PlotFinderConfig config) async {
    final platform = NativePlatform();
    final database = await AppDatabase.open(config.databaseName);
    final deviceInfo = await platform.deviceInfo();
    return AppContainer._(database, HttpPlotApi(baseUrl: config.apiBaseUrl), platform, deviceInfo, config);
  }

  final AppDatabase _database;
  final HttpPlotApi _api;
  final NativePlatform platform;
  final DeviceInfo deviceInfo;
  final PlotFinderConfig config;

  /// Releases the database and the HTTP client. Embedded in a host app the
  /// feature is opened and closed many times, and each opening must not leave
  /// a connection behind.
  Future<void> close() async {
    _api.close();
    await _database.close();
  }

  late final PlotRepository plots = PlotRepository(_database.plots, _database.health, _api);
  late final TelemetryRepository telemetry = TelemetryRepository(_database.telemetry, _api);

  /// Simulation is off unless the host asks for it, and the standalone example
  /// asks only in debug builds. Release builds should have no joystick and no
  /// error sliders, so there is no way to put fabricated positions in front of
  /// an agent who thinks they are real.
  bool get simulationAvailable => config.enableSimulation;

  /// A location source on its own, for screens that want a distance but have no
  /// use for attitude - the plot list, chiefly. Kept separate so browsing the
  /// list does not spin up the rotation sensors.
  LocationSource createLocationSource() => FusedLocationSource(platform);

  /// Builds the pose and location pair for one AR session.
  ///
  /// They are created together because in simulation they are the same object:
  /// one simulated agent has one position and one heading, and handing out two
  /// independent fakes would let them disagree.
  Sensors createSensors({required bool simulated, required LatLng simulationOrigin}) {
    if (simulated && simulationAvailable) {
      final engine = SimulationEngine(simulationOrigin);
      return Sensors(pose: engine, location: engine, simulation: engine);
    }
    return Sensors(
      pose: SensorPoseSource(platform),
      location: createLocationSource(),
      simulation: null,
    );
  }
}

class Sensors {
  const Sensors({required this.pose, required this.location, required this.simulation});

  final PoseSource pose;
  final LocationSource location;

  /// Non-null only in simulation, and only in a debug build.
  final SimulationEngine? simulation;
}
