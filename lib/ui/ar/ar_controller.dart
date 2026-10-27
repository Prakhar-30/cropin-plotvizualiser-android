import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../app_container.dart';
import '../../core/geo/arcore_pose.dart';
import '../../core/geo/boundary_snap.dart';
import '../../core/geo/enu.dart';
import '../../core/geo/position_stabilizer.dart';
import '../../core/geo/projection.dart';
import '../../core/heading/course_over_ground_detector.dart';
import '../../core/heading/heading_model.dart';
import '../../core/heading/trajectory_aligner.dart';
import '../../core/math_util.dart';
import '../../core/motion/step_calibrator.dart';
import '../../core/motion/step_detector.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../core/render/world_scene.dart';
import '../../data/db/entities.dart';
import '../../data/plot.dart';
import '../../pose/pose_source.dart';
import '../../pose/vio_pose_source.dart';

/// Plots whose nearest edge is within this are drawn. Beyond it a boundary is
/// a sliver on the horizon and the minimap is the better guide.
const double plotViewRangeM = 400.0;

/// At most this many plots are drawn at once, nearest first.
const int maxDrawnPlots = 24;

/// The furthest the pinch zoom goes. Past this a phone camera's image is mush.
const double maxZoom = 5.0;

/// The horizontal field of view after a digital zoom of [zoom] about the centre.
double zoomedFovDeg(double horizontalFovDeg, double zoom) =>
    toDegrees(2.0 * math.atan(math.tan(toRadians(horizontalFovDeg) / 2.0) / zoom));

/// One plot as drawn this frame.
class DrawnPlot {
  const DrawnPlot(this.plot, this.overlay);

  final Plot plot;
  final PlotOverlay overlay;
}

/// What the overlay canvas draws for one pose sample.
///
/// Kept out of [ArUiState] on purpose: frames arrive at sensor rate and only
/// the canvas and the minimap marker need them.
class ArFrame {
  const ArFrame({
    this.plots = const [],
    this.drops = const [],
    this.cells = const [],
    this.guide,
    this.agent,
    this.headingDeg = 0.0,
  });

  /// Every nearby plot, nearest first. On the sensor path the canvas draws
  /// them; on the ARCore path only their labels.
  final List<DrawnPlot> plots;

  /// Drop points, projected - sensor path only; ARCore draws its own.
  final List<DropMarker> drops;

  /// Moderate and critical ground cells, projected - sensor path only.
  final List<CellPolygon> cells;

  /// The way to the nearest boundary, until the session has snapped to one.
  final BoundaryGuide? guide;

  /// Where the agent is drawn from, and which way the camera faces.
  final LatLng? agent;
  final double headingDeg;
}

/// How far, and which way, to the nearest plot boundary.
class BoundaryGuide {
  const BoundaryGuide(this.distanceM, this.relativeBearingDeg, this.plotName);

  final double distanceM;

  /// Negative is to the left of where the camera points.
  final double relativeBearingDeg;
  final String plotName;
}

/// Everything on the AR screen except the per-frame geometry - see [ArFrame].
class ArUiState {
  const ArUiState({
    this.plots = const [],
    this.health = const {},
    this.index = HealthIndex.ndvi,
    this.mode,
    this.edgeDistanceM = 0,
    this.headingStatus,
    this.accuracyM = 0.0,
    this.hasFix = false,
    this.stationary = false,
    this.message,
    this.visual = false,
    this.visualTracking = false,
    this.trackingFailure = ArTrackingFailure.none,
    this.snappedTo,
    this.depthActive = false,
    this.loaded = false,
  });

  /// Every cached plot. The view shows the nearby ones.
  final List<Plot> plots;

  /// Crop condition per plot id, for those that have a snapshot.
  final Map<String, PlotHealth> health;

  /// Which index the drop points and the minimap show.
  final HealthIndex index;

  /// Render mode of the nearest plot, or null before the first frame.
  final RenderMode? mode;

  /// Distance to the nearest plot's nearest edge, whole metres.
  final int edgeDistanceM;
  final HeadingStatus? headingStatus;
  final double accuracyM;
  final bool hasFix;

