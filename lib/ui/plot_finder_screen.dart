import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_container.dart';
import '../config.dart';
import '../platform/native_platform.dart';
import 'ar/ar_screen.dart';
import 'home/home_screen.dart';
import 'permission_screen.dart';
import 'plots/plot_list_controller.dart';
import 'status_screen.dart';
import 'theme.dart';

/// Whether the plot finder can run on this device.
///
/// The sensor, camera and location plumbing exists for Android only. On any
/// other platform [PlotFinderScreen] shows a notice instead of failing, but a
/// host app would usually rather not offer the entry point at all.
bool get plotFinderSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The whole feature behind one widget: a home screen to sync, and the AR view.
///
/// Push it from anywhere in a host app's navigator. It opens its own cache and
/// HTTP client when shown and releases them when popped, and asks for camera
/// and location itself. Its pages carry their own themes - the Cropin Grow
/// look for the planning screens, dark for the AR view - so neither depends on
/// how the host app is themed.
class PlotFinderScreen extends StatefulWidget {
  const PlotFinderScreen({super.key, this.config = const PlotFinderConfig()});

  final PlotFinderConfig config;

  @override
  State<PlotFinderScreen> createState() => _PlotFinderScreenState();
}

class _PlotFinderScreenState extends State<PlotFinderScreen> {
  Future<AppContainer>? _container;

  @override
  void initState() {
    super.initState();
    if (plotFinderSupported) _container = AppContainer.create(widget.config);
  }

  @override
  void dispose() {
    _container?.then((c) => c.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final container = _container;
    return Theme(
      data: growTheme(),
      child: container == null
          ? const StatusScreen.notice(
              title: 'Available on Android only',
              detail: 'Plot Finder uses Android sensors and the camera to find a plot on the ground.',
              icon: Icons.phone_android,
            )
          : FutureBuilder<AppContainer>(
              future: container,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return StatusScreen.notice(
                    title: 'Plot Finder could not start',
                    detail: '${snapshot.error}',
                    icon: Icons.error_outline,
                  );
                }
                final ready = snapshot.data;
                if (ready == null) return const StatusScreen.loading(title: 'Opening offline plots…');
                return PermissionGate(platform: ready.platform, child: _Home(container: ready));
              },
            ),
    );
  }
}

/// Camera and location are both hard requirements: without them there is no
/// preview to draw on and nothing to anchor the local frame to. Asking once at
/// the top keeps every screen below free of permission branches.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key, required this.platform, required this.child});

  final NativePlatform platform;
  final Widget child;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _request();
  }

  Future<void> _request() async {
    final granted = await widget.platform.requestPermissions();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    if (granted == null) return const StatusScreen.loading(title: 'Checking camera and location access…');
    if (granted) return widget.child;

    // Once Android stops showing the dialog, the setting is the only way back.
    return PermissionScreen(onGrant: _request, onOpenSettings: widget.platform.openAppSettings);
  }
}

/// Owns the cached plots and their sync for as long as the feature is open,
/// so the location fix and any sync in flight survive a trip into AR and back.
class _Home extends StatefulWidget {
  const _Home({required this.container});

  final AppContainer container;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final PlotListController _plots = PlotListController(widget.container);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _plots.pause, onShow: _plots.resume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _plots.dispose();
    super.dispose();
  }

  void _openAr() {
    // Pushed on the host's navigator, so system back behaves as the host
    // expects. The AR view stays dark whatever the rest of the app uses: light
    // chrome over a daylight camera feed washes the overlay out.
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Theme(
        data: plotFinderTheme(),
        child: ArScreen(container: widget.container),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlotListState>(
        valueListenable: _plots,
        builder: (context, state, _) => HomeScreen(state: state, onSync: _plots.sync, onStart: _openAr),
      );
}
