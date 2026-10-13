import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/geo/enu.dart';
import '../core/heading/course_over_ground_detector.dart';
import '../platform/native_platform.dart';

/// Where the agent is.
///
/// Kept behind an interface for the same reason `PoseSource` is: simulation
/// mode substitutes a joystick for the GNSS receiver without any code above
/// this line knowing.
abstract interface class LocationSource {
  /// Null until the first fix arrives.
  ValueListenable<LocationSample?> get location;

  void start();
  void stop();
}

/// Assumed accuracy when a fix does not report one. Deliberately pessimistic:
/// this number sets the width of the near-mode band, and a band that is too wide
/// is an honest statement while one that is too narrow is a false claim.
const double defaultAccuracyM = 15.0;

/// Phone GNSS from the fused provider, one fix per second - see the native
/// side for why the rate is what it is.
///
/// No external receiver, no RTK, no NTRIP - phone only, by constraint.
class FusedLocationSource implements LocationSource {
  FusedLocationSource(this._platform);

  final NativePlatform _platform;
  final ValueNotifier<LocationSample?> _location = ValueNotifier(null);
  StreamSubscription<RawFix>? _subscription;

  @override
  ValueListenable<LocationSample?> get location => _location;

  @override
  void start() {
    if (_subscription != null) return;
    _subscription = _platform.fixes.listen((fix) => _location.value = toSample(fix));
  }

  @override
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// A missing bearing stays null: it is exactly the case the course-over-ground
  /// detector must reject rather than guess at.
  static LocationSample toSample(RawFix fix) => LocationSample(
        position: LatLng(fix.lat, fix.lng),
        bearingDeg: fix.bearingDeg,
        speedMps: fix.speedMps ?? 0.0,
        accuracyM: fix.accuracyM ?? defaultAccuracyM,
        timestampMs: fix.timestampMs,
      );
}
