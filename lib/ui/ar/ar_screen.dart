import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../app_container.dart';
import '../../core/geo/arcore_pose.dart';
import '../../core/geo/camera_geometry.dart';
import '../../core/heading/heading_model.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../data/plot.dart';
import '../../platform/native_platform.dart';
import '../formatting.dart';
import '../theme.dart';
import 'ar_controller.dart';
import 'ar_overlay_painter.dart';
import 'heading_chip.dart';

/// Camera, overlay, heading chip, mode indicator, snap button.
///
/// Two ways to run, chosen when the screen opens:
///
///  - **ARCore** where Google Play Services for AR is installed. ARCore owns
///    the camera, draws the preview full-screen and tracks the phone through
///    space from the image and the IMU, so the overlay stays where it belongs
///    as the agent walks. Its projection reports the field of view the preview
///    is really shown with, so full-bleed is safe.
///  - **Sensors** everywhere else: the camera plugin's preview and the rotation
///    sensors plus counted steps. Here the preview and the canvas share one box
///    sized to the camera's own aspect ratio, because a cropped preview shows a
///    narrower field of view than the characteristics report, which would
///    silently scale every projected point.
class ArScreen extends StatefulWidget {
  const ArScreen({super.key, required this.container, required this.plotId});

  final AppContainer container;
  final String plotId;

  @override
  State<ArScreen> createState() => _ArScreenState();
}

enum _Backend { checking, arcore, sensors }

class _ArScreenState extends State<ArScreen> with WidgetsBindingObserver {
  ArController? _controller;
  _Backend _backend = _Backend.checking;

