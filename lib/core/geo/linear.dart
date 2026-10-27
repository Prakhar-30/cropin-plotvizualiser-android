import 'dart:math' as math;

/// The three-by-three linear algebra the overlay needs, and nothing more.
///
/// Deliberately free of Flutter imports: every line in `core/geo` runs under a
/// plain `dart test` so the projection can be tested against hand-computed
/// values.

class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get length => math.sqrt(x * x + y * y + z * z);

  @override
  bool operator ==(Object other) =>
      other is Vec3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// Row-major 3x3 matrix. `m01` is row 0, column 1.
class Mat3 {
  const Mat3(
    this.m00, this.m01, this.m02, //
    this.m10, this.m11, this.m12, //
    this.m20, this.m21, this.m22,
  );

  final double m00, m01, m02;
  final double m10, m11, m12;
  final double m20, m21, m22;

  static const Mat3 identity = Mat3(
    1.0, 0.0, 0.0, //
    0.0, 1.0, 0.0, //
    0.0, 0.0, 1.0,
  );

  /// Reads the row-major 9-element array `SensorManager` fills in.
  factory Mat3.fromRowMajor(List<double> a) {
    if (a.length < 9) {
      throw ArgumentError('rotation matrix needs 9 elements, got ${a.length}');
    }
    return Mat3(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
  }

  /// Rotation about the device x axis (screen right).
  factory Mat3.rotationX(double radians) {
    final c = math.cos(radians);
    final s = math.sin(radians);
    return Mat3(
      1.0, 0.0, 0.0, //
      0.0, c, -s, //
      0.0, s, c,
    );
  }

  /// Rotation about the device z axis (out of the screen).
  factory Mat3.rotationZ(double radians) {
    final c = math.cos(radians);
    final s = math.sin(radians);
    return Mat3(
      c, -s, 0.0, //
      s, c, 0.0, //
      0.0, 0.0, 1.0,
    );
  }

  Vec3 timesVec(Vec3 v) => Vec3(
        m00 * v.x + m01 * v.y + m02 * v.z,
        m10 * v.x + m11 * v.y + m12 * v.z,
        m20 * v.x + m21 * v.y + m22 * v.z,
      );

  Mat3 operator *(Mat3 o) => Mat3(
        m00 * o.m00 + m01 * o.m10 + m02 * o.m20,
        m00 * o.m01 + m01 * o.m11 + m02 * o.m21,
        m00 * o.m02 + m01 * o.m12 + m02 * o.m22,
        //
        m10 * o.m00 + m11 * o.m10 + m12 * o.m20,
        m10 * o.m01 + m11 * o.m11 + m12 * o.m21,
        m10 * o.m02 + m11 * o.m12 + m12 * o.m22,
        //
        m20 * o.m00 + m21 * o.m10 + m22 * o.m20,
        m20 * o.m01 + m21 * o.m11 + m22 * o.m21,
        m20 * o.m02 + m21 * o.m12 + m22 * o.m22,
      );

  /// For a rotation matrix this is also the inverse.
  Mat3 transpose() => Mat3(
        m00, m10, m20, //
        m01, m11, m21, //
        m02, m12, m22,
      );

  List<double> toRowMajor() => [m00, m01, m02, m10, m11, m12, m20, m21, m22];

  @override
  bool operator ==(Object other) =>
      other is Mat3 &&
      other.m00 == m00 && other.m01 == m01 && other.m02 == m02 &&
      other.m10 == m10 && other.m11 == m11 && other.m12 == m12 &&
      other.m20 == m20 && other.m21 == m21 && other.m22 == m22;

  @override
  int get hashCode => Object.hashAll(toRowMajor());
}
