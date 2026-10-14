import 'dart:math' as math;

import '../geo/enu.dart';
import 'heading_model.dart';

/// Holds a heading once something trustworthy has established it.
///
/// Two attitude streams come in:
///
///  - the **carrier**, a gyro-dominant heading with no magnetic reference. It is
///    smooth and disturbance-proof but its absolute yaw is arbitrary and drifts.
///  - the **magnetic** heading, which knows where north is but is wrong by 15-25
///    degrees anywhere near steel or a running motor.
///
/// A fix - a walked segment or a landmark snap - pins the carrier to true north
/// by storing the offset between them. From then on the heading is carried by the
/// gyro, and the magnetometer is allowed only to trim slow drift, at a long time
/// constant and with a hard ceiling on total authority. That ceiling matters: an
/// unbounded trim would let a magnetically disturbed site drag a good lock onto
/// the neighbouring field slowly enough that nobody notices it happening.
///
/// Pure: no sensors, no clock of its own. Every method takes the time.
class HeadingFusion {
  HeadingFusion([this.config = const HeadingConfig()]);

  final HeadingConfig config;

  double? _carrierDeg;
  double? _magneticDeg;

  /// True heading minus carrier heading, as fixed by the last walk or snap.
  double _offsetDeg = 0.0;

  /// The offset at the moment of the fix, so drift can be bounded against it.
  double _offsetAtFixDeg = 0.0;

  HeadingSource? _fixSource;

  /// The fix's own error estimate, when it came with one; otherwise the
  /// source's typical error is used.
  double? _fixErrorDeg;
  int _fixAtMs = 0;
  int _lastMagneticUpdateMs = 0;

  /// Gyro-carried heading, from a rotation vector with no magnetic input.
  void onCarrierHeading(double headingDeg, int atMs) {
    _carrierDeg = normalizeDeg(headingDeg);
    // Drift trimming is driven from the carrier tick so it runs at a known
    // rate even when magnetic samples arrive irregularly.
    _applyMagneticDrift(atMs);
  }

  /// Magnetometer-referenced heading, used as a fallback and as a slow trim.
  void onMagneticHeading(double headingDeg, int atMs) {
    _magneticDeg = normalizeDeg(headingDeg);
    _applyMagneticDrift(atMs);
  }

  /// A walk lock or a landmark snap. This is the only thing that sets a heading.
  void onFix(double headingDeg, HeadingSource source, int atMs, {double? errorDeg}) {
    _fixErrorDeg = errorDeg;
    final carrier = _carrierDeg;
    _offsetDeg = carrier == null ? 0.0 : angleDifferenceDeg(carrier, headingDeg);
    _offsetAtFixDeg = _offsetDeg;
    _fixSource = source;
    _fixAtMs = atMs;
    _lastMagneticUpdateMs = atMs;
    // With no carrier yet, the fix itself is the heading until one arrives.
    if (carrier == null) _carrierDeg = normalizeDeg(headingDeg);
  }

  void _applyMagneticDrift(int atMs) {
    final carrier = _carrierDeg;
    final magnetic = _magneticDeg;
    if (carrier == null || magnetic == null) return;
    if (_fixSource == null) return;

    final previous = _lastMagneticUpdateMs;
    _lastMagneticUpdateMs = atMs;
    if (previous == 0 || atMs <= previous) return;

    final dtSeconds = (atMs - previous) / 1000.0;
    final alpha = 1.0 - math.exp(-dtSeconds / config.magneticDriftTimeConstantS);

    final targetOffset = angleDifferenceDeg(carrier, magnetic);
    final corrected = _offsetDeg + alpha * angleDifferenceDeg(_offsetDeg, targetOffset);

    // Never let the compass pull further than the ceiling from the fix.
    final drift = angleDifferenceDeg(_offsetAtFixDeg, corrected);
    final ceiling = config.maxMagneticDriftCorrectionDeg;
    _offsetDeg = _offsetAtFixDeg + math.max(-ceiling, math.min(ceiling, drift));
  }

  HeadingEstimate estimate(int atMs) {
    final source = _fixSource;
    final ageMs = source == null ? 0 : math.max(0, atMs - _fixAtMs);

    if (source != null && ageMs <= config.lockTtlMs) {
      final carrier = _carrierDeg ?? 0.0;
      final confidence =
          ageMs <= config.lockFreshMs ? HeadingConfidence.locked : HeadingConfidence.holding;
      // A carried heading is only as good as its fix plus whatever drift
      // the compass has been allowed to introduce since.
      final drift = angleDifferenceDeg(_offsetAtFixDeg, _offsetDeg).abs();
      return HeadingEstimate(
        headingDeg: normalizeDeg(carrier + _offsetDeg),
        source: source,
        confidence: confidence,
        ageMs: ageMs,
        expectedErrorDeg: (_fixErrorDeg ?? source.typicalErrorDeg) + drift,
      );
    }

    // No fix, or the lock expired: the compass is all that is left, and the
    // UI is expected to grey the overlay out and ask for a few steps.
    return HeadingEstimate(
      headingDeg: _magneticDeg ?? _carrierDeg ?? 0.0,
      source: HeadingSource.magnetometer,
      confidence: HeadingConfidence.unreliable,
      ageMs: ageMs,
      expectedErrorDeg: HeadingSource.magnetometer.typicalErrorDeg,
    );
  }
}
