import 'config.dart';
import 'data/db/app_database.dart';
import 'data/net/plot_api.dart';
import 'data/plot_repository.dart';
import 'data/telemetry_repository.dart';
import 'location/location_source.dart';
import 'platform/native_platform.dart';
import 'pose/pose_source.dart';
import 'pose/sensor_pose_source.dart';
import 'pose/vio_pose_source.dart';

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

  /// A location source on its own, for screens that want a distance but have no
  /// use for attitude - the plot list, chiefly. Kept separate so browsing the
  /// list does not spin up the rotation sensors.
  LocationSource createLocationSource() => FusedLocationSource(platform);

  /// Builds the pose and location pair for one AR session.
  ///
  /// [visual] selects ARCore motion tracking for the pose - only when the AR
  /// screen has confirmed ARCore is installed and is showing its camera view.
  /// Otherwise the rotation sensors and counted steps carry it, as before.
  Sensors createSensors({bool visual = false}) => Sensors(
        pose: visual ? VioPoseSource(platform) : SensorPoseSource(platform),
        location: createLocationSource(),
      );
}

class Sensors {
  const Sensors({required this.pose, required this.location});

  final PoseSource pose;
  final LocationSource location;
}
