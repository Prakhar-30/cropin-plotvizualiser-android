import 'package:flutter/services.dart';

import 'data/net/plot_api.dart';

/// How a host app configures the plot finder.
class PlotFinderConfig {
  const PlotFinderConfig({
    this.apiBaseUrl = defaultApiBaseUrl,
    this.databaseName = 'plot_finder.db',
    this.enableSimulation = false,
    this.restoreOrientations = const [],
  });

  /// Base URL of the plot web tool's API, with or without a trailing slash.
  final String apiBaseUrl;

  /// File name of the offline cache, inside the app's databases directory.
  /// Distinct from anything the host uses, by default.
  final String databaseName;

  /// Shows the debug joystick and error sliders on the AR screen. Never turn
  /// this on in a release build: it puts fabricated positions in front of an
  /// agent who thinks they are real.
  final bool enableSimulation;

  /// The orientations to restore when the AR screen closes.
  ///
  /// The AR screen locks to portrait while open - the overlay maths assumes the
  /// screen frame the sensors are remapped into - and Flutter offers no way to
  /// read the previous setting back. The default, an empty list, hands control
  /// back to the activity's manifest. A host that sets its own preferred
  /// orientations in Dart should pass them here.
  final List<DeviceOrientation> restoreOrientations;
}
