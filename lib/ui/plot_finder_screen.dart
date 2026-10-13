import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_container.dart';
import '../config.dart';
import '../platform/native_platform.dart';
import 'ar/ar_screen.dart';
import 'detail/plot_detail_screen.dart';
import 'plots/plot_list_controller.dart';
import 'plots/plot_list_screen.dart';
import 'theme.dart';

/// Whether the plot finder can run on this device.
///
/// The sensor, camera and location plumbing exists for Android only. On any
/// other platform [PlotFinderScreen] shows a notice instead of failing, but a
/// host app would usually rather not offer the entry point at all.
bool get plotFinderSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The whole feature behind one widget: plot list, plot detail and AR view.
///
/// Push it from anywhere in a host app's navigator. It opens its own cache and
/// HTTP client when shown and releases them when popped, wraps its pages in its
/// own dark theme so the host theme cannot wash the overlay out, and asks for
/// camera and location itself.
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
      data: plotFinderTheme(),
      child: container == null
          ? const _Notice('Plot Finder is available on Android only.')
          : FutureBuilder<AppContainer>(
              future: container,
              builder: (context, snapshot) {
                if (snapshot.hasError) return _Notice('Plot Finder could not start: ${snapshot.error}');
                final ready = snapshot.data;
                if (ready == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
                return PermissionGate(platform: ready.platform, child: _Home(container: ready));
              },
            ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
      );
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
    if (granted == null) return const Scaffold();
    if (granted) return widget.child;

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Plot Finder needs the camera and your location'),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The camera is the view the boundary is drawn on, and the location '
                'anchors it to the ground. Neither leaves the device.',
                style: TextStyle(color: muted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: FilledButton(onPressed: _request, child: const Text('Grant permissions')),
            ),
            // Once Android stops showing the dialog, the setting is the only
            // way back.
            TextButton(onPressed: widget.platform.openAppSettings, child: const Text('Open app settings')),
          ],
        ),
      ),
    );
  }
}

/// Owns the plot list controller for as long as the feature is open, so the
/// list - and its location fix - survive a trip into AR and back.
class _Home extends StatefulWidget {
  const _Home({required this.container});

  final AppContainer container;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final PlotListController _list = PlotListController(widget.container);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _list.pause, onShow: _list.resume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _list.dispose();
    super.dispose();
  }

  /// Pages are pushed on the host's navigator, so system back behaves as the
  /// host expects; each one carries the feature's own theme, because a pushed
  /// route is built under the navigator, not under [PlotFinderScreen].
  Route<void> _route(WidgetBuilder builder) => MaterialPageRoute<void>(
        builder: (context) => Theme(data: plotFinderTheme(), child: Builder(builder: builder)),
      );

  void _openPlot(String plotId) {
    Navigator.of(context).push(_route(
      (context) => ValueListenableBuilder<PlotListState>(
        valueListenable: _list,
        builder: (context, _, __) {
          final item = _list.itemFor(plotId);
          return PlotDetailScreen(
            plot: item?.plot,
            distanceM: item?.distanceM,
            simulationAvailable: widget.container.simulationAvailable,
            onFindPlot: (simulated) => _openAr(plotId, simulated),
          );
        },
      ),
    ));
  }

  void _openAr(String plotId, bool simulated) {
    Navigator.of(context).push(_route(
      (_) => ArScreen(container: widget.container, plotId: plotId, simulated: simulated),
    ));
  }

  @override
  Widget build(BuildContext context) => PlotListScreen(controller: _list, onOpenPlot: _openPlot);
}
