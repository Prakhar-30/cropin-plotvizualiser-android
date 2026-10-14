import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/geo/arcore_pose.dart';
import '../core/geo/enu.dart';
import '../core/geo/projection.dart';
import '../core/heading/heading_fusion.dart';
import '../core/heading/heading_model.dart';
import '../platform/clock.dart';
import '../platform/native_platform.dart';
import 'pose_source.dart';

/// What visual tracking is doing right now, for the UI and the overlay.
class VioStatus {
  const VioStatus({required this.tracking, required this.failure, this.horizontalFovDeg, this.failed = false});

  final bool tracking;
  final ArTrackingFailure failure;

  /// The session could not run at all - it failed to open, or no frame has
  /// arrived for [VioPoseSource.frameTimeout]. The screen falls back to the
  /// sensors when this is set; it is never cleared.
  final bool failed;

  /// Of the preview as ARCore shows it; null before the first frame.
  final double? horizontalFovDeg;

  @override
  bool operator ==(Object other) =>
      other is VioStatus &&
      other.tracking == tracking &&
      other.failure == failure &&
      other.horizontalFovDeg == horizontalFovDeg &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(tracking, failure, horizontalFovDeg, failed);
}

/// Pose from ARCore motion tracking, with the heading pinned to true north by
/// the same [HeadingFusion] the sensor-only path uses.
///
/// ARCore's yaw is arbitrary - fixed by however the phone was held when the
/// session started - but visually tracked, so it drifts far less than the gyro
/// and is immune to magnetic disturbance. That is exactly the role the game
/// rotation vector plays on the sensor path, so it slots in as the carrier: a
/// walk lock or a landmark snap fixes the offset to true north, and the
/// magnetometer only trims slow drift within its ceiling.
///
/// What the sensor path never had is [onMotion]: how far the camera actually
/// moved, frame to frame, to centimetres, rotated into true east-north-up.
/// That is what keeps the boundary standing where it is while the agent walks
/// up to it - no step-length error, and sideways or backwards steps count too.
class VioPoseSource implements PoseSource {
  VioPoseSource(
    this._platform, {
    HeadingFusion? fusion,
    int Function()? clockMs,
    this.frameTimeout = const Duration(seconds: 6),
  })  : _fusion = fusion ?? HeadingFusion(),
        _clockMs = clockMs ?? monotonicMs {
    _headingStatus = ValueNotifier(HeadingStatus.from(_fusion.estimate(_clockMs())));
  }

  final NativePlatform _platform;
  final HeadingFusion _fusion;
  final int Function() _clockMs;

  final ValueNotifier<DevicePose> _pose = ValueNotifier(DevicePose.unknown);
  late final ValueNotifier<HeadingStatus> _headingStatus;
  final ValueNotifier<VioStatus> status =
      ValueNotifier(const VioStatus(tracking: false, failure: ArTrackingFailure.none));

  /// Camera displacement in true ENU between consecutive tracked frames, with
  /// the frame time on the fixes' clock.
  void Function(double dEast, double dNorth, int timestampMs)? onMotion;

  /// How long without any frame - tracked or not - before the session is
  /// declared failed. ARCore sends a frame per camera image even while it is
  /// still initialising, so silence this long means it is not running.
  final Duration frameTimeout;

  StreamSubscription<ArCoreFrame>? _frames;
  Timer? _watchdog;
  int _lastFrameAtMs = 0;
  StreamSubscription<RotationSample>? _magnetic;
  Enu? _lastPosition;

  @override
  ValueListenable<DevicePose> get pose => _pose;

  @override
  ValueListenable<HeadingStatus> get headingStatus => _headingStatus;

  @override
  void start() {
    if (status.value.failed) return;
    _frames ??= _platform.arFrames.listen(_onFrame, onError: (Object error) {
      debugPrint('PlotFinder: ARCore failed ($error)');
      _fail();
    });
    _armWatchdog();
    // The magnetometer still has a job - the drift trim and the last-resort
    // heading - so the magnetic rotation vector keeps flowing. The game vector
    // is ignored: ARCore is the carrier now.
    _magnetic ??= _platform.rotationSamples.listen((sample) {
      if (!sample.isGame) _fusion.onMagneticHeading(cameraHeadingDeg(sample.matrix), _clockMs());
    });
  }

  @override
  void stop() {
    _frames?.cancel();
    _frames = null;
    _watchdog?.cancel();
    _watchdog = null;
    _magnetic?.cancel();
    _magnetic = null;
    _lastPosition = null;
  }

  @override
  void applyHeadingFix(double bearingDeg, HeadingSource source) {
    _fusion.onFix(bearingDeg, source, _clockMs());
  }

  void _armWatchdog() {
    _lastFrameAtMs = _clockMs();
    _watchdog ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_clockMs() - _lastFrameAtMs > frameTimeout.inMilliseconds) _fail();
    });
  }

  void _fail() {
    _watchdog?.cancel();
    _watchdog = null;
    status.value = VioStatus(tracking: false, failure: status.value.failure, failed: true);
  }

  void _onFrame(ArCoreFrame frame) {
    if (status.value.failed) return;
    _lastFrameAtMs = _clockMs();
    status.value = VioStatus(
      tracking: frame.tracking,
      failure: frame.failure,
      horizontalFovDeg: frame.horizontalFovDeg,
    );
    if (!frame.tracking) {
      // Motion across a tracking gap is not measured, only guessed - and
      // ARCore may resume in a shifted world frame. Start a fresh baseline.
      _lastPosition = null;
      return;
    }

    final now = _clockMs();
    final carrier = frame.carrierHeadingDeg;
    _fusion.onCarrierHeading(carrier, now);
    final estimate = _fusion.estimate(now);
    final corrected = withHeading(frame.deviceToArEnu, estimate.headingDeg);

    final last = _lastPosition;
    _lastPosition = frame.position;
    if (last != null) {
      final offset = angleDifferenceDeg(carrier, estimate.headingDeg);
      final moved = arEnuToEnu(
        Enu(frame.position.east - last.east, frame.position.north - last.north),
        offset,
      );
      onMotion?.call(moved.east, moved.north, frame.timestampMs);
    }

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