  /// True while the stabiliser judges the agent to be standing still.
  final bool stationary;
  final String? message;

  /// ARCore motion tracking carries the pose and the motion this session.
  final bool visual;

  /// ARCore is tracking right now. While it is not, counted steps stand in.
  final bool visualTracking;
  final ArTrackingFailure trackingFailure;

  /// The plot whose boundary the session anchored to, once it has.
  final String? snappedTo;

  /// ARCore depth is hiding the overlay behind nearer objects.
  final bool depthActive;

  /// The cache has been read.
  final bool loaded;

  bool get snapped => snappedTo != null;

  /// Every drop point of the current index, across all plots.
  Iterable<HealthPatch> get patches sync* {
    for (final h in health.values) {
      yield* h.patchesFor(index);
    }
  }

  /// True when any shown snapshot is demonstration data.
  bool get synthetic => health.values.any((h) => h.synthetic);

  ArUiState copyWith({
    List<Plot>? plots,
    Map<String, PlotHealth>? health,
    HealthIndex? index,
    RenderMode? mode,
    int? edgeDistanceM,
    HeadingStatus? Function()? headingStatus,
    double? accuracyM,
    bool? hasFix,
    bool? stationary,
    String? Function()? message,
    bool? visualTracking,
    ArTrackingFailure? trackingFailure,
    String? Function()? snappedTo,
    bool? depthActive,
    bool? loaded,
  }) =>
      ArUiState(
        plots: plots ?? this.plots,
        health: health ?? this.health,
        index: index ?? this.index,
        mode: mode ?? this.mode,
        edgeDistanceM: edgeDistanceM ?? this.edgeDistanceM,
        headingStatus: headingStatus == null ? this.headingStatus : headingStatus(),
        accuracyM: accuracyM ?? this.accuracyM,
        hasFix: hasFix ?? this.hasFix,
        stationary: stationary ?? this.stationary,
        message: message == null ? this.message : message(),
        visual: visual,
        visualTracking: visualTracking ?? this.visualTracking,
        trackingFailure: trackingFailure ?? this.trackingFailure,
        snappedTo: snappedTo == null ? this.snappedTo : snappedTo(),
        depthActive: depthActive ?? this.depthActive,
        loaded: loaded ?? this.loaded,
      );
}

/// Runs one AR session over every nearby plot: pose in, overlay out.
class ArController extends ValueNotifier<ArUiState> {
  /// [focusPlotId], when the session was opened from a plot, is preferred for
  /// telemetry; every nearby plot is shown either way. [visual] runs the
  /// session on ARCore motion tracking; the AR screen sets it only once it
  /// knows ARCore is installed and its camera view is shown.
  ArController(this._container, {String? focusPlotId, bool visual = false})
      : _focusPlotId = focusPlotId,
        _sensors = _container.createSensors(visual: visual),
        super(ArUiState(visual: visual)) {
    _sensors.location.location.addListener(_onLocationChanged);
    _sensors.pose.pose.addListener(_onPoseChanged);
    _sensors.pose.headingStatus.addListener(_onHeadingStatusChanged);
    final vio = _vio;
    if (vio != null) {
      vio.onMotion = _onVisualMotion;
      vio.status.addListener(_onVisualStatusChanged);
    }
    _load();
  }

  final AppContainer _container;
  final String? _focusPlotId;
  final Sensors _sensors;

  /// The ARCore pose source, when this session runs on one.
  VioPoseSource? get _vio => switch (_sensors.pose) {
        final VioPoseSource vio => vio,
        _ => null,
      };

  /// True once ARCore has failed outright; the screen restarts on the sensors.
  final ValueNotifier<bool> visualFailed = ValueNotifier(false);

  /// The geometry to draw, updated at sensor rate. The canvas listens to this
  /// alone; see [ArFrame].
  final ValueNotifier<ArFrame?> frame = ValueNotifier(null);

  /// Pinch zoom, from 1 (none) to [maxZoom].
  final ValueNotifier<double> zoom = ValueNotifier(1.0);

  /// The latest attitude. Not UI state: only the overlay and telemetry use it.
  DevicePose _pose = DevicePose.unknown;

