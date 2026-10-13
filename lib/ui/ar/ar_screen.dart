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
            // Chip and badge share one row so they cannot overlap: at a large
            // system font scale the chip's text grows into the badge if both are
            // absolutely positioned against opposite corners.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
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
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.message != null)
                      Container(
                        color: PlotFinderColors.scrim,
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(state.message!, style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ),
                            TextButton(onPressed: _controller.dismissMessage, child: const Text('Dismiss')),
                          ],
                        ),
                      ),
                    if (state.plot != null)
                      Container(
                        width: double.infinity,
                        color: PlotFinderColors.scrim,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _HealthControls(state: state, onCycleHealth: _controller.cycleHealthLayer),
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                'Access point: ${state.plot!.landmarkNote.trim().isEmpty ? 'no landmark note recorded' : state.plot!.landmarkNote}',
                                style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: FilledButton(
                                onPressed: _controller.snapToAccessPoint,
                                child: const Text('Aim at it and tap to pin heading'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_controller.simulation != null) SimulationPanel(engine: _controller.simulation!),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
      color: PlotFinderColors.scrim,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            mode == RenderMode.far ? 'FAR' : 'NEAR',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          Text(
            '${state.edgeDistanceM} m to edge',
            style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 11),
          ),
          if (!state.hasFix)
            const Text('waiting for GNSS', style: TextStyle(color: PlotFinderColors.warning, fontSize: 11)),
        ],
      ),
    );
  }
}

/// The crop-health toggle, its legend, and every caveat attached to it.
///
/// The caveats are not decoration. This overlay paints ground brown and tells a
/// field agent to walk there, and there are three separate ways it can be saying
/// something it does not know: the values may be synthetic rather than measured,
/// the heading may be too poor to place them, or the raster may simply not be
/// cached. Each of those has to be visible at the moment the colour is, because
/// a confident-looking overlay is believed.
class _HealthControls extends StatelessWidget {
  const _HealthControls({required this.state, required this.onCycleHealth});

  final ArUiState state;
  final VoidCallback onCycleHealth;

  @override
  Widget build(BuildContext context) {
    final health = state.health;
    final Widget status;
    if (state.healthLayer == HealthLayer.off) {
      status = const Text('Crop health hidden', style: TextStyle(color: PlotFinderColors.faintText, fontSize: 11));
    } else if (health == null) {
      status = const Text(
        'No raster cached - tap Sync on the plot list',
        style: TextStyle(color: PlotFinderColors.warning, fontSize: 11),
      );
    } else if (state.healthVetoed) {
      // The veto, spelled out. "Nothing is drawn" and "nothing is wrong" look
      // identical on a camera feed, so the reason has to be stated or the agent
      // will read an empty field as a healthy one.
      status = const Text(
        'Health hidden until heading is trusted - pin it below',
        style: TextStyle(color: PlotFinderColors.warning, fontSize: 11),
      );
    } else {
      final patches = health.hotspots.length;
      final hidden = state.hiddenCellCount;
      status = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${health.indexName.toUpperCase()} ${health.capturedOn} · '
            '$patches patch${patches == 1 ? '' : 'es'} · '
            '${formatHectares(health.stressedAreaSqM)} stressed',
            style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 11),
          ),
          // Says out loud that healthy ground is being withheld. An agent who
          // does not know the filter is on reads bare ground between two brown
          // patches as unsurveyed.
          if (hidden > 0)
            Text(
              '$hidden healthy cells hidden - tap for all',
              style: const TextStyle(color: PlotFinderColors.faintText, fontSize: 10),
            ),
          // The server's own wording, not a second copy of it written here.
          if (health.synthetic)
            Text(
              health.note.trim().isEmpty ? 'Synthetic values - not measured imagery' : health.note,
              style: const TextStyle(color: PlotFinderColors.warning, fontSize: 10),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            OutlinedButton(
              onPressed: onCycleHealth,
              child: Text(
                state.healthSyncing ? 'Fetching health...' : state.healthLayer.label,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: status),
          ],
        ),
        if (state.healthLayer != HealthLayer.off && health != null && !state.healthVetoed)
          _SeverityLegend(minSeverity: state.healthLayer.minSeverity),
      ],
    );
  }
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
          spacing: 12,
          children: [
            for (final band in severityColours)
              if (band.level >= minSeverity)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 11, height: 11, color: Color(band.argb)),
                    const SizedBox(width: 5),
                    Text(band.label, style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 10)),
                  ],
                ),
          ],
        ),
      );
}
