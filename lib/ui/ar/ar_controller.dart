import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../app_container.dart';
import '../../core/geo/enu.dart';
import '../../core/geo/linear.dart';
import '../../core/geo/position_stabilizer.dart';
import '../../core/geo/projection.dart';
import '../../core/heading/course_over_ground_detector.dart';
import '../../core/heading/heading_model.dart';
import '../../core/heading/landmark_snap.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../data/db/entities.dart';
import '../../data/plot.dart';
import '../../pose/pose_source.dart';
import '../../sim/simulation_engine.dart';

/// What the overlay canvas draws for one pose sample.
///
/// Kept out of [ArUiState] on purpose. A new frame arrives with every carrier
/// sample - about fifty a second - and only the canvas needs it. Folding it into
/// the UI state made every one of those samples rebuild the whole screen: the
/// chip, the health panel, the buttons and the camera box.
class ArFrame {
  const ArFrame(this.overlay, this.health);

  final PlotOverlay overlay;

  /// The crop-health raster, already projected. Null when the layer is off.
  final HealthOverlay? health;
}

/// Everything on the AR screen except the per-frame geometry - see [ArFrame].
class ArUiState {
  const ArUiState({
    this.plot,
    this.mode,
    this.edgeDistanceM = 0,
    this.hiddenCellCount = 0,
    this.headingStatus,
    this.accuracyM = 0.0,
    this.hasFix = false,
    this.stationary = false,
    this.health,
    this.healthLayer = HealthLayer.stress,
    this.healthSyncing = false,
    this.message,
  });

  final Plot? plot;

  /// Render mode of the latest frame, or null before the first one.
  final RenderMode? mode;

  /// Distance to the nearest edge, whole metres - as precise as the badge shows.
  final int edgeDistanceM;

  /// Cells inside range that the health layer chose not to draw.
  final int hiddenCellCount;
  final HeadingStatus? headingStatus;
  final double accuracyM;
  final bool hasFix;

  /// True while the stabiliser judges the agent to be standing still.
  final bool stationary;

  /// The cached crop-health raster, or null if none has ever been pulled.
  final PlotHealth? health;

  /// What the agent asked to see. Not necessarily what is drawn - see below.
  final HealthLayer healthLayer;
  final bool healthSyncing;
  final String? message;

  /// The layer actually drawn, after the heading veto.
  ///
  /// A boundary drawn on a bad heading is wrong about where a fence is, and the
  /// agent can see the fence to check it. A health patch drawn on a bad heading
  /// is wrong about which ground is failing, and there is nothing in the field
  /// to check it against - stressed crop and healthy crop look alike from a
  /// distance, which is the entire reason for showing the raster. So the
  /// boundary degrades to grey and stays up, while this switches off rather
  /// than sending someone to dig up a healthy corner.
  HealthLayer get effectiveHealthLayer =>
      headingStatus?.confidence == HeadingConfidence.unreliable ? HealthLayer.off : healthLayer;

  /// True when the layer is on but the heading veto is suppressing it.
  bool get healthVetoed => healthLayer != HealthLayer.off && effectiveHealthLayer == HealthLayer.off;

  ArUiState copyWith({
    Plot? Function()? plot,
    RenderMode? mode,
    int? edgeDistanceM,
    int? hiddenCellCount,
    HeadingStatus? Function()? headingStatus,
    double? accuracyM,
    bool? hasFix,
    bool? stationary,
    PlotHealth? Function()? health,
    HealthLayer? healthLayer,
    bool? healthSyncing,
    String? Function()? message,
  }) =>
      ArUiState(
        plot: plot == null ? this.plot : plot(),
        mode: mode ?? this.mode,
        edgeDistanceM: edgeDistanceM ?? this.edgeDistanceM,
        hiddenCellCount: hiddenCellCount ?? this.hiddenCellCount,
        headingStatus: headingStatus == null ? this.headingStatus : headingStatus(),
        accuracyM: accuracyM ?? this.accuracyM,
        hasFix: hasFix ?? this.hasFix,
        stationary: stationary ?? this.stationary,
        health: health == null ? this.health : health(),
        healthLayer: healthLayer ?? this.healthLayer,
        healthSyncing: healthSyncing ?? this.healthSyncing,
        message: message == null ? this.message : message(),
      );
}

