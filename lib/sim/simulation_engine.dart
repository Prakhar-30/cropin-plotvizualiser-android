import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/geo/enu.dart';
import '../core/geo/projection.dart';
import '../core/heading/course_over_ground_detector.dart';
import '../core/heading/heading_fusion.dart';
import '../core/heading/heading_model.dart';
import '../core/math_util.dart';
import '../location/location_source.dart';
import '../platform/clock.dart';
import '../pose/pose_source.dart';

/// Debug-only stand-in for the GNSS receiver and the attitude sensors.
///
/// Drives the AR overlay around a synthetic plot from a desk, which is worth
/// days: the failure modes this app exists to handle only appear in a field, and
/// "walk 20 m north to see whether the lock works" is not a debug cycle.
///
/// It implements both [LocationSource] and [PoseSource] from one piece of state,
/// because they are two views of the same simulated agent - splitting them would
/// mean keeping a position in two places and letting them disagree.
///
/// Two deliberate error injections:
///
///  - [gnssErrorM] displaces the *reported* position from the true one, which
///    shifts the whole overlay by a few metres. Barely visible at 80 m, which is
///    the point.
///  - [headingErrorDeg] is added to the reported heading after fusion, standing
///    in for residual error whatever the source. At 80 m, 20 degrees puts the
///    boundary 29 m sideways - on the neighbour's field. That is the slide that
///    explains why the heading architecture exists.
class SimulationEngine implements LocationSource, PoseSource {
  SimulationEngine(LatLng startAt, {HeadingFusion? fusion, int Function()? clockMs})
      : _truePosition = startAt,
        _fusion = fusion ?? HeadingFusion(),
        _clockMs = clockMs ?? monotonicMs {
    _headingStatus = ValueNotifier(HeadingStatus.from(_fusion.estimate(_clockMs())));
  }

  final HeadingFusion _fusion;
  final int Function() _clockMs;

  LatLng _truePosition;
  double _trueHeadingDeg = 0.0;
  double _pitchDeg = 0.0;

  /// Where the agent really is, before any injected error.
  LatLng get truePosition => _truePosition;

  /// Where the phone is really aimed, before any injected error.
  double get trueHeadingDeg => _trueHeadingDeg;

  double get pitchDeg => _pitchDeg;

  /// Injected horizontal position error, in metres.
  double gnssErrorM = 0.0;

  /// Accuracy the simulated receiver claims, which sets the near-mode band width.
  double reportedAccuracyM = 6.0;

  /// Injected heading error, in degrees. The demo dial.
  double headingErrorDeg = 0.0;

  final ValueNotifier<LocationSample?> _location = ValueNotifier(null);
  final ValueNotifier<DevicePose> _pose = ValueNotifier(DevicePose.unknown);
  late final ValueNotifier<HeadingStatus> _headingStatus;

  int _lastMoveAtMs = 0;

  @override
  ValueListenable<LocationSample?> get location => _location;

  @override
  ValueListenable<DevicePose> get pose => _pose;

  @override
  ValueListenable<HeadingStatus> get headingStatus => _headingStatus;

  @override
  void start() {
    _publishLocation(null, 0.0);
    _publishPose();
  }

  @override
  void stop() {}

  @override
  void applyHeadingFix(double bearingDeg, HeadingSource source) {
    _fusion.onFix(bearingDeg, source, _clockMs());
    _publishPose();
  }

  /// Steps the agent by a ground velocity, as an on-screen joystick would.
  ///
  /// A real walk is what produces a course-over-ground lock, so the simulated
  /// fix carries a bearing and a speed derived from the movement itself - the
  /// detector upstream cannot tell this apart from a real walk, which is the
  /// whole point.
  void move(double eastMps, double northMps) {
    final now = _clockMs();
    final previous = _lastMoveAtMs;
    _lastMoveAtMs = now;
    final dt = previous == 0 ? 0.0 : math.min((now - previous) / 1000.0, 0.5);

    final speed = hypot(eastMps, northMps);
    if (dt <= 0.0 || speed <= 0.0) {
      _publishLocation(null, 0.0);
      return;
    }

    _truePosition = EnuFrame(_truePosition).toLatLng(Enu(eastMps * dt, northMps * dt));
    _publishLocation(normalizeDeg(toDegrees(math.atan2(eastMps, northMps))), speed);
  }

  /// Aims the phone. The joystick's rotation axis, or the heading slider.
  void aim(double headingDeg, {double? pitchDeg}) {
    _trueHeadingDeg = normalizeDeg(headingDeg);
    if (pitchDeg != null) _pitchDeg = pitchDeg;
    final now = _clockMs();
    // The simulated attitude sensors see the true aim; injected error is
    // applied on the way out, so fusion behaves exactly as it does in the field.
    _fusion.onCarrierHeading(_trueHeadingDeg, now);
    _fusion.onMagneticHeading(_trueHeadingDeg, now);
    _publishPose();
  }

  /// Teleports the agent, for jumping to a plot without walking there.
  void teleport(LatLng to) {
    _truePosition = to;
    _lastMoveAtMs = 0;
    _publishLocation(null, 0.0);
  }

  /// Re-publishes with the current error settings, after a slider moves.
  void refresh() {
    final last = _location.value;
    _publishLocation(last?.bearingDeg, last?.speedMps ?? 0.0);
    _publishPose();
  }

  void _publishLocation(double? bearingDeg, double speedMps) {
    // The injected error is applied along a fixed north-east bearing so the
    // overlay shifts in a repeatable direction rather than jittering.
    final displaced = EnuFrame(_truePosition).toLatLng(Enu(
      gnssErrorM * math.cos(toRadians(45.0)),
      gnssErrorM * math.sin(toRadians(45.0)),
    ));
    _location.value = LocationSample(
      position: displaced,
      bearingDeg: bearingDeg,
      speedMps: speedMps,
      accuracyM: reportedAccuracyM,
      timestampMs: _clockMs(),
    );
  }

  void _publishPose() {
    final now = _clockMs();
    final estimate = _fusion.estimate(now);
    final reportedHeading = normalizeDeg(estimate.headingDeg + headingErrorDeg);
    final attitude = deviceToEnuFromOrientation(reportedHeading, _pitchDeg);

    _pose.value = DevicePose(
      deviceToEnu: attitude,
      headingDeg: reportedHeading,
      pitchDeg: cameraPitchDeg(attitude),
      rollDeg: cameraRollDeg(attitude),
      timestampMs: now,
    );
    _headingStatus.value = HeadingStatus.from(estimate);
  }
}
