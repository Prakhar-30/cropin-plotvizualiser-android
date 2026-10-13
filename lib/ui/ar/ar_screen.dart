import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../app_container.dart';
import '../../core/geo/camera_geometry.dart';
import '../../core/heading/heading_model.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../data/plot.dart';
import '../formatting.dart';
import '../theme.dart';
import 'ar_controller.dart';
import 'ar_overlay_painter.dart';
import 'heading_chip.dart';
import 'simulation_panel.dart';

/// Camera, overlay, heading chip, mode indicator, snap button.
///
/// The preview and the canvas share one box sized to the camera's own aspect
/// ratio. That is deliberate: a full-bleed preview would be cropped, and a
/// cropped preview shows a narrower field of view than the characteristics
/// report, which silently scales every projected point.
class ArScreen extends StatefulWidget {
  const ArScreen({super.key, required this.container, required this.plotId, required this.simulated});

  final AppContainer container;
  final String plotId;
  final bool simulated;

  @override
  State<ArScreen> createState() => _ArScreenState();
}

class _ArScreenState extends State<ArScreen> with WidgetsBindingObserver {
  late final ArController _controller;
  CameraController? _camera;
  CameraGeometry _geometry = CameraGeometry.fallback;
  bool _cameraStarting = false;
  (int, int, double)? _measured;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ArController(widget.container, widget.plotId, simulated: widget.simulated);
    _controller.start();
    unawaited(_startCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.stop();
    _controller.dispose();
    unawaited(_camera?.dispose());
    super.dispose();
  }