/// Runs one AR session: pose in, overlay out, telemetry recorded.
class ArController extends ValueNotifier<ArUiState> {
  ArController(this._container, this._plotId, {required bool simulated})
      : _sensors = _container.createSensors(simulated: simulated, simulationOrigin: simulationOrigin),
        super(const ArUiState()) {
    _sensors.location.location.addListener(_onLocationChanged);
    _sensors.pose.pose.addListener(_onPoseChanged);
    _sensors.pose.headingStatus.addListener(_onHeadingStatusChanged);
    _load();
  }

  /// Used only until the plot loads and the agent is placed relative to it.
  static const LatLng simulationOrigin = LatLng(12.7862, 76.7201);

  final AppContainer _container;
  final String _plotId;
  final Sensors _sensors;

  SimulationEngine? get simulation => _sensors.simulation;

  /// The geometry to draw, updated at sensor rate. The canvas listens to this
  /// alone; see [ArFrame].
  final ValueNotifier<ArFrame?> frame = ValueNotifier(null);

  /// The latest attitude. Not UI state: only the overlay and telemetry use it.
  DevicePose _pose = DevicePose.unknown;

  final CourseOverGroundDetector _courseOverGround = CourseOverGroundDetector();

  /// Smooths the agent's position so a stationary agent gets a stationary
  /// overlay. Applied to the render path only - see [_onLocation].
  final PositionStabilizer _stabilizer = PositionStabilizer();

  /// The local metric frame, re-anchored whenever the agent walks far enough.
  /// Held here rather than rebuilt per frame so that a single origin serves
  /// every point in one drawing pass - two points converted against different
  /// origins would be metres apart for no reason.
  EnuFrame? _frame;

  CameraIntrinsics? _intrinsics;
  LocationSample? _lastLocation;

  /// The health raster in metres, built once per frame anchor.
  ///
  /// Rebuilt only when [_frame] changes, which is when the agent has walked far
  /// enough to re-anchor - not on every pose sample. Converting a few hundred
  /// cells from degrees is trigonometry per corner, and doing that at sensor
  /// rate is the difference between a smooth overlay and a stuttering one.
  HealthField? _healthField;

  /// The filtered position everything is drawn against.
  LatLng? _agentPosition;

  /// Worst single-update overlay shift seen while standing still, for telemetry.
  double _worstStationaryShiftM = 0.0;
  int _frameAnchoredAtMs = 0;
  final int _sessionStartedAtMs = DateTime.now().millisecondsSinceEpoch;
  final String _sessionId = _uuidV4();
  bool _disposed = false;

  Future<void> _load() async {
    final plot = await _container.plots.findById(_plotId);
    if (_disposed) return;
    value = value.copyWith(
      plot: () => plot,
      message: () => plot == null ? 'Plot $_plotId is not in the offline cache' : null,
    );
    // Simulation starts the agent a realistic walk away from the plot, so far
    // mode is what you see first. The stabiliser is reset first: a teleport is
    // not a GNSS observation, and filtering it against an estimate anchored
    // somewhere else would have it gated as a wild outlier - which once left
    // the overlay stranded 97 km away.
    if (plot != null) {
      _stabilizer.reset();
      simulation?.teleport(_simulationStartFor(plot));
      // The raster is loaded after the plot, never before: the boundary is
      // what the agent came for and must not wait on it.
      await _loadHealth();

      // A plot cached before the health layer existed has a boundary and no
      // raster, and the layer defaults to on - so without this the agent opens
      // AR, sees no colour, and concludes the field is healthy. One quiet
      // attempt fixes that. Quiet because it is speculative: failing to reach
      // the network here is the normal rural case and is not worth a banner.
      if (!_disposed && value.health == null) unawaited(refreshHealth(announce: false));
    }
  }

  void start() {
    _sensors.pose.start();
    _sensors.location.start();
    unawaited(_container.telemetry.syncPending());
  }

  void stop() {
    pause();
    _recordTelemetry();
  }

  /// Releases the sensors and the GNSS receiver while the app is in the
  /// background, without ending the session. An AR screen left open in a
  /// pocket would otherwise keep a 1 Hz high-accuracy fix and two 50 Hz sensor
  /// streams running for nothing.
  void pause() {
    _sensors.pose.stop();
    _sensors.location.stop();
  }

  void resume() {
    _sensors.pose.start();
    _sensors.location.start();
  }

