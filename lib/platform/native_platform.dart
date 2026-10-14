import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/geo/camera_geometry.dart';
import '../core/geo/linear.dart';

/// One rotation-vector sample, already a display-remapped rotation matrix.
class RotationSample {
  const RotationSample({required this.isGame, required this.isCarrier, required this.matrix});

  /// From `TYPE_GAME_ROTATION_VECTOR`: gyro and accelerometer, no magnetometer.
  final bool isGame;

  /// True for the one stream that carries the drawn attitude.
  final bool isCarrier;

  /// Device-to-ENU, row-major, as `SensorManager` produces it.
  final Mat3 matrix;
}

/// One fix from the fused provider, with absent fields left null.
class RawFix {
  const RawFix({
    required this.lat,
    required this.lng,
    required this.bearingDeg,
    required this.speedMps,
    required this.accuracyM,
    required this.timestampMs,
  });

  final double lat;
  final double lng;
  final double? bearingDeg;
  final double? speedMps;
  final double? accuracyM;
  final int timestampMs;
}

class DeviceInfo {
  const DeviceInfo(this.model, this.appVersion);

  final String model;
  final String appVersion;

  static const DeviceInfo unknown = DeviceInfo('unknown', '');
}

/// The Dart end of `PlotFinderPlugin.kt`.
///
/// One instance per app. Each event stream is created once and shared: an
/// EventChannel has a single native listener, so two screens opening their own
/// streams on it would steal each other's fixes.
class NativePlatform {
  NativePlatform();

  // Namespaced to this package, so they cannot collide with a host app's own
  // channels.
  static const String _prefix = 'com.fieldar.plot_finder';
  static const MethodChannel _methods = MethodChannel('$_prefix/platform');
  static const EventChannel _rotation = EventChannel('$_prefix/rotation');
  static const EventChannel _location = EventChannel('$_prefix/location');
  static const EventChannel _acceleration = EventChannel('$_prefix/acceleration');

  late final Stream<RotationSample> rotationSamples =
      _rotation.receiveBroadcastStream().map(_toRotation).handleError(_log);

  late final Stream<RawFix> fixes = _location.receiveBroadcastStream().map(_toFix).handleError(_log);

  /// Accelerometer magnitude in m/s², gravity included, stamped on the fixes'
  /// clock: `(magnitude, timestampMs)`.
  late final Stream<(double, int)> acceleration =
      _acceleration.receiveBroadcastStream().map(_toAcceleration).handleError(_log);

  /// The rear camera's geometry for a preview of [previewAspect], or the
  /// flagged fallback when the characteristics cannot be read.
  Future<CameraGeometry> cameraGeometry({double? previewAspect}) async {
    try {
      final raw = await _methods.invokeMapMethod<String, Object?>('cameraGeometry');
      if (raw == null) return _fallback(previewAspect);
      final geometry = CameraGeometry.fromSensor(
        sensorWidthMm: (raw['sensorWidthMm']! as num).toDouble(),
        sensorHeightMm: (raw['sensorHeightMm']! as num).toDouble(),
        focalMm: (raw['focalMm']! as num).toDouble(),
        previewAspect: previewAspect,
      );
      // The single number the whole projection scales on. Worth being able to
      // read off a real device rather than inferring it from a wrong overlay.
      debugPrint('PlotFinder: portrait hFOV=${geometry.portraitHorizontalFovDeg.toStringAsFixed(1)} deg '
          'aspect=${geometry.portraitAspect.toStringAsFixed(3)}');
      return geometry;
    } on Object catch (e) {
      debugPrint('PlotFinder: camera characteristics unreadable ($e) - using fallback FOV');
      return _fallback(previewAspect);
    }
  }

  /// True when camera and fine location are both granted.
  Future<bool> hasPermissions() async {
    try {
      return await _methods.invokeMethod<bool>('hasPermissions') ?? false;
    } on Object {
      return false;
    }
  }

  /// Asks for camera and location, and reports whether both were granted.
  Future<bool> requestPermissions() async {
    try {
      return await _methods.invokeMethod<bool>('requestPermissions') ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _methods.invokeMethod<bool>('openAppSettings');
    } on Object {
      // Nothing useful to do; the button simply does nothing.
    }
  }

  Future<DeviceInfo> deviceInfo() async {
    try {
      final raw = await _methods.invokeMapMethod<String, Object?>('deviceInfo');
      if (raw == null) return DeviceInfo.unknown;
      return DeviceInfo(raw['model'] as String? ?? 'unknown', raw['appVersion'] as String? ?? '');
    } on Object {
      return DeviceInfo.unknown;
    }
  }

  static CameraGeometry _fallback(double? previewAspect) => previewAspect == null
      ? CameraGeometry.fallback
      : CameraGeometry.fallback.withPreviewAspect(previewAspect);

  static RotationSample _toRotation(Object? event) {
    final map = event! as Map<Object?, Object?>;
    final m = map['m']! as List<Object?>;
    return RotationSample(
      isGame: map['game']! as bool,
      isCarrier: map['carrier']! as bool,
      matrix: Mat3.fromRowMajor([for (final v in m) (v! as num).toDouble()]),
    );
  }

  static (double, int) _toAcceleration(Object? event) {
    final values = event! as List<Object?>;
    return ((values[1]! as num).toDouble(), (values[0]! as num).toInt());
  }

  static RawFix _toFix(Object? event) {
    final map = event! as Map<Object?, Object?>;
    double? opt(String key) => (map[key] as num?)?.toDouble();
    return RawFix(
      lat: (map['lat']! as num).toDouble(),
      lng: (map['lng']! as num).toDouble(),
      bearingDeg: opt('bearing'),
      speedMps: opt('speed'),
      accuracyM: opt('accuracy'),
      timestampMs: (map['timestampMs']! as num).toInt(),
    );
  }

  static void _log(Object error) => debugPrint('PlotFinder: platform stream error: $error');
}