  /// The camera is released whenever the app leaves the foreground, as CameraX
  /// did when it was bound to the activity lifecycle - holding it would block
  /// every other app from the camera and drain the battery behind a lock screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _controller.pause();
    if (state == AppLifecycleState.resumed) _controller.resume();
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final camera = _camera;
      _camera = null;
      if (camera != null) {
        setState(() {});
        unawaited(camera.dispose());
      }
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      unawaited(_startCamera());
    }
  }

  Future<void> _startCamera() async {
    if (_cameraStarting) return;
    _cameraStarting = true;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('none', 'no camera on this device');
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await camera.initialize();
      final preview = camera.value.previewSize;
      final previewAspect =
          preview == null ? null : math.max(preview.width, preview.height) / math.min(preview.width, preview.height);
      final geometry = await widget.container.platform.cameraGeometry(previewAspect: previewAspect);
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() {
        _camera = camera;
        _geometry = geometry;
      });
    } on Object catch (e) {
      // No preview to draw on is survivable in simulation and on an emulator;
      // the overlay still draws against black with the fallback geometry.
      debugPrint('PlotFinder: camera unavailable ($e)');
    } finally {
      _cameraStarting = false;
    }
  }

  void _reportViewport(int width, int height) {
    final next = (width, height, _geometry.portraitHorizontalFovDeg);
    if (next == _measured) return;
    _measured = next;
    // After layout, never during it: the controller rebuilds the overlay and
    // notifies listeners synchronously.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.onViewportMeasured(width, height, next.$3);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<ArUiState>(
        valueListenable: _controller,
        builder: (context, state, _) => Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(builder: (context, constraints) {
                // Largest box with the camera's aspect ratio that fits the
                // screen, in whole logical pixels so the intrinsics describe
                // exactly the box the overlay is painted in.
                final aspect = _geometry.portraitAspect;
                final fittedW = math.min(constraints.maxWidth, constraints.maxHeight * aspect).floorToDouble();
                final fittedH = (fittedW / aspect).floorToDouble();
                _reportViewport(fittedW.toInt(), fittedH.toInt());
                return Center(
                  child: SizedBox(
                    width: fittedW,
                    height: fittedH,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _CameraBox(camera: _camera),
                        // Its own layer: the canvas repaints at sensor rate,
                        // and without the boundary each repaint would drag the
                        // camera texture and the chrome along with it.
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: ArOverlayPainter(
                              frame: _controller.frame,
                              plotId: state.plot?.id ?? '',
                              areaHectares: state.plot?.areaHectares ?? 0.0,
                              colourIndex: state.plot?.colourIndex ?? 0,
                              confidence: state.headingStatus?.confidence ?? HeadingConfidence.unreliable,
                              accuracyM: state.accuracyM,
                              devicePixelRatio: dpr,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
            // App bar, then chip and badge in one row so they cannot overlap:
            // at a large system font scale the chip's text grows into the
            // badge if both are absolutely positioned against opposite corners.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ArAppBar(plot: state.plot, simulated: widget.simulated),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (state.headingStatus != null) Flexible(child: HeadingChip(status: state.headingStatus!)),
                        const Spacer(),
                        _ModeBadge(state: state),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomSheet(
                state: state,
                onDismissMessage: _controller.dismissMessage,
                onSelectHealth: _controller.setHealthLayer,
                onSnap: _controller.snapToAccessPoint,
                simulation: _controller.simulation == null ? null : SimulationPanel(engine: _controller.simulation!),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grow's slate app bar, carried over the camera so the agent always sees
/// which plot they are looking for.
class _ArAppBar extends StatelessWidget {
  const _ArAppBar({required this.plot, required this.simulated});

  final Plot? plot;
  final bool simulated;

  @override
  Widget build(BuildContext context) {
    final plot = this.plot;
    return Material(
      color: GrowColors.primary,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, MediaQuery.paddingOf(context).top, 12, 0),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to plot details',
                color: Colors.white,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plot?.name ?? 'Finding plot',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500),
                    ),
                    if (plot != null)
                      Text(
                        '${plot.id} · ${formatHectares(plot.areaSqM)}',
                        style: const TextStyle(color: GrowColors.onPrimaryMuted, fontSize: 12),
                      ),
                  ],
                ),
              ),
              if (simulated)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: PlotFinderColors.warning, borderRadius: BorderRadius.circular(12)),
                  child: const Text(
                    'SIMULATION',
                    style: TextStyle(color: Color(0xFF1A1206), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Message, crop health, access point and snap, and the simulator in debug.
class _BottomSheet extends StatelessWidget {
  const _BottomSheet({
    required this.state,
    required this.onDismissMessage,
    required this.onSelectHealth,
    required this.onSnap,
    required this.simulation,
  });

  final ArUiState state;
  final VoidCallback onDismissMessage;
  final ValueChanged<HealthLayer> onSelectHealth;
  final VoidCallback onSnap;
  final Widget? simulation;

  @override
  Widget build(BuildContext context) {
    final plot = state.plot;
    final message = state.message;
    final simulation = this.simulation;
    if (plot == null && message == null && simulation == null) return const SizedBox.shrink();
    final landmark = plot?.landmarkNote.trim() ?? '';
    return Container(
      decoration: const BoxDecoration(
        color: PlotFinderColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(16, 10, 16, 16 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: const Color(0xFF3A4A53), borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 12),
          if (message != null) ...[
            _MessageBanner(message: message, onDismiss: onDismissMessage),
            const SizedBox(height: 12),
          ],
          if (plot != null) ...[
            _HealthControls(state: state, onSelect: onSelectHealth),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1, color: PlotFinderColors.sheetDivider),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(color: Color(0x2EF59E0B), shape: BoxShape.circle),
                  child: const Icon(Icons.flag_outlined, size: 16, color: PlotFinderColors.warning),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Access point', style: TextStyle(color: PlotFinderColors.mutedText, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text(
                        landmark.isEmpty ? 'no landmark note recorded' : landmark,
                        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.43),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: cameraPrimaryButtonStyle(),
              onPressed: onSnap,
              icon: const Icon(Icons.gps_fixed, size: 18),
              label: const Text('Aim at it and tap to pin heading'),
            ),
          ],
          if (simulation != null) ...[
            const SizedBox(height: 12),
            simulation,
          ],
        ],
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(color: PlotFinderColors.sheetRaised, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18, color: PlotFinderColors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.38)),
            ),
            TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      );
}

/// The live preview, filling a box already sized to its aspect ratio so
/// nothing is cropped.
class _CameraBox extends StatelessWidget {
  const _CameraBox({required this.camera});

  final CameraController? camera;

  @override
  Widget build(BuildContext context) {
    final camera = this.camera;
    final preview = camera?.value.previewSize;
    if (camera == null || !camera.value.isInitialized || preview == null) {
      return const ColoredBox(color: Colors.black);
    }
    // previewSize is reported landscape; upright, its sides swap.
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: math.min(preview.width, preview.height),
          height: math.max(preview.width, preview.height),
          child: CameraPreview(camera),
        ),
      ),
    );
  }
}

/// Which render mode is live, and how far the nearest edge is.
class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.state});

  final ArUiState state;

  @override
  Widget build(BuildContext context) {
    final mode = state.mode;
    if (mode == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: PlotFinderColors.scrim, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: mode == RenderMode.far ? PlotFinderColors.sheetRaised : Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              mode == RenderMode.far ? 'FAR' : 'NEAR',
              style: TextStyle(
                color: mode == RenderMode.far ? Colors.white : GrowColors.primaryDark,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${state.edgeDistanceM} m to edge',
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          if (!state.hasFix)
            const Text(
              'waiting for GNSS',
              style: TextStyle(color: PlotFinderColors.warning, fontSize: 12, fontWeight: FontWeight.w500),
            ),
        ],
      ),
    );
  }
}

