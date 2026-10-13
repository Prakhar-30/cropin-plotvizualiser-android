import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plot_finder/plot_finder.dart';

/// The plot finder on its own, exactly as a host app would embed it.
///
/// The API base URL is a compile-time define; it defaults to the emulator's
/// route to a `plot-web` API running on the host machine:
///
///     flutter run --dart-define=PLOT_API_BASE_URL=http://192.168.1.20:4000/
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  runApp(const MaterialApp(
    title: 'Plot Finder',
    debugShowCheckedModeBanner: false,
    home: PlotFinderScreen(
      config: PlotFinderConfig(
        apiBaseUrl: String.fromEnvironment('PLOT_API_BASE_URL', defaultValue: 'http://10.0.2.2:4000/'),
        // The Kotlin app's file name, so installing over it keeps its cache.
        databaseName: 'plotfinder.db',
        enableSimulation: kDebugMode,
        restoreOrientations: [DeviceOrientation.portraitUp],
      ),
    ),
  ));
}
