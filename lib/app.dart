import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_container.dart';
import 'ui/ar/ar_screen.dart';
import 'ui/detail/plot_detail_screen.dart';
import 'ui/plots/plot_list_controller.dart';
import 'ui/plots/plot_list_screen.dart';
import 'ui/theme.dart';

class PlotFinderApp extends StatelessWidget {
  const PlotFinderApp({super.key, required this.container});

  final AppContainer container;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Plot Finder',
        debugShowCheckedModeBanner: false,
        theme: plotFinderTheme(),
        home: PermissionGate(child: _Home(container: container)),
      );
}

/// Camera and location are both hard requirements: without them there is no
/// preview to draw on and nothing to anchor the local frame to. Asking once at
/// the top keeps every screen below free of permission branches.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key, required this.child});

  final Widget child;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  static const List<Permission> _required = [Permission.camera, Permission.locationWhenInUse];

  bool? _granted;

  @override
  void initState() {
    super.initState();
    _request();
  }

  Future<void> _request() async {
    final results = await _required.request();
    if (!mounted) return;
    setState(() => _granted = results.values.every((s) => s.isGranted));
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    if (granted == null) return const Scaffold();
    if (granted) return widget.child;

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: Padding(
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
              const TextButton(onPressed: openAppSettings, child: Text('Open app settings')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Owns the plot list controller for the life of the app, so the list - and
/// its location fix - survive a trip into AR and back.
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

  void _openPlot(String plotId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => ValueListenableBuilder(
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ArScreen(container: widget.container, plotId: plotId, simulated: simulated),
    ));
  }

  @override
  Widget build(BuildContext context) => PlotListScreen(controller: _list, onOpenPlot: _openPlot);
}
