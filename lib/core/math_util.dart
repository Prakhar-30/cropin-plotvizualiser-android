import 'dart:math' as math;

/// The few numeric helpers `dart:math` leaves out. Kept in one place so every
/// file in `core` agrees on them.

double toRadians(double degrees) => degrees * math.pi / 180.0;

double toDegrees(double radians) => radians * 180.0 / math.pi;

/// sqrt(x^2 + y^2).
double hypot(double x, double y) => math.sqrt(x * x + y * y);

/// [value] limited to `[min, max]`. Unlike `num.clamp` it stays a `double`.
double clampDouble(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);
