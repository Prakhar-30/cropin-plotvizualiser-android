import '../geo/enu.dart';

/// One GNSS fix, as the platform hands it over.
class LocationSample {
  const LocationSample({
    required this.position,
    required this.bearingDeg,
    required this.speedMps,
    required this.accuracyM,
    required this.timestampMs,
  });

  final LatLng position;

  /// `Location.bearing`, degrees clockwise from true north. Null when not moving.
  final double? bearingDeg;
  final double speedMps;
  final double accuracyM;
  final int timestampMs;
}

/// Tunables for what counts as "walked far enough in a straight enough line".
class CourseOverGroundConfig {
  const CourseOverGroundConfig({
    this.minSpeedMps = 0.7,
    this.minSegmentDistanceM = 20.0,
    this.minSamples = 5,
    this.maxBearingSpreadDeg = 8.0,
    this.maxAccuracyM = 25.0,
    this.maxSampleGapMs = 5000,
  });

  final double minSpeedMps;
  final double minSegmentDistanceM;
  final int minSamples;

  /// Mean absolute deviation of the bearings in the window. Above this the
  /// agent turned, and averaging the segment would produce a heading pointing
  /// at neither leg of the walk.
  final double maxBearingSpreadDeg;

  /// Fixes worse than this contribute more noise to the bearing than signal.
  final double maxAccuracyM;

  /// A gap this long means the fixes are no longer one continuous walk.
  final int maxSampleGapMs;
}

/// Turns a walked segment into a heading.
///
/// `Location.bearing` is derived from GNSS motion, not from the magnetic field,
/// so it is the one heading source in this app that a tractor, a transformer or a
/// steel gatepost cannot corrupt. The catch is that it is only meaningful while
/// the agent is actually walking in a straight line, so this class accumulates a
/// window and rejects it outright if the bearings inside it disagree - a segment
/// where the agent turned is worse than no segment at all, because averaging its
/// two legs gives a confident heading pointing between them.
///
/// Pure and clock-free: feed it samples, it returns a heading or null.
class CourseOverGroundDetector {
  CourseOverGroundDetector([this.config = const CourseOverGroundConfig()]);

  final CourseOverGroundConfig config;

  final List<LocationSample> _window = [];

  double _segmentDistanceM = 0.0;

  /// Metres of ground covered by the samples currently in the window.
  double get segmentDistanceM => _segmentDistanceM;

  int get sampleCount => _window.length;

  void reset() {
    _window.clear();
    _segmentDistanceM = 0.0;
  }

  /// Adds a fix and returns a locked heading when the window has become a valid
  /// straight segment. Returns null while the segment is still forming, and
  /// discards the window whenever the walk breaks.
  double? add(LocationSample sample) {
    final bearing = sample.bearingDeg;
    final usable = bearing != null &&
        sample.speedMps >= config.minSpeedMps &&
        sample.accuracyM <= config.maxAccuracyM;

    if (!usable) {
      // Standing still, or a fix too poor to trust: the walk is over.
      reset();
      return null;
    }

    final previous = _window.isEmpty ? null : _window.last;
    if (previous != null) {
      if (sample.timestampMs - previous.timestampMs > config.maxSampleGapMs) {
        reset();
      } else {
        _segmentDistanceM += distanceM(previous.position, sample.position);
      }
    }
    _window.add(sample);

    if (_segmentDistanceM < config.minSegmentDistanceM || _window.length < config.minSamples) {
      return null;
    }

    final stats = bearingStatistics([
      for (final s in _window)
        if (s.bearingDeg != null) s.bearingDeg!,
    ]);
    if (stats == null) return null;
    if (stats.spreadDeg > config.maxBearingSpreadDeg) {
      // The agent turned somewhere in this window. Throw it away and start
      // a fresh segment from the newest fix.
      final newest = _window.last;
      reset();
      _window.add(newest);
      return null;
    }

    reset();
    return stats.meanDeg;
  }
}
