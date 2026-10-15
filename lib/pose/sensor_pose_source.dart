import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/geo/linear.dart';
import '../core/geo/orientation_smoother.dart';
import '../core/geo/projection.dart';
import '../core/heading/heading_fusion.dart';
import '../core/heading/heading_model.dart';
import '../platform/clock.dart';
import '../platform/native_platform.dart';
import 'pose_source.dart';

/// Pose from the rotation vectors, with the heading replaced by whatever the
/// [HeadingFusion] currently trusts.
///
/// Two rotation sensors are used, for different jobs:
///
///  - `TYPE_ROTATION_VECTOR` knows where magnetic north is. Its heading feeds the
///    fusion as the low-weight drift trim and as the last-resort fallback.
///  - `TYPE_GAME_ROTATION_VECTOR` has no magnetometer input at all. Its heading is
///    the gyro carrier: arbitrary in absolute terms, but immune to a tractor
///    parked next to the agent. Where the device does not provide it, the
///    magnetic rotation vector carries instead, which is worse but never absent.
///
/// Pitch and roll always come from the sensors untouched. Only yaw is substituted.
class SensorPoseSource implements PoseSource {
  SensorPoseSource(this._platform, {HeadingFusion? fusion, int Function()? clockMs})
      : _fusion = fusion ?? HeadingFusion(),
        _clockMs = clockMs ?? monotonicMs {
    _headingStatus = ValueNotifier(HeadingStatus.from(_fusion.estimate(_clockMs())));
  }

  final NativePlatform _platform;
  final HeadingFusion _fusion;
  final int Function() _clockMs;

  final ValueNotifier<DevicePose> _pose = ValueNotifier(DevicePose.unknown);
  late final ValueNotifier<HeadingStatus> _headingStatus;

  /// Takes the shimmer out of the sensor stream. See [OrientationSmoother] -
  /// this is the difference between a boundary that sits on the ground and one
  /// that trembles a metre either side of it.
  final OrientationSmoother _orientation = OrientationSmoother();

  /// Latest attitude that carries pitch and roll, whichever sensor supplied it.
  Mat3? _latestAttitude;

  StreamSubscription<RotationSample>? _subscription;

  @override
  ValueListenable<DevicePose> get pose => _pose;

  @override
  ValueListenable<HeadingStatus> get headingStatus => _headingStatus;

  @override
  void start() {
    if (_subscription != null) return;
    _subscription = _platform.rotationSamples.listen(_onSample);
  }

  @override
  void stop() {
    _orientation.reset();
    _subscription?.cancel();
    _subscription = null;
  }

  @override
  void applyHeadingFix(double bearingDeg, HeadingSource source, {double? errorDeg}) {
    _fusion.onFix(bearingDeg, source, _clockMs(), errorDeg: errorDeg);
    _publish();
  }

  void _onSample(RotationSample sample) {
    final now = _clockMs();
    final raw = sample.matrix;

    // Exactly one stream is the carrier, and only the carrier is smoothed.
    //
    // This used to smooth whichever sample had just arrived, from either
    // sensor, into one shared filter - and that quietly destroyed the filter.
    // The two rotation vectors do not agree: the game vector's yaw origin is
    // arbitrary at boot, so the two attitudes sit tens of degrees apart and the
    // smoother saw a stream flipping between them a hundred times a second.
    // Its deviation measure saturated permanently, pinning the time constant at
    // its most agile and turning the smoothing off.
    //
    // Yaw hid the damage, because `withHeading` overwrites it downstream.
    // Pitch and roll did not, and pitch and roll are what tilt the ground
    // plane - which slides the whole overlay sideways across the field.

    // The magnetic sample contributes a heading and nothing else. It never
    // touches the smoother and never becomes the drawn attitude.
    if (!sample.isGame) {
      _fusion.onMagneticHeading(cameraHeadingDeg(raw), now);
    }

    if (!sample.isCarrier) return;

    // The heading fed to the fusion is taken from the *raw* sample: the fusion
    // has its own drift-trimming and lock logic, and filtering its input twice
    // would slow the response to a genuine turn without making the result any
    // steadier.
    _latestAttitude = _orientation.update(raw, now);
    _fusion.onCarrierHeading(cameraHeadingDeg(raw), now);

    // Published only on the carrier tick. Publishing on both streams emitted a
    // new pose about a hundred times a second, and every emission rebuilds the
    // overlay - several hundred ground cells reprojected - for a sample that
    // did not change the attitude at all.
    _publish();
  }

  void _publish() {
    final attitude = _latestAttitude;
    if (attitude == null) return;
    final now = _clockMs();
    final estimate = _fusion.estimate(now);
    final corrected = withHeading(attitude, estimate.headingDeg);

    _pose.value = DevicePose(
      deviceToEnu: corrected,
      headingDeg: estimate.headingDeg,
      pitchDeg: cameraPitchDeg(corrected),
      rollDeg: cameraRollDeg(corrected),
      timestampMs: now,
    );
    _headingStatus.value = HeadingStatus.from(estimate);
  }
}
