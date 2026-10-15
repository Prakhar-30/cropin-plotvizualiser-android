import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../app_container.dart';
import '../../core/geo/arcore_pose.dart';
import '../../core/geo/enu.dart';
import '../../core/geo/linear.dart';
import '../../core/geo/position_stabilizer.dart';
import '../../core/geo/projection.dart';
import '../../core/heading/course_over_ground_detector.dart';
import '../../core/heading/heading_model.dart';
import '../../core/heading/landmark_snap.dart';
import '../../core/heading/trajectory_aligner.dart';
import '../../core/math_util.dart';
import '../../core/motion/step_calibrator.dart';
import '../../core/motion/step_detector.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../core/render/world_scene.dart';
import '../../data/db/entities.dart';
import '../../data/plot.dart';
import '../../pose/pose_source.dart';
import '../../pose/vio_pose_source.dart';

/// Beyond this GPS distance from the access point, "I'm at the access point"
/// stays disabled. Generous enough for ordinary GNSS error in the open,
/// tight enough that a tap from the next field over cannot place the plot.
const double maxAccessPointPinDistanceM = 50.0;

/// What the overlay canvas draws for one pose sample.
///
/// Kept out of [ArUiState] on purpose. A new frame arrives with every carrier
/// sample - about fifty a second - and only the canvas needs it. Folding it into
/// the UI state made every one of those samples rebuild the whole screen: the
/// chip, the health panel, the buttons and the camera box.
class ArFrame {
  const ArFrame(this.overlay, this.health, {this.guide, this.agent, this.headingDeg = 0.0});

  final PlotOverlay overlay;

  /// The way to the access point, until the agent says they are standing on it.
  final AccessGuide? guide;

  /// Where the agent is drawn from, and which way the camera faces - for the
  /// minimap's marker.
  final LatLng? agent;
  final double headingDeg;

  /// The crop-health raster, already projected. Null when the layer is off.
  final HealthOverlay? health;
}

/// Where the access point is from here: how far, and how far to turn.
class AccessGuide {
  const AccessGuide(this.distanceM, this.relativeBearingDeg);

  final double distanceM;

  /// Negative is to the left of where the camera points.
  final double relativeBearingDeg;
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
    this.visual = false,
    this.visualTracking = false,
    this.trackingFailure = ArTrackingFailure.none,
    this.pinned = false,
    this.depthActive = false,
    this.accessPointDistanceM,
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

  /// ARCore motion tracking carries the pose and the motion this session.
  final bool visual;

  /// ARCore is tracking right now. While it is not, counted steps stand in.
  final bool visualTracking;

  /// Why ARCore is not tracking, when it is not.
  final ArTrackingFailure trackingFailure;

  /// The agent has declared their position at the access point.
  final bool pinned;

  /// ARCore depth is hiding the overlay behind nearer objects.
  final bool depthActive;

  /// GPS distance to the access point, whole metres; null before a fix.
  final int? accessPointDistanceM;

  /// "I'm at the access point" is offered only within
  /// [maxAccessPointPinDistanceM] by GPS.
  bool get canPin => switch (accessPointDistanceM) {
        final d? => d <= maxAccessPointPinDistanceM,
        null => false,
      };

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
    bool? visualTracking,
    ArTrackingFailure? trackingFailure,
    bool? pinned,
    bool? depthActive,
    int? Function()? accessPointDistanceM,
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
        visual: visual,
        visualTracking: visualTracking ?? this.visualTracking,
        trackingFailure: trackingFailure ?? this.trackingFailure,
        pinned: pinned ?? this.pinned,
        depthActive: depthActive ?? this.depthActive,
        accessPointDistanceM: accessPointDistanceM == null ? this.accessPointDistanceM : accessPointDistanceM(),
      );
}

/// Runs one AR session: pose in, overlay out, telemetry recorded.
class ArController extends ValueNotifier<ArUiState> {
  /// [visual] runs the session on ARCore motion tracking; the AR screen sets
  /// it only once it knows ARCore is installed and its camera view is shown.
  ArController(this._container, this._plotId, {bool visual = false})
      : _sensors = _container.createSensors(visual: visual),
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
  final String _plotId;
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

