import 'package:flutter/foundation.dart';

import '../core/geo/linear.dart';
import '../core/heading/heading_model.dart';

/// Where the phone is pointing.
///
/// [deviceToEnu] is the authoritative value: it is what the projection consumes,
/// and it already carries the fused heading rather than the magnetometer's. The
/// Euler angles are derived from it for the UI and the telemetry row - nothing
/// reconstructs the matrix from them.
class DevicePose {
  const DevicePose({
    required this.deviceToEnu,
    required this.headingDeg,
    required this.pitchDeg,
    required this.rollDeg,
    required this.timestampMs,
  });

  final Mat3 deviceToEnu;
  final double headingDeg;
  final double pitchDeg;
  final double rollDeg;
  final int timestampMs;

  static const DevicePose unknown = DevicePose(
    deviceToEnu: Mat3.identity,
    headingDeg: 0.0,
    pitchDeg: 0.0,
    rollDeg: 0.0,
    timestampMs: 0,
  );
}

/// How the current heading was arrived at, and how much to trust it.
class HeadingStatus {
  const HeadingStatus({
    required this.source,
    required this.confidence,
    required this.ageSeconds,
    required this.expectedErrorDeg,
  });

  factory HeadingStatus.from(HeadingEstimate estimate) => HeadingStatus(
        source: estimate.source,
        confidence: estimate.confidence,
        ageSeconds: estimate.ageSeconds,
        expectedErrorDeg: estimate.expectedErrorDeg,
      );

  final HeadingSource source;
  final HeadingConfidence confidence;

  /// Seconds since the last walk lock or landmark snap.
  final int ageSeconds;
  final double expectedErrorDeg;

  @override
  bool operator ==(Object other) =>
      other is HeadingStatus &&
      other.source == source &&
      other.confidence == confidence &&
      other.ageSeconds == ageSeconds &&
      other.expectedErrorDeg == expectedErrorDeg;

  @override
  int get hashCode => Object.hash(source, confidence, ageSeconds, expectedErrorDeg);
}

/// The seam ARCore would slot into later.
///
/// v0 is sensor-only on purpose. The far-field identification case needs no plane
/// detection and no visual odometry, and ARCore's Geospatial API is actively
/// wrong here: it depends on Google's Visual Positioning System, which needs
/// Street View coverage that farmland does not have, and it reports confident
/// accuracy figures while silently falling back to raw GPS.
///
/// An ARCore-backed implementation would satisfy this same interface, so nothing
/// above it has to change.
abstract interface class PoseSource {
  ValueListenable<DevicePose> get pose;
  ValueListenable<HeadingStatus> get headingStatus;

  /// Starts listening. Idempotent.
  void start();

  /// Stops listening and releases sensors.
  void stop();

  /// Pins the heading to a computed true bearing, as a landmark snap does.
  /// [bearingDeg] is the bearing of the camera axis, crosshair offset already
  /// subtracted.
  void applyHeadingFix(double bearingDeg, HeadingSource source);
}