  /// The viewport is only known once the camera box has been laid out.
  void onViewportMeasured(int widthPx, int heightPx, double horizontalFovDeg) {
    if (widthPx <= 0 || heightPx <= 0) return;
    final next = CameraIntrinsics(
      horizontalFovDeg: horizontalFovDeg,
      viewportWidthPx: widthPx,
      viewportHeightPx: heightPx,
    );
    if (next != _intrinsics) {
      debugPrint('PlotFinder: viewport ${widthPx}x$heightPx hFOV=${horizontalFovDeg.toStringAsFixed(1)} deg '
          '-> focal=${next.focalPx.toStringAsFixed(1)}');
    }
    _intrinsics = next;
    _rebuildOverlay();
  }

  /// Landmark snap: the agent has the crosshair on the plot's access point.
  ///
  /// Both endpoints are known, so the true bearing is computable outright - one
  /// tap and the heading is pinned to within a couple of degrees, no walking
  /// required. [crosshairXPx] allows for a crosshair that is not dead centre.
  void snapToAccessPoint({double? crosshairXPx}) {
    final plot = value.plot;
    if (plot == null) return;
    final agent = _lastLocation?.position;
    if (agent == null) {
      value = value.copyWith(message: () => 'Waiting for a GNSS fix before snapping');
      return;
    }
    final intrinsics = _intrinsics;
    final offsetDeg =
        crosshairXPx != null && intrinsics != null ? horizontalAngleOffsetDeg(crosshairXPx, intrinsics) : 0.0;

    final heading = headingFromLandmarkSnap(agent, plot.accessPoint, offsetDeg);
    if (heading == null) {
      value = value.copyWith(
        message: () => 'Too close to the access point to snap - aim at something further off',
      );
      return;
    }
    _sensors.pose.applyHeadingFix(heading, HeadingSource.landmarkSnap);
    value = value.copyWith(message: () => 'Heading pinned to the access point');
  }

  /// Cycles off - problem areas - all cells.
  void cycleHealthLayer() => setHealthLayer(value.healthLayer.next());

  /// Shows [layer], fetching the raster if the agent turned health on and
  /// none is cached.
  void setHealthLayer(HealthLayer layer) {
    if (layer == value.healthLayer) return;
    _rebuildOverlay(value.copyWith(healthLayer: layer));
    if (layer != HealthLayer.off && value.health == null) unawaited(refreshHealth());
  }

  /// Pulls this plot's raster from the API on demand.
  ///
  /// Needed because a plot cached before the health layer existed has a
  /// boundary and no raster, and making the agent re-sync every plot in the
  /// district to colour one field would be an absurd way to spend their signal.
  Future<void> refreshHealth({bool announce = true}) async {
    if (value.healthSyncing) return;
    value = value.copyWith(healthSyncing: true);
    await _container.plots.syncHealth(_plotId);
    await _loadHealth();
    if (_disposed) return;
    // Judged on what is now cached, not on what the call returned: a fetch
    // that failed against a raster already on disk is not a problem the agent
    // needs to hear about.
    final failed = value.health == null;
    value = value.copyWith(
      healthSyncing: false,
      message: announce && failed ? () => 'No crop health cached for this plot, and no signal to fetch it' : null,
    );
  }

  Future<void> _loadHealth() async {
    final health = await _container.plots.healthFor(_plotId);
    if (_disposed) return;
    // The metric conversion belongs to the old raster; keeping it would draw
    // the previous cells under the new data.
    _healthField = null;
    _rebuildOverlay(value.copyWith(health: () => health));
  }

  void dismissMessage() => value = value.copyWith(message: () => null);

  void _onLocationChanged() {
    final sample = _sensors.location.location.value;
    if (sample != null) _onLocation(sample);
  }

  void _onLocation(LocationSample sample) {
    _lastLocation = sample;

    // A walked segment is the one heading source no magnetic disturbance can
    // touch, so every fix is offered to the detector - and it is offered the
    // RAW fix, deliberately. The stabiliser's whole job is to suppress apparent
    // movement, which is precisely the signal course-over-ground measures;
    // feeding it filtered positions would shorten every segment and bias the
    // bearing towards whatever the filter already believed.
    final locked = _courseOverGround.add(sample);
    if (locked != null) _sensors.pose.applyHeadingFix(locked, HeadingSource.courseOverGround);

    final stabilized = _stabilizer.update(
      position: sample.position,
      accuracyM: sample.accuracyM,
      speedMps: sample.speedMps,
      timestampMs: sample.timestampMs,
    );
    _agentPosition = stabilized.position;

    if (stabilized.stationary) {
      _worstStationaryShiftM = math.max(_worstStationaryShiftM, stabilized.shiftM);
    }

    final current = _frame;
    if (current == null || current.needsReanchor(stabilized.position)) {
      _frame = EnuFrame(stabilized.position);
      _frameAnchoredAtMs = DateTime.now().millisecondsSinceEpoch;
      // Every cached metre is measured from the old origin. Keeping them would
      // offset the whole raster by however far the agent walked.
      _healthField = null;
    }

    _rebuildOverlay(value.copyWith(
      accuracyM: sample.accuracyM,
      hasFix: true,
      stationary: stabilized.stationary,
    ));
  }