  final CourseOverGroundDetector _courseOverGround = CourseOverGroundDetector();

  /// Direction from the walk itself, on the ARCore path. See [TrajectoryAligner].
  final TrajectoryAligner _aligner = TrajectoryAligner();
  bool _wasTracking = false;

  /// Smooths the agent's position and carries it with ARCore's motion or
  /// counted steps. The boundary snap pins it.
  final PositionStabilizer _stabilizer = PositionStabilizer();

  final StepDetector _steps = StepDetector();
  final StepLengthModel _stepLength = StepLengthModel();
  late final StepCalibrator _stepCalibration = StepCalibrator(_stepLength);
  StreamSubscription<(double, int)>? _acceleration;

  /// The local metric frame, re-anchored whenever the agent walks far enough.
  EnuFrame? _frame;

  CameraIntrinsics? _intrinsics;

  /// The overlay box in logical pixels, kept so the intrinsics can be rebuilt
  /// when ARCore reports the field of view its preview is really shown with.
  (int, int)? _viewport;
  LocationSample? _lastLocation;

  /// The filtered position everything is drawn against.
  LatLng? _agentPosition;

  /// Where the session last snapped, for deciding when the agent has walked
  /// on far enough to snap to another boundary.
  LatLng? _snapPoint;

  /// Nearby plots, nearest first, recomputed on each fix.
  List<Plot> _nearby = const [];

  /// The scene's fixed origin on the ARCore path; set with the first nearby set.
  LatLng? _sceneOrigin;

  double _worstStationaryShiftM = 0.0;
  int _frameAnchoredAtMs = 0;
  final int _sessionStartedAtMs = DateTime.now().millisecondsSinceEpoch;
  final String _sessionId = _uuidV4();
  bool _disposed = false;

  Future<void> _load() async {
    final plots = await _container.plots.allPlots();
    final health = await _container.plots.allHealth();
    if (_disposed) return;
    value = value.copyWith(
      plots: plots,
      health: health,
      loaded: true,
      message: () => plots.isEmpty ? 'No plots cached - sync on the home screen first' : null,
    );
    // Plots synced before crop condition existed have no snapshot. One quiet
    // attempt each; failing to reach the network is the normal rural case.
    final missing = [
      for (final p in plots)
        if (!health.containsKey(p.id)) p.id,
    ];
    if (missing.isNotEmpty) unawaited(_fetchMissingHealth(missing));
  }

  Future<void> _fetchMissingHealth(List<String> ids) async {
    await Future.wait([for (final id in ids) _container.plots.syncHealth(id)]);
    final health = await _container.plots.allHealth();
    if (_disposed) return;
    _rebuildOverlay(value.copyWith(health: health));
  }

  void start() {
    resume();
    unawaited(_container.telemetry.syncPending());
  }

  void stop() {
    pause();
    _recordTelemetry();
  }

  /// Releases the sensors and the GNSS receiver while the app is in the
  /// background, without ending the session.
  void pause() {
    if (value.visual) unawaited(_container.platform.arPause());
    _sensors.pose.stop();
    _sensors.location.stop();
    _acceleration?.cancel();
    _acceleration = null;
    _steps.reset();
  }

  void resume() {
    if (value.visual) unawaited(_container.platform.arResume());
    _sensors.pose.start();
    _sensors.location.start();
    _acceleration ??= _container.platform.acceleration.listen((sample) {
      final step = _steps.add(sample.$1, sample.$2);
      if (step != null) _onStep(step);
    });
  }

  /// Shows [index]'s drop points - crop greenness, crop vigour or water stress.
  void setIndex(HealthIndex index) {
    if (index == value.index) return;
    _rebuildOverlay(value.copyWith(index: index));
  }

  void dismissMessage() => value = value.copyWith(message: () => null);

