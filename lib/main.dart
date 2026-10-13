import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'app_container.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait only. The overlay maths assumes the screen frame the sensor
  // rotation matrix is remapped into, and letting the device rotate mid-session
  // would change that frame under the projection.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final container = await AppContainer.create();
  runApp(PlotFinderApp(container: container));
}
