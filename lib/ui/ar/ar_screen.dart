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
import '../../platform/native_platform.dart';
import '../theme.dart';
import 'ar_controller.dart';
import 'ar_overlay_painter.dart';
import 'heading_chip.dart';
import 'minimap.dart';
import 'startup_loader.dart';

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
  const ArScreen({super.key, required this.container, this.plotId});

  final AppContainer container;
  /// The plot the view was opened from, if any. Every nearby plot is shown.
  final String? plotId;

  @override
  State<ArScreen> createState() => _ArScreenState();
}

enum _Backend { checking, arcore, sensors }

class _ArScreenState extends State<ArScreen> with WidgetsBindingObserver {
  ArController? _controller;
  _Backend _backend = _Backend.checking;

  /// ARCore could run here once Google Play Services for AR is installed.
  bool _arCoreInstallable = false;

  /// Latched once the first fix and first tracked frame are in: the startup
  /// loader is for opening the screen, not for every later dropout - those
  /// get the tracking banner, which says why.
  bool _ready = false;
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
    final controller = ArController(widget.container, focusPlotId: widget.plotId, visual: backend == _Backend.arcore);
    controller.visualFailed.addListener(_onVisualFailed);
    controller.start();
    setState(() {
      _backend = backend;
      _controller = controller;
      _measured = null;
      _ready = false;
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

  bool _isReady(ArUiState state) => _ready = _ready ||
      StartupLoader.done(hasFix: state.hasFix, usesTracking: state.visual, tracking: state.visualTracking);

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
            // Over the camera, under the chrome: the sheet stays usable while
            // the position comes in, and the card fades once it has.
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _isReady(state)
                    ? const SizedBox.shrink()
                    : StartupLoader(
                        hasFix: state.hasFix,
                        usesTracking: state.visual,
                        tracking: state.visualTracking,
                      ),
              ),
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
                  _ArAppBar(index: state.index, synthetic: state.synthetic),
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
                  _GuidePill(frame: controller.frame),
                  // The loader already says tracking is starting; the banner is
                  // for losing it later.
                  if (state.visual && !state.visualTracking && _ready)
                    _TrackingBanner(failure: state.trackingFailure)
                  else if (!arcore && _arCoreInstallable)
                    _InstallArCoreBanner(onInstall: _installArCore),
                ],
              ),
            ),
            // The minimap rides on top of the sheet, so it never hides behind
            // it and moves up and down as the sheet does.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.plots.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 12, bottom: 10),
                      child: PlotMinimap(
                        plots: state.plots,
                        health: state.health,
                        index: state.index,
                        frame: controller.frame,
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: _BottomSheet(
                      state: state,
                      onDismissMessage: controller.dismissMessage,
                      onSelectIndex: controller.setIndex,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grow's slate app bar, carried over the camera: what is being shown.
class _ArAppBar extends StatelessWidget {
  const _ArAppBar({required this.index, required this.synthetic});

  final HealthIndex index;
  final bool synthetic;

  @override
  Widget build(BuildContext context) => Material(
        color: GrowColors.primary,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, MediaQuery.paddingOf(context).top, 12, 0),
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Nearby plots',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500),
                      ),
                      Text(
                        '${index.label} · ${index.code}${synthetic ? ' · demo values' : ''}',
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

/// The sheet: which index the drop points show, what the colours mean, and
/// where the session is anchored. No buttons to press - the anchor is automatic.
class _BottomSheet extends StatelessWidget {
  const _BottomSheet({required this.state, required this.onDismissMessage, required this.onSelectIndex});

  final ArUiState state;
  final VoidCallback onDismissMessage;
  final ValueChanged<HealthIndex> onSelectIndex;

  @override
  Widget build(BuildContext context) {
    final message = state.message;
    final drops = state.patches.length;
    return Container(
      decoration: const BoxDecoration(
        color: PlotFinderColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message != null) ...[
            _MessageBanner(message: message, onDismiss: onDismissMessage),
            const SizedBox(height: 10),
          ],
          _IndexSwitch(selected: state.index, onSelect: onSelectIndex),
          const SizedBox(height: 10),
          Row(
            children: [
              const _ZoneDot(zone: zoneCritical),
              const SizedBox(width: 6),
              const Text('Critical', style: TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(width: 14),
              const _ZoneDot(zone: zoneModerate),
              const SizedBox(width: 6),
              const Text('Moderate', style: TextStyle(color: Colors.white, fontSize: 13)),
              const Spacer(),
              Text(
                state.health.isEmpty ? 'no crop data cached' : '$drops drop point${drops == 1 ? '' : 's'}',
                style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            state.snapped
                ? 'Anchored - crop condition shown on the ground'
                : 'Drop points only - ground colouring starts once anchored within 10 m of a boundary',
            style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Crop greenness, crop vigour, water stress - one at a time.
class _IndexSwitch extends StatelessWidget {
  const _IndexSwitch({required this.selected, required this.onSelect});

  final HealthIndex selected;
  final ValueChanged<HealthIndex> onSelect;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: PlotFinderColors.sheetRaised,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            for (final index in HealthIndex.values)
              Expanded(
                child: Semantics(
                  selected: index == selected,
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelect(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: index == selected ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        index.label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: index == selected ? GrowColors.primaryDark : Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

class _ZoneDot extends StatelessWidget {
  const _ZoneDot({required this.zone});

  final int zone;

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: Color(severityColour(zone).argb), shape: BoxShape.circle),
      );
}

/// Which way, and how far, to the nearest plot boundary - until the session
/// anchors to one.
class _GuidePill extends StatelessWidget {
  const _GuidePill({required this.frame});

  final ValueListenable<ArFrame?> frame;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ArFrame?>(
        valueListenable: frame,
        builder: (context, current, _) {
          final guide = current?.guide;
          if (guide == null) return const SizedBox.shrink();
          return Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: PlotFinderColors.scrim, borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.rotate(
                    angle: guide.relativeBearingDeg * math.pi / 180.0,
                    child: const Icon(Icons.navigation, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '${guide.plotName} boundary · ${guide.distanceM.round()} m',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