  void _onPoseChanged() {
    _pose = _sensors.pose.pose.value;
    _rebuildOverlay();
  }

  void _onHeadingStatusChanged() {
    // Through the overlay, not around it: the heading veto on the health layer
    // depends on this status, so the frame has to be rebuilt against it.
    final status = _sensors.pose.headingStatus.value;
    _rebuildOverlay(value.copyWith(headingStatus: () => status));
  }

  /// Rebuilds the frame and publishes [next] - the current state when omitted.
  ///
  /// Listeners hear about a state change at most once per call, and not at all
  /// when nothing they show has changed. At fifty pose samples a second that is
  /// the difference between redrawing the canvas and rebuilding the screen.
  void _rebuildOverlay([ArUiState? next]) {
    if (_disposed) return;
    var state = next ?? value;
    final plot = state.plot;
    final frame = _frame;
    final intrinsics = _intrinsics;
    final agent = _agentPosition;
    if (plot != null && frame != null && intrinsics != null && agent != null) {
      final overlay = buildPlotOverlay(
        ring: plot.ring,
        centroid: plot.centroid,
        agent: agent,
        frame: frame,
        deviceToEnu: _pose.deviceToEnu,
        intrinsics: intrinsics,
        gnssAccuracyM: state.accuracyM,
      );
      final health = _buildHealth(state, frame, agent, _pose.deviceToEnu, intrinsics);
      this.frame.value = ArFrame(overlay, health);

      final edge = overlay.edgeDistanceM.toInt();
      final hidden = health?.hiddenCellCount ?? 0;
      if (state.mode != overlay.mode || state.edgeDistanceM != edge || state.hiddenCellCount != hidden) {
        state = state.copyWith(mode: overlay.mode, edgeDistanceM: edge, hiddenCellCount: hidden);
      }
    }
    if (!identical(state, value)) value = state;
  }

  /// Projects the health raster against the same eye and frame as the boundary.
  ///
  /// Both take the camera from the *stabilised* agent fix through this one
  /// frame, so the raster and the boundary move together or not at all.
  /// Deriving the eye separately here is precisely what would let the brown
  /// ground drift outside the plot that is supposed to contain it.
  HealthOverlay? _buildHealth(
    ArUiState state,
    EnuFrame frame,
    LatLng agent,
    Mat3 deviceToEnu,
    CameraIntrinsics intrinsics,
  ) {
    final layer = state.effectiveHealthLayer;
    if (layer == HealthLayer.off) return null;
    final health = state.health;
    if (health == null) return null;

    final existing = _healthField;
    final field = existing != null && existing.matches(frame)
        ? existing
        : (_healthField = HealthField(health.cells, health.hotspots, frame));
    if (field.isEmpty) return null;

    return buildHealthOverlay(
      field: field,
      eye: frame.toEnu(agent),
      enuToDevice: deviceToEnu.transpose(),
      intrinsics: intrinsics,
      layer: layer,
    );
  }

  /// One row per session, written on the way out. No UI, by design.
  void _recordTelemetry() {
    final snapshot = value;
    final location = _lastLocation;
    final status = snapshot.headingStatus;
    if (location == null || status == null) return;
    final mode = snapshot.mode?.wireName ?? 'NONE';

    final now = DateTime.now().millisecondsSinceEpoch;
    final row = TelemetryEntity(
      timestampMs: now,
      sessionId: _sessionId,
      plotId: _plotId,
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
    // Not tied to this controller's lifetime: the row must land even though
    // the screen that produced it is closing.
    unawaited(() async {
      await _container.telemetry.record(row);
      await _container.telemetry.syncPending();
    }());
  }

  /// Drops the agent about 127 m south-west of the plot, a plausible road arrival.
  static LatLng _simulationStartFor(Plot plot) => EnuFrame(plot.centroid).toLatLng(const Enu(-90.0, -90.0));

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