  /// ARCore could run here once Google Play Services for AR is installed.
  bool _arCoreInstallable = false;
  CameraController? _camera;
  CameraGeometry _geometry = CameraGeometry.fallback;
  bool _cameraStarting = false;
  (int, int, double)? _measured;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Portrait while this screen is open, and only while it is. The overlay
    // maths assumes the screen frame the sensor matrix is remapped into; the
    // rest of the host app keeps whatever orientations it allows.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    unawaited(_chooseBackend());
  }

  Future<void> _chooseBackend() async {
    final availability = await widget.container.platform.arCoreAvailability();
    if (!mounted) return;
    _arCoreInstallable = availability == 'not_installed';
    _open(availability == 'supported' ? _Backend.arcore : _Backend.sensors);
  }

  void _open(_Backend backend) {
    final controller = ArController(widget.container, widget.plotId, visual: backend == _Backend.arcore);
    controller.visualFailed.addListener(_onVisualFailed);
    controller.start();
    setState(() {
      _backend = backend;
      _controller = controller;
      _measured = null;
    });
    if (backend == _Backend.sensors) unawaited(_startCamera());
  }

  /// ARCore could not run after all - the session would not open, or never
  /// produced a frame. Rather than leave the agent at a black screen, restart
  /// on the sensors.
  void _onVisualFailed() {
    final failed = _controller;
    if (failed == null || !failed.visualFailed.value || _backend != _Backend.arcore) return;
    // Not from inside the notification: the controller being closed owns the
    // notifier that is calling us.
    scheduleMicrotask(() {
      if (!mounted || !identical(failed, _controller)) return;
      _closeController();
      // The platform view leaves the tree on this rebuild, which releases
      // ARCore's hold on the camera before the camera plugin asks for it.
      setState(() => _backend = _Backend.checking);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(_Backend.sensors);
      });
    });
  }

  void _closeController() {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.visualFailed.removeListener(_onVisualFailed);
    controller.stop();
    controller.dispose();
  }

  Future<void> _installArCore() async {
    final answer = await widget.container.platform.arInstall();
    if (!mounted || answer == 'failed') return;
    // The Play Store opens on top; reopening the AR screen afterwards picks
    // the new install up.
    setState(() => _arCoreInstallable = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(widget.container.config.restoreOrientations);
    _closeController();
    unawaited(_camera?.dispose());
    super.dispose();
  }

  /// The camera is released whenever the app leaves the foreground, as CameraX
  /// did when it was bound to the activity lifecycle - holding it would block
  /// every other app from the camera and drain the battery behind a lock screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _controller?.pause();
    if (state == AppLifecycleState.resumed) _controller?.resume();
    // ARCore's camera is paused and resumed with the controller.
    if (_backend != _Backend.sensors) return;
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
      // No preview to draw on is survivable, on an emulator for instance;
      // the overlay still draws against black with the fallback geometry.
      debugPrint('PlotFinder: camera unavailable ($e)');
    } finally {
      _cameraStarting = false;
    }
  }

  void _reportViewport(ArController controller, int width, int height) {
    final next = (width, height, _geometry.portraitHorizontalFovDeg);
    if (next == _measured) return;
    _measured = next;
    // After layout, never during it: the controller rebuilds the overlay and
    // notifies listeners synchronously.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(controller, _controller)) controller.onViewportMeasured(width, height, next.$3);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final arcore = _backend == _Backend.arcore;
    return Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<ArUiState>(
        valueListenable: controller,
        builder: (context, state, _) => Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(builder: (context, constraints) {
                // ARCore: the whole screen. Sensors: the largest box with the
                // camera's aspect ratio that fits. Either way in whole logical
                // pixels, so the intrinsics describe exactly the box the
                // overlay is painted in.
                final double boxW;
                final double boxH;
                if (arcore) {
                  boxW = constraints.maxWidth.floorToDouble();
                  boxH = constraints.maxHeight.floorToDouble();
                } else {
                  final aspect = _geometry.portraitAspect;
                  boxW = math.min(constraints.maxWidth, constraints.maxHeight * aspect).floorToDouble();
                  boxH = (boxW / aspect).floorToDouble();
                }
                _reportViewport(controller, boxW.toInt(), boxH.toInt());
                return Center(
                  child: SizedBox(
                    width: boxW,
                    height: boxH,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (arcore) const _ArCoreBox() else _CameraBox(camera: _camera),
                        // Its own layer: the canvas repaints at sensor rate,
                        // and without the boundary each repaint would drag the
                        // camera texture and the chrome along with it.
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: ArOverlayPainter(
                              frame: controller.frame,
                              plotId: state.plot?.id ?? '',
                              areaHectares: state.plot?.areaHectares ?? 0.0,
                              colourIndex: state.plot?.colourIndex ?? 0,
                              confidence: state.headingStatus?.confidence ?? HeadingConfidence.unreliable,
                              accuracyM: state.accuracyM,
                              devicePixelRatio: dpr,
                              drawGeometry: !arcore,
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
                  _ArAppBar(plot: state.plot),
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
                  if (state.visual && !state.visualTracking)
                    _TrackingBanner(failure: state.trackingFailure)
                  else if (!arcore && _arCoreInstallable)
                    _InstallArCoreBanner(onInstall: _installArCore),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomSheet(
                state: state,
                onDismissMessage: controller.dismissMessage,
                onSelectHealth: controller.setHealthLayer,
                onSnap: controller.snapToAccessPoint,
                onPin: controller.pinToAccessPoint,
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
  const _ArAppBar({required this.plot});

  final Plot? plot;

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
            ],
          ),
        ),
      ),
    );
  }
}

/// Message, the two positioning actions, crop health - collapsible.
///
/// The two actions - aim at the access point to lock the heading, stand on it
/// to fix the position - sit side by side and stay visible when the sheet is
/// collapsed: they are what the agent reaches for while walking, and the
/// collapsed sheet is how they walk. Expanding adds the health layer and the
/// access point's note, nothing more.
class _BottomSheet extends StatefulWidget {
  const _BottomSheet({
    required this.state,
    required this.onDismissMessage,
    required this.onSelectHealth,
    required this.onSnap,
    required this.onPin,
  });

  final ArUiState state;
  final VoidCallback onDismissMessage;
  final ValueChanged<HealthLayer> onSelectHealth;
  final VoidCallback onSnap;
  final VoidCallback onPin;

  @override
  State<_BottomSheet> createState() => _BottomSheetState();
}

class _BottomSheetState extends State<_BottomSheet> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 100) return;
    setState(() => _expanded = velocity < 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final plot = state.plot;
    final message = state.message;
    if (plot == null && message == null) return const SizedBox.shrink();
    final landmark = plot?.landmarkNote.trim() ?? '';
    return Container(
      decoration: const BoxDecoration(
        color: PlotFinderColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.paddingOf(context).bottom),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.bottomCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetHandle(expanded: _expanded, onTap: _toggle, onDragEnd: _onDragEnd),
            if (message != null) ...[
              _MessageBanner(message: message, onDismiss: widget.onDismissMessage),
              const SizedBox(height: 10),
            ],
            if (plot != null) _Actions(pinned: state.pinned, onSnap: widget.onSnap, onPin: widget.onPin),
            if (plot != null && _expanded) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1, color: PlotFinderColors.sheetDivider),
              ),
              _HealthControls(state: state, onSelect: widget.onSelectHealth),
              if (landmark.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.flag_outlined, size: 16, color: PlotFinderColors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        landmark,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Aim and lock the heading; stand here and fix the position.
class _Actions extends StatelessWidget {
  const _Actions({required this.pinned, required this.onSnap, required this.onPin});

  final bool pinned;
  final VoidCallback onSnap;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Tooltip(
              message: 'Put the crosshair on the access point, then tap',
              child: FilledButton.icon(
                style: cameraPrimaryButtonStyle(),
                onPressed: onSnap,
                icon: const Icon(Icons.gps_fixed, size: 18),
                label: const Text('Aim & lock'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Tooltip(
              message: 'Tap while standing on the access point',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: pinned ? PlotFinderColors.warning : PlotFinderColors.sheetDivider),
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                onPressed: onPin,
                icon: Icon(pinned ? Icons.where_to_vote : Icons.my_location, size: 18),
                label: Text(pinned ? 'Pinned' : "I'm here"),
              ),
            ),
          ),
        ],
      );
}