/// The crop-health switch, its legend, and every caveat attached to it.
///
/// The caveats are not decoration. This overlay paints ground brown and tells a
/// field agent to walk there, and there are three separate ways it can be saying
/// something it does not know: the values may be synthetic rather than measured,
/// the heading may be too poor to place them, or the raster may simply not be
/// cached. Each of those has to be visible at the moment the colour is, because
/// a confident-looking overlay is believed.
class _HealthControls extends StatelessWidget {
  const _HealthControls({required this.state, required this.onSelect});

  final ArUiState state;
  final ValueChanged<HealthLayer> onSelect;

  @override
  Widget build(BuildContext context) {
    final health = state.health;
    final caveats = <Widget>[];
    if (state.healthSyncing) {
      caveats.add(const _Caveat(Icons.downloading, 'Fetching health...', PlotFinderColors.mutedText));
    } else if (state.healthLayer == HealthLayer.off) {
      caveats.add(const _Caveat(Icons.visibility_off_outlined, 'Crop health hidden', PlotFinderColors.faintText));
    } else if (health == null) {
      caveats.add(const _Caveat(
        Icons.cloud_off_outlined,
        'No raster cached - tap Sync on the plot list',
        PlotFinderColors.warning,
      ));
    } else if (state.healthVetoed) {
      // The veto, spelled out. "Nothing is drawn" and "nothing is wrong" look
      // identical on a camera feed, so the reason has to be stated or the agent
      // will read an empty field as a healthy one.
      caveats.add(const _Caveat(
        Icons.visibility_off_outlined,
        'Health hidden until heading is trusted - pin it below',
        PlotFinderColors.warning,
      ));
    }
    if (health != null && state.healthLayer != HealthLayer.off && health.synthetic) {
      // The server's own wording, not a second copy of it written here.
      caveats.add(_Caveat(
        Icons.warning_amber_rounded,
        health.note.trim().isEmpty ? 'Synthetic values - not measured imagery' : health.note,
        PlotFinderColors.warning,
      ));
    }
    final showing = state.healthLayer != HealthLayer.off && health != null && !state.healthVetoed;
    final patches = health?.hotspots.length ?? 0;
    final hidden = state.hiddenCellCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Crop health', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            if (health != null)
              Text(
                '${health.indexName.toUpperCase()} · ${health.capturedOn}',
                style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _LayerSwitch(selected: state.healthLayer, onSelect: onSelect),
        if (showing && health != null) ...[
          const SizedBox(height: 10),
          Text(
            '$patches patch${patches == 1 ? '' : 'es'} · ${formatHectares(health.stressedAreaSqM)} stressed',
            style: const TextStyle(color: PlotFinderColors.onSurface, fontSize: 13),
          ),
          _SeverityLegend(minSeverity: state.healthLayer.minSeverity),
          // Says out loud that healthy ground is being withheld. An agent who
          // does not know the filter is on reads bare ground between two brown
          // patches as unsurveyed.
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$hidden healthy cells hidden - choose All cells to show them',
                style: const TextStyle(color: PlotFinderColors.faintText, fontSize: 12),
              ),
            ),
        ],
        for (final caveat in caveats) Padding(padding: const EdgeInsets.only(top: 8), child: caveat),
      ],
    );
  }
}

/// Off / Problem areas / All cells as one segmented control, so the agent
/// picks the layer instead of cycling past the one they want.
class _LayerSwitch extends StatelessWidget {
  const _LayerSwitch({required this.selected, required this.onSelect});

  final HealthLayer selected;
  final ValueChanged<HealthLayer> onSelect;

  static String _label(HealthLayer layer) => switch (layer) {
        HealthLayer.off => 'Off',
        HealthLayer.stress => 'Problem areas',
        HealthLayer.all => 'All cells',
      };

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: PlotFinderColors.sheetRaised, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            for (final layer in HealthLayer.values)
              Expanded(
                child: Semantics(
                  selected: layer == selected,
                  button: true,
                  child: TextButton(
                    onPressed: () => onSelect(layer),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      backgroundColor: layer == selected ? Colors.white : Colors.transparent,
                      foregroundColor: layer == selected ? GrowColors.primaryDark : PlotFinderColors.mutedText,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: TextStyle(
                        fontSize: 13,
                        fontWeight: layer == selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    child: Text(_label(layer), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
          ],
        ),
      );
}

class _Caveat extends StatelessWidget {
  const _Caveat(this.icon, this.text, this.colour);

  final IconData icon;
  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: colour)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: colour, fontSize: 12, height: 1.4))),
        ],
      );
}

/// The colour key, showing only the bands this layer actually draws.
///
/// Listing a band that is currently hidden would have the agent hunting the
/// field for a green that is not on screen.
class _SeverityLegend extends StatelessWidget {
  const _SeverityLegend({required this.minSeverity});

  final int minSeverity;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final band in severityColours)
              if (band.level >= minSeverity)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: Color(band.argb), borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(width: 6),
                    Text(band.label, style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12)),
                  ],
                ),
          ],
        ),
      );
}
