# Embedding Plot Finder in a Flutter app

Plot Finder is a Flutter plugin package. A host app adds one dependency and
pushes one screen; there is no Kotlin to copy and no `MainActivity` to change.

## 1. Add the dependency

```yaml
dependencies:
  plot_finder:
    git:
      url: https://github.com/Prakhar-30/cropin-plotvizualiser-android.git
      ref: flutter
```

## 2. Open it

```dart
import 'package:plot_finder/plot_finder.dart';

if (plotFinderSupported) {               // false on iOS and web - hide the entry point
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const PlotFinderScreen(
      config: PlotFinderConfig(
        apiBaseUrl: 'https://your-plot-api.example.com/',
      ),
    ),
  ));
}
```

That is the whole integration. The screen asks for camera and location itself,
opens its own cache and closes it when popped, and pushes its detail and AR
pages on your navigator, so system back behaves as everywhere else in your app.

## `PlotFinderConfig`

| Field | Default | Notes |
|---|---|---|
| `apiBaseUrl` | `http://10.0.2.2:4000/` | The plot web tool's API. Release builds block cleartext HTTP, so use HTTPS |
| `databaseName` | `plot_finder.db` | The offline cache's file in your app's databases directory |
| `enableSimulation` | `false` | Debug joystick and error sliders. Never in a release build |
| `restoreOrientations` | `[]` | Applied when the AR screen closes. See below |

## What it does to your build

Designed to change as little as possible:

- **No third-party native dependencies.** The Kotlin uses only the Android
  framework and the Flutter embedding. Location comes from the framework's
  `LocationManager` (its fused provider on Android 12+, GPS before that) rather
  than Google Play Services, so it cannot force a different
  `play-services-location` version on your app - 20.x and 21.x are
  binary-incompatible, a clash that compiles and then crashes. Permissions are
  requested by the plugin itself, so there is no `permission_handler` version
  to agree on either.
- **Dart dependencies with wide ranges:** `camera >=0.10.5 <0.12.0`,
  `sqflite >=2.2.0 <3.0.0`, `path >=1.8.0 <2.0.0`.
- **Flutter 3.22 or newer.** CI runs analysis and every test on 3.22.3 and on
  the current stable release.
- **minSdk 21.** The plugin does not raise your app's minimum; newer APIs are
  guarded at runtime.
- **Your Gradle, AGP and Kotlin versions are used.** The plugin builds with its
  JVM target set in a form that works from Kotlin 1.8 to 2.x.
- **Manifest:** adds `CAMERA`, `ACCESS_FINE_LOCATION`,
  `ACCESS_COARSE_LOCATION` and `INTERNET`. It deliberately adds **no**
  `<uses-feature android:required="true">`, which would hide your whole app on
  Google Play from devices without a camera or GPS.
- **Channels** are namespaced `com.fieldar.plot_finder/...`; the Android
  namespace is `com.fieldar.plotfinder.plugin`.

## Orientation

The AR screen locks to portrait while it is open: the overlay maths assumes
the screen frame the sensors are remapped into. Flutter cannot read back the
previous setting, so on close it applies `restoreOrientations`. The default,
an empty list, hands control back to your activity's manifest. If your app
calls `SystemChrome.setPreferredOrientations` itself, pass the same list here.

## iOS

`plotFinderSupported` is false on iOS and `PlotFinderScreen` shows an
"Android only" notice instead of failing. The package declares no iOS
implementation, so it adds nothing to your iOS build. Supporting iOS means a
Swift counterpart of `PlotFinderPlugin.kt`: CoreMotion attitude, the
AVCaptureDevice field of view, and CoreLocation course.

## Not verified yet

CI compiles the plugin inside the example app and runs every test, but nobody
has run it on a device. Before shipping it inside your app, check on a real
phone that the camera preview, the heading lock and the overlay behave.
