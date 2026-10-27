import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plot_finder/plot_finder.dart';

/// The plot finder on its own, exactly as a host app would embed it.
///
/// It talks to the deployed API unless a build says otherwise, e.g. for a
/// local `npm run dev:api` seen from the emulator:
///
///     flutter run --dart-define=PLOT_API_BASE_URL=http://10.0.2.2:4000/
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  runApp(const MaterialApp(
    title: 'Plot Finder',
    debugShowCheckedModeBanner: false,
    home: PlotFinderScreen(
      config: PlotFinderConfig(
        apiBaseUrl: defaultApiBaseUrl,
        // The Kotlin app's file name, so installing over it keeps its cache.
        databaseName: 'plotfinder.db',
        restoreOrientations: [DeviceOrientation.portraitUp],
      ),
    ),
  ));
}