  /// The latest attitude. Not UI state: only the overlay and telemetry use it.
  DevicePose _pose = DevicePose.unknown;

  final CourseOverGroundDetector _courseOverGround = CourseOverGroundDetector();

  /// Direction from the walk itself, on the ARCore path. See [TrajectoryAligner].
  final TrajectoryAligner _aligner = TrajectoryAligner();
  bool _wasTracking = false;

  /// Smooths the agent's position so a stationary agent gets a stationary
  /// overlay, and moves it with each counted step so a walking agent's overlay
  /// keeps pace with the camera. Applied to the render path only - see
  /// [_onLocation].
  final PositionStabilizer _stabilizer = PositionStabilizer();

  final StepDetector _steps = StepDetector();
  final StepLengthModel _stepLength = StepLengthModel();
  late final StepCalibrator _stepCalibration = StepCalibrator(_stepLength);
  StreamSubscription<(double, int)>? _acceleration;

  /// The local metric frame, re-anchored whenever the agent walks far enough.
  /// Held here rather than rebuilt per frame so that a single origin serves
  /// every point in one drawing pass - two points converted against different
  /// origins would be metres apart for no reason.
  EnuFrame? _frame;

  CameraIntrinsics? _intrinsics;

  /// The overlay box in logical pixels, kept so the intrinsics can be rebuilt
  /// when ARCore reports the field of view its preview is really shown with.
  (int, int)? _viewport;
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
    if (plot != null) {
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
    resume();
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
    if (value.visual) unawaited(_container.platform.arPause());
    _sensors.pose.stop();
    _sensors.location.stop();
    _acceleration?.cancel();
    _acceleration = null;
    // A stride interrupted by the app going away is not one to finish later.
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

  /// One counted step: move the agent along the way the camera faces.
  ///
  /// The camera heading stands in for the walking direction, which is right
  /// for the way this screen is used - phone held up, looking where you are
  /// going - and is the fused, locked heading rather than the compass. When it
  /// is wrong, because the agent walks one way while looking another, the
  /// error is bounded by GNSS pulling the estimate back, and it only lasts
  /// until they look where they are going again.
  void _onStep(DetectedStep step) {
    if (_pose.timestampMs == 0) return;
    // While ARCore tracks, it measures the motion the steps would only model;
    // counting both would move the agent twice.
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
      // Every cached metre is measured from the old origin. Keeping them would
      // offset the whole raster by however far the agent walked.
      _healthField = null;
    }
  }

  /// The viewport is only known once the camera box has been laid out.
  ///
  /// On ARCore the field of view passed here is a placeholder until the first
  /// frame reports the one its projection actually uses - see
  /// [_onVisualStatusChanged].
  void onViewportMeasured(int widthPx, int heightPx, double horizontalFovDeg) {
    if (widthPx <= 0 || heightPx <= 0) return;
    _viewport = (widthPx, heightPx);
    final fov = _vio?.status.value.horizontalFovDeg ?? horizontalFovDeg;
    _setIntrinsics(widthPx, heightPx, fov);
  }