/// The grab handle. The whole strip is the hit target, not the 36 px bar: a
/// field agent is holding the phone up with one hand, often in gloves or the
/// sun.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle({required this.expanded, required this.onTap, required this.onDragEnd});

  final bool expanded;
  final VoidCallback onTap;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: expanded ? 'Collapse panel' : 'Show crop health',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onVerticalDragEnd: onDragEnd,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 10),
            child: Center(
              child: Icon(
                expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                color: PlotFinderColors.mutedText,
                size: 22,
              ),
            ),
          ),
        ),
      );
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

/// ARCore's camera preview, drawn natively and composited under the overlay.
///
/// Hybrid composition: the GLSurfaceView sits in the Android view hierarchy
/// and Flutter draws above it, which is what a SurfaceView needs to show at
/// all, and keeps the camera image at full rate however busy the canvas is.
class _ArCoreBox extends StatelessWidget {
  const _ArCoreBox();

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) return const ColoredBox(color: Colors.black);
    return PlatformViewLink(
      viewType: NativePlatform.arViewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) => PlatformViewsService.initExpensiveAndroidView(
        id: params.id,
        viewType: NativePlatform.arViewType,
        layoutDirection: TextDirection.ltr,
        creationParamsCodec: const StandardMessageCodec(),
      )
        ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
        ..create(),
    );
  }
}

/// Shown while ARCore has lost tracking, with what to do about it.
class _TrackingBanner extends StatelessWidget {
  const _TrackingBanner({required this.failure});

  final ArTrackingFailure failure;

  String get _advice => switch (failure) {
        ArTrackingFailure.insufficientLight => 'Too dark to track',
        ArTrackingFailure.excessiveMotion => 'Slow down',
        ArTrackingFailure.insufficientFeatures => 'Point at the ground or textured objects',
        ArTrackingFailure.cameraUnavailable => 'Camera in use by another app',
        _ => 'Move the phone slowly side to side',
      };

  @override
  Widget build(BuildContext context) => _Banner(icon: Icons.motion_photos_paused, text: _advice);
}

class _InstallArCoreBanner extends StatelessWidget {
  const _InstallArCoreBanner({required this.onInstall});

  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) => _Banner(
        icon: Icons.view_in_ar,
        text: 'Install AR services to lock the overlay in place',
        action: TextButton(
          onPressed: onInstall,
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          child: const Text('Install'),
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Container(
          padding: EdgeInsets.fromLTRB(12, 8, action == null ? 12 : 4, 8),
          decoration: BoxDecoration(color: PlotFinderColors.sheet, borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              Icon(icon, size: 18, color: PlotFinderColors.warning),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.38))),
              if (action case final action?) action,
            ],
          ),
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
          if (state.depthActive)
            const Text(
              'occlusion on',
              style: TextStyle(color: PlotFinderColors.mutedText, fontSize: 12),
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
        if (showing) ...[
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