  /// One counted step: move the agent along the way the camera faces. Only
  /// without ARCore tracking - with it, the measured motion is used instead.
  void _onStep(DetectedStep step) {
    if (_pose.timestampMs == 0) return;
    if (value.visualTracking) return;
    final heading = _pose.headingDeg;
    _stepCalibration.onStep(step, heading);
    final stepped = _stabilizer.onStep(
      lengthM: _stepLength.lengthM(step.swingMps2),
      headingDeg: heading,
      timestampMs: step.timestampMs,
    );
    if (stepped == null) return;
    _moveAgent(stepped.position);
    _rebuildOverlay(value.copyWith(stationary: false));
  }

  /// Re-anchors the local frame if the agent has walked far enough from it.
  void _moveAgent(LatLng position) {
    _agentPosition = position;
    final current = _frame;
    if (current == null || current.needsReanchor(position)) {
      _frame = EnuFrame(position);
      _frameAnchoredAtMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// The viewport is only known once the camera box has been laid out.
  void onViewportMeasured(int widthPx, int heightPx, double horizontalFovDeg) {
    if (widthPx <= 0 || heightPx <= 0) return;
    _viewport = (widthPx, heightPx);
    final fov = _vio?.status.value.horizontalFovDeg ?? horizontalFovDeg;
    _setIntrinsics(widthPx, heightPx, fov);
  }

  /// Zooms the view by [factor], clamped to 1..[maxZoom].
  ///
  /// It is a digital zoom: the camera image is magnified about the centre and
  /// the projection narrowed by the same factor, so everything drawn stays on
  /// the ground it marks - zooming shows a distant drop point or patch bigger,
  /// it does not move it. Under ARCore the native view does both and reports the
  /// narrower field of view with the next frame; on the sensor path the screen
  /// scales the preview and the intrinsics are narrowed here.
  void setZoom(double factor) {
    final next = factor.clamp(1.0, maxZoom).toDouble();
    if ((next - zoom.value).abs() < 0.005) return;
    zoom.value = next;
    if (value.visual) {
      unawaited(_container.platform.arSetZoom(next));
    } else if (_baseIntrinsics case (final w, final h, final fov)) {
      _setIntrinsics(w, h, fov);
    }
  }

  /// The intrinsics as measured, before any sensor-path zoom.
  (int, int, double)? _baseIntrinsics;

  void _setIntrinsics(int widthPx, int heightPx, double horizontalFovDeg) {
    _baseIntrinsics = (widthPx, heightPx, horizontalFovDeg);
    _intrinsics = CameraIntrinsics(
      // Under ARCore the reported field of view is already the zoomed one.
      horizontalFovDeg: _vio == null ? zoomedFovDeg(horizontalFovDeg, zoom.value) : horizontalFovDeg,
      viewportWidthPx: widthPx,
      viewportHeightPx: heightPx,
    );
    _rebuildOverlay();
  }

  /// One frame of ARCore-measured camera motion, already in true east-north.
  void _onVisualMotion(double dEast, double dNorth, int timestampMs) {
    final moved = _stabilizer.onVisualMotion(dEast: dEast, dNorth: dNorth, timestampMs: timestampMs);
    if (moved == null) return;
    _moveAgent(moved.position);
  }

  void _onVisualStatusChanged() {
    final status = _vio!.status.value;
    if (status.failed) {
      visualFailed.value = true;
      return;
    }
    if (_wasTracking && !status.tracking) {
      // ARCore may resume in a shifted frame: nothing measured before can be
      // laid against anything after, and the snap is no longer held by it.
      _aligner.reset();
      _snapPoint = null;
      if (value.snapped) {
        // The anchor no longer holds, so the ground colouring goes with it until
        // the next one.
        value = value.copyWith(
          snappedTo: () => null,
          message: () => 'Tracking lost - walk to a boundary to anchor again',
        );
      }
    }
    _wasTracking = status.tracking;
    final fov = status.horizontalFovDeg;
    final viewport = _viewport;
    final current = _intrinsics;
    if (fov != null && viewport != null && (current == null || (current.horizontalFovDeg - fov).abs() > 0.05)) {
      _setIntrinsics(viewport.$1, viewport.$2, fov);
    }
    if (status.tracking != value.visualTracking ||
        status.failure != value.trackingFailure ||
        status.depthActive != value.depthActive) {
      value = value.copyWith(
        visualTracking: status.tracking,
        trackingFailure: status.failure,
        depthActive: status.depthActive,
      );
    }
  }

  /// The automatic anchor: once GPS puts the agent within [autoSnapDistanceM]
  /// of any nearby plot's boundary, the closest point of it - a corner, or a
  /// point between two corners - is taken as where they stand.
  ///
  /// Once per area: it happens again only after the agent has moved
  /// [resnapAfterM] from the last snap point (on to the next plot), or ARCore
  /// lost tracking and the old anchor no longer holds.
  void _maybeSnap(LocationSample sample) {
    if (_nearby.isEmpty) return;
    final last = _snapPoint;
    final agent = _agentPosition;
    if (last != null && agent != null && distanceM(last, agent) < resnapAfterM) return;

    final hit = nearestBoundaryPoint([for (final p in _nearby) p.ring], sample.position);
    if (hit == null || hit.distanceM > autoSnapDistanceM) return;

    final plot = _nearby[hit.ringIndex];
    final pinned = _stabilizer.pinTo(hit.point, timestampMs: sample.timestampMs);
    _snapPoint = hit.point;
    _moveAgent(pinned.position);
    if (_vio?.sessionPosition case final session?) {
      _aligner.anchor(session, hit.point);
      _lockFromWalk();
    }
    _rebuildOverlay(value.copyWith(
      snappedTo: () => plot.id,
      stationary: true,
      accuracyM: _stabilizer.uncertaintyM,
      message: () => 'Anchored to the ${plot.name} boundary',
    ));
  }

  /// Offers the walk alignment to the heading, when it is good enough and
  /// better than what the heading already has.
  void _lockFromWalk() {
    final vio = _vio;
    if (vio == null) return;
    final fit = _aligner.solve();
    if (fit == null || fit.errorDeg > maxAlignmentErrorDeg) return;
    final current = vio.headingStatus.value;
    final unlocked = current.confidence == HeadingConfidence.unreliable;
    if (!unlocked && fit.errorDeg > current.expectedErrorDeg + 0.5) return;
    vio.applyYawOffset(fit.yawOffsetDeg, HeadingSource.courseOverGround, errorDeg: fit.errorDeg);
  }

  void _onLocationChanged() {
    final sample = _sensors.location.location.value;
    if (sample != null) _onLocation(sample);
  }

  void _onLocation(LocationSample sample) {
    _lastLocation = sample;

    // Direction from walking. On the sensor path, a straight GNSS segment; on
    // the ARCore path, the tracked walk fitted to the fixes along it.
    final vio = _vio;
    if (vio == null) {
      final locked = _courseOverGround.add(sample);
      if (locked != null) _sensors.pose.applyHeadingFix(locked, HeadingSource.courseOverGround);
    } else if (value.visualTracking) {
      if (vio.sessionPosition case final session?) {
        _aligner.addFix(session, sample.position, sample.accuracyM);
        _lockFromWalk();
      }
    }

    final stabilized = _stabilizer.update(
      position: sample.position,
      accuracyM: sample.accuracyM,
      speedMps: sample.speedMps,
      timestampMs: sample.timestampMs,
    );
    _moveAgent(stabilized.position);
    _stepCalibration.onFix(sample.position, sample.accuracyM);
    if (stabilized.stationary) {
      _worstStationaryShiftM = math.max(_worstStationaryShiftM, stabilized.shiftM);
    }

    _updateNearby(stabilized.position);
    _maybeSnap(sample);

    final snapped = _stabilizer.pinned;
    _rebuildOverlay(value.copyWith(
      // Once snapped, the receiver's error is not the position's any more.
      accuracyM: snapped ? math.min(sample.accuracyM, _stabilizer.uncertaintyM) : sample.accuracyM,
      hasFix: true,
      stationary: stabilized.stationary,
    ));
  }

  /// Picks the plots worth drawing: within [plotViewRangeM] of an edge, at most
  /// [maxDrawnPlots], nearest first.
  void _updateNearby(LatLng at) {
    final scored = <(Plot, double)>[];
    for (final plot in value.plots) {
      final d = insideRing(plot.ring, at) ? 0.0 : distanceToRingM(plot.ring, at);
      if (d <= plotViewRangeM) scored.add((plot, d));
    }
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    final next = [for (final (plot, _) in scored.take(maxDrawnPlots)) plot];
    if (!listEquals([for (final p in next) p.id], [for (final p in _nearby) p.id])) {
      _nearby = next;
      _sceneOrigin ??= at;
    }
  }

  void _onPoseChanged() {
    _pose = _sensors.pose.pose.value;
    _rebuildOverlay();
    _syncPlacement();
  }

  void _onHeadingStatusChanged() {
    final status = _sensors.pose.headingStatus.value;
    _rebuildOverlay(value.copyWith(headingStatus: () => status));
  }

  /// What the native renderer was last given, to send only real changes.
  Object? _sentSceneKey;
  WorldPlacement? _sentPlacement;

  /// Sends every nearby plot and the drop points of the current index to the
  /// ARCore renderer, when any of that has changed.
  void _syncScene(ArUiState state) {
    if (!state.visual) return;
    final origin = _sceneOrigin;
    if (origin == null) return;
    final confidence = state.headingStatus?.confidence ?? HeadingConfidence.unreliable;
    final key = (
      Object.hashAll([for (final p in _nearby) p.id]),
      state.index,
      identityHashCode(state.health),
      confidence,
      state.snapped,
    );
    if (key == _sentSceneKey) return;
    _sentSceneKey = key;
    final agent = _agentPosition ?? origin;
    final scene = buildWorldScene(
      plots: _nearby,
      // Ground cells only once anchored. Before that the scene is placed from
      // raw GPS and moves with it, and a 3 m square that wanders by several
      // metres paints the wrong ground; a drop point is a target, not a claim
      // about which square metre is red, so it is shown from the start.
      cells: [
        if (state.snapped)
          for (final plot in _nearby) ...?state.health[plot.id]?.cells,
      ],
      index: state.index,
      patches: nearbyPatches(state.patches, agent, state.index),
      origin: origin,
      // Always the plots' own colours on the ARCore path: a grey translucent
      // wall is invisible against a white wall or a pale sky. The heading chip
      // carries the confidence instead.
      alpha: math.max(0.85, overlayConfidenceAlpha(confidence)),
    );
    unawaited(_container.platform.arSetScene(scene.toMessage()));
  }

  /// Tells the ARCore renderer where the scene stands in its session. Only
  /// when the geo-registration moves - walking moves agent and camera together.
  void _syncPlacement() {
    final vio = _vio;
    final origin = _sceneOrigin;
    final agent = _agentPosition;
    if (vio == null || origin == null || agent == null) return;
    final session = vio.sessionPosition;
    final yaw = vio.yawOffsetDeg;
    if (session == null || yaw == null) return;
    final next = placePlot(plotOrigin: origin, agent: agent, sessionCamera: session, yawOffsetDeg: yaw);
    final sent = _sentPlacement;
    if (sent != null && next.isCloseTo(sent)) return;
    _sentPlacement = next;
    unawaited(_container.platform.arSetPlacement(next.toList()));
  }

  /// Rebuilds the frame and publishes [next] - the current state when omitted.
  void _rebuildOverlay([ArUiState? next]) {
    if (_disposed) return;
    var state = next ?? value;
    final frame = _frame;
    final intrinsics = _intrinsics;
    final agent = _agentPosition;
    if (frame != null && intrinsics != null && agent != null) {
      final eyeHeight = _vio?.eyeHeightM ?? eyeHeightM;
      final drawn = <DrawnPlot>[
        for (final (i, plot) in _nearby.indexed)
          DrawnPlot(
            plot,
            buildPlotOverlay(
              primary: i == 0,
              ring: plot.ring,
              centroid: plot.centroid,
              agent: agent,
              frame: frame,
              deviceToEnu: _pose.deviceToEnu,
              intrinsics: intrinsics,
              gnssAccuracyM: state.accuracyM,
              eyeHeight: eyeHeight,
            ),
          ),
      ];
      final drops = state.visual
          ? const <DropMarker>[]
          : buildDropMarkers(
              patches: nearbyPatches(state.patches, agent, state.index),
              frame: frame,
              eye: frame.toEnu(agent),
              enuToDevice: _pose.deviceToEnu.transpose(),
              intrinsics: intrinsics,
              eyeHeight: eyeHeight,
            );
      final cells = state.visual || !state.snapped
          ? const <CellPolygon>[]
          : buildCellPolygons(
              cells: [
                for (final plot in _nearby) ...?state.health[plot.id]?.cells,
              ],
              index: state.index,
              frame: frame,
              eye: frame.toEnu(agent),
              enuToDevice: _pose.deviceToEnu.transpose(),
              intrinsics: intrinsics,
              eyeHeight: eyeHeight,
            );
      this.frame.value = ArFrame(
        plots: drawn,
        drops: drops,
        cells: cells,
        guide: state.snapped ? null : _guide(agent),
        agent: agent,
        headingDeg: _pose.headingDeg,
      );

      if (drawn.isNotEmpty) {
        final nearest = drawn.first.overlay;
        final edge = nearest.edgeDistanceM.toInt();
        if (state.mode != nearest.mode || state.edgeDistanceM != edge) {
          state = state.copyWith(mode: nearest.mode, edgeDistanceM: edge);
        }
      }
    }
    _syncScene(state);
    if (!identical(state, value)) value = state;
  }

  /// Which way, and how far, to the nearest boundary of any nearby plot.
  BoundaryGuide? _guide(LatLng agent) {
    if (_nearby.isEmpty) return null;
    final hit = nearestBoundaryPoint([for (final p in _nearby) p.ring], agent);
    if (hit == null) return null;
    return BoundaryGuide(
      hit.distanceM,
      angleDifferenceDeg(_pose.headingDeg, bearingDeg(agent, hit.point)),
      _nearby[hit.ringIndex].name,
    );
  }

  /// One row per session, written on the way out. No UI, by design.
  void _recordTelemetry() {
    final snapshot = value;
    final location = _lastLocation;
    final status = snapshot.headingStatus;
    if (location == null || status == null) return;
    final mode = snapshot.mode?.wireName ?? 'NONE';
    final plotId = _focusPlotId ?? snapshot.snappedTo ?? (_nearby.isEmpty ? '' : _nearby.first.id);

    final now = DateTime.now().millisecondsSinceEpoch;
    final row = TelemetryEntity(
      timestampMs: now,
      sessionId: _sessionId,
      plotId: plotId,
      lat: location.position.lat,
      lng: location.position.lng,
      reportedAccuracyM: location.accuracyM,
      headingDeg: _pose.headingDeg,
      headingSource: status.source.wireName,
      headingConfidence: status.confidence.wireName,
      renderMode: mode,
      anchorShiftM: _worstStationaryShiftM,
      anchorAgeS: _frameAnchoredAtMs == 0 ? 0.0 : (now - _frameAnchoredAtMs) / 1000.0,
      deviceModel: _container.deviceInfo.model,
      appVersion: _container.deviceInfo.appVersion,
      sessionDurationMs: now - _sessionStartedAtMs,
    );
    unawaited(() async {
      await _container.telemetry.record(row);
      await _container.telemetry.syncPending();
    }());
  }

  @override
  set value(ArUiState newValue) {
    if (_disposed) return;
    super.value = newValue;
  }

  @override
  void dispose() {
    _disposed = true;
    _sensors.location.location.removeListener(_onLocationChanged);
    _sensors.pose.pose.removeListener(_onPoseChanged);
    _sensors.pose.headingStatus.removeListener(_onHeadingStatusChanged);
    _vio?.status.removeListener(_onVisualStatusChanged);
    if (value.visual) {
      unawaited(_container.platform.arSetScene(null));
      unawaited(_container.platform.arSetPlacement(null));
      unawaited(_container.platform.arSetZoom(1.0));
    }
    zoom.dispose();
    _acceleration?.cancel();
    visualFailed.dispose();
    frame.dispose();
    super.dispose();
  }
}

/// A random (version 4) UUID, for grouping one session's telemetry.
String _uuidV4() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