  void _setIntrinsics(int widthPx, int heightPx, double horizontalFovDeg) {
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

  /// One frame of ARCore-measured camera motion, already in true east-north.
  void _onVisualMotion(double dEast, double dNorth, int timestampMs) {
    final moved = _stabilizer.onVisualMotion(dEast: dEast, dNorth: dNorth, timestampMs: timestampMs);
    if (moved == null) return;
    _moveAgent(moved.position);
    // The pose listener redraws on this same frame; no rebuild here.
  }

  void _onVisualStatusChanged() {
    final status = _vio!.status.value;
    if (status.failed) {
      visualFailed.value = true;
      return;
    }
    if (_wasTracking && !status.tracking) _aligner.reset();
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

  /// "I'm at the access point": the one action this screen asks for.
  ///
  /// GNSS under a roof or beside a tree line is several metres out, and close
  /// to a boundary a few metres is the difference between the line in front of
  /// you and the line beside you. The access point is a surveyed point the
  /// agent can physically stand on, so standing there and saying so replaces
  /// the receiver's opinion outright. On the ARCore path it also becomes the
  /// anchor of the walk alignment, so every step away from it refines the
  /// direction, with nothing more to tap.
  void pinToAccessPoint() {
    final plot = value.plot;
    if (plot == null || !value.canPin) return;
    final now = _lastLocation?.timestampMs;
    if (now == null) {
      value = value.copyWith(message: () => 'Waiting for a location fix');
      return;
    }
    final pinned = _stabilizer.pinTo(plot.accessPoint, timestampMs: now);
    _moveAgent(pinned.position);
    if (_vio?.sessionPosition case final session?) {
      _aligner.anchor(session, plot.accessPoint);
      _lockFromWalk();
    }
    final locked = _sensors.pose.headingStatus.value.confidence != HeadingConfidence.unreliable;
    final gpsUsable = (_lastLocation?.accuracyM ?? double.infinity) <= maxAlignmentFixAccuracyM;
    _rebuildOverlay(value.copyWith(
      pinned: true,
      stationary: true,
      accuracyM: _stabilizer.uncertaintyM,
      message: () => locked
          ? 'At the access point - plot placed'
          : gpsUsable
              ? 'At the access point - walk a few steps to set direction'
              : 'At the access point - GPS weak here, direction is from the compass',
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
    if (unlocked) value = value.copyWith(message: () => 'Direction set from your walk');
  }

  /// Landmark snap: the agent has the crosshair on the plot's access point.
  ///
  /// Both endpoints are known, so the true bearing is computable outright - one
  /// tap and the heading is pinned to within a couple of degrees, no walking
  /// required. [crosshairXPx] allows for a crosshair that is not dead centre.
  void snapToAccessPoint({double? crosshairXPx}) {
    final plot = value.plot;
    if (plot == null) return;
    // From the position the overlay is drawn from, never the raw fix. The
    // snap's promise is "the access point lands under the crosshair", and it
    // only keeps it if the bearing is taken from the same point the plot is
    // projected from. Taken from the raw fix - ±90 m indoors - every tap
    // computed a different bearing from a different wild position, and
    // tapping repeatedly walked the plot round the agent in a circle.
    final agent = _agentPosition;
    if (agent == null) {
      value = value.copyWith(message: () => 'Waiting for a location fix');
      return;
    }
    // Too close comes first: standing on the access point, there is nothing
    // to aim at, whatever the position is worth.
    final range = distanceM(agent, plot.accessPoint);
    if (range < minSnapDistanceM) {
      value = value.copyWith(message: () => 'Step 10 m away from the access point, aim at it, then tap');
      return;
    }
    // A bearing from an uncertain position is only as good as the position:
    // ±15 m at 14 m away is ±47°. Refuse rather than lock a guess.
    final uncertainty = _stabilizer.uncertaintyM;
    if (toDegrees(math.atan2(uncertainty, range)) > maxSnapPositionErrorDeg) {
      value = value.copyWith(message: () => 'GPS too weak here (±${uncertainty.round()} m). Use "I\'m at the access point" first');
      return;
    }
    final intrinsics = _intrinsics;
    final offsetDeg =
        crosshairXPx != null && intrinsics != null ? horizontalAngleOffsetDeg(crosshairXPx, intrinsics) : 0.0;

    final heading = headingFromLandmarkSnap(agent, plot.accessPoint, offsetDeg);
    if (heading == null) return;
    _sensors.pose.applyHeadingFix(heading, HeadingSource.landmarkSnap);
    value = value.copyWith(message: () => 'Heading locked');
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
    //
    // On the ARCore path the walk alignment does the same job better - any
    // path, not just straight ones - so the two are not left to fight.
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
    // Raw fix, like course over ground: calibrating the step length against
    // positions the steps themselves have already moved would be circular.
    _stepCalibration.onFix(sample.position, sample.accuracyM);
    final pinned = _stabilizer.pinned;

    if (stabilized.stationary) {
      _worstStationaryShiftM = math.max(_worstStationaryShiftM, stabilized.shiftM);
    }

    final plotNow = value.plot;
    final distanceToAccess =
        plotNow == null ? null : distanceM(sample.position, plotNow.accessPoint).round();
    _rebuildOverlay(value.copyWith(
      accessPointDistanceM: () => distanceToAccess,
      // Once pinned, the receiver's ±90 m is not the position's error any more.
      accuracyM: pinned ? math.min(sample.accuracyM, _stabilizer.uncertaintyM) : sample.accuracyM,
      hasFix: true,
      stationary: stabilized.stationary,
      pinned: pinned,
    ));
  }

  void _onPoseChanged() {
    _pose = _sensors.pose.pose.value;
    _rebuildOverlay();
    _syncPlacement();
  }

  /// What the native renderer was last given, to send only real changes.
  Object? _sentSceneKey;
  WorldPlacement? _sentPlacement;

  /// Sends the plot geometry to the ARCore renderer when what it draws has
  /// changed: the plot, the health layer or raster, or the heading confidence
  /// that sets its colour.
  void _syncScene(ArUiState state) {
    if (!state.visual) return;
    final plot = state.plot;
    if (plot == null) return;
    final confidence = state.headingStatus?.confidence ?? HeadingConfidence.unreliable;
    final layer = state.effectiveHealthLayer;
    final health = state.health;
    final key = (plot.id, layer, identityHashCode(health), confidence, plot.colourIndex);
    if (key == _sentSceneKey) return;
    _sentSceneKey = key;
    final scene = buildWorldScene(
      ring: plot.ring,
      origin: plot.centroid,
      cells: health?.cells ?? const [],
      layer: layer,
      // Always the plot's own colour, never the grey of the sensor path: in a
      // white office or under a pale sky a grey translucent wall is simply
      // invisible, and an agent who cannot see the plot cannot judge it. The
      // heading chip carries the confidence instead.
      tintArgb: plotColour(plot.colourIndex).argb,
      alpha: math.max(0.85, overlayConfidenceAlpha(confidence)),
    );
    unawaited(_container.platform.arSetScene(scene.toMessage()));
  }

  /// Tells the ARCore renderer where the plot stands in its session.
  ///
  /// Only when the geo-registration moves - a pin, a heading lock, a drift
  /// correction. Walking does not change it: the agent's position and
  /// ARCore's camera move together.
  void _syncPlacement() {
    final vio = _vio;
    final plot = value.plot;
    final agent = _agentPosition;
    if (vio == null || plot == null || agent == null) return;
    final session = vio.sessionPosition;
    final yaw = vio.yawOffsetDeg;
    if (session == null || yaw == null) return;
    final next = placePlot(plotOrigin: plot.centroid, agent: agent, sessionCamera: session, yawOffsetDeg: yaw);
    final sent = _sentPlacement;
    if (sent != null && next.isCloseTo(sent)) return;
    _sentPlacement = next;
    unawaited(_container.platform.arSetPlacement(next.toList()));
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
        eyeHeight: _vio?.eyeHeightM ?? eyeHeightM,
      );
      final health = _buildHealth(state, frame, agent, _pose.deviceToEnu, intrinsics);
      this.frame.value = ArFrame(
        overlay,
        health,
        guide: state.pinned ? null : _guide(plot, agent),
        agent: agent,
        headingDeg: _pose.headingDeg,
      );

      final edge = overlay.edgeDistanceM.toInt();
      final hidden = health?.hiddenCellCount ?? 0;
      if (state.mode != overlay.mode || state.edgeDistanceM != edge || state.hiddenCellCount != hidden) {
        state = state.copyWith(mode: overlay.mode, edgeDistanceM: edge, hiddenCellCount: hidden);
      }
    }
    _syncScene(state);
    if (!identical(state, value)) value = state;
  }

  AccessGuide _guide(Plot plot, LatLng agent) => AccessGuide(
        distanceM(agent, plot.accessPoint),
        angleDifferenceDeg(_pose.headingDeg, bearingDeg(agent, plot.accessPoint)),
      );

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
    }
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
