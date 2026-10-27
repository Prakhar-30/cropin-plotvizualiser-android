import 'dart:math' as math;

import '../math_util.dart';
import 'enu.dart';

/// Plot geometry in the local metric frame.
///
/// The render mode switches on distance to the nearest **edge**, never to the
/// centroid: an elongated plot can have its centroid 60 m away while the agent is
/// standing on its boundary, and showing them a far-mode filled shape at that
/// point claims a precision the fix does not have.

/// Distance from a point to a line segment, all in metres.
double distanceToSegmentM(Enu point, Enu a, Enu b) {
  final abE = b.east - a.east;
  final abN = b.north - a.north;
  final lengthSq = abE * abE + abN * abN;

  // A degenerate edge collapses to its own endpoint.
  if (lengthSq == 0.0) return hypot(point.east - a.east, point.north - a.north);

  final t = ((point.east - a.east) * abE + (point.north - a.north) * abN) / lengthSq;
  final clamped = math.max(0.0, math.min(1.0, t));
  final closestE = a.east + clamped * abE;
  final closestN = a.north + clamped * abN;
  return hypot(point.east - closestE, point.north - closestN);
}

/// Distance from [point] to the closest boundary edge of [ring], in metres.
///
/// Zero when the point sits on the boundary, and positive both inside and
/// outside - the overlay cares how far the line is, not which side of it you are
/// standing on.
double distanceToNearestEdgeM(List<Enu> ring, Enu point) {
  final vertices = openRing(ring);
  if (vertices.isEmpty) return double.infinity;
  if (vertices.length == 1) {
    return hypot(point.east - vertices[0].east, point.north - vertices[0].north);
  }

  var nearest = double.infinity;
  for (var i = 0; i < vertices.length; i++) {
    final a = vertices[i];
    final b = vertices[(i + 1) % vertices.length];
    nearest = math.min(nearest, distanceToSegmentM(point, a, b));
  }
  return nearest;
}

/// Drops the repeated closing vertex a GeoJSON ring carries.
///
/// Left in place it produces a zero-length edge, which is harmless for distance
/// but draws a stray vertex post on top of another one.
List<Enu> openRing(List<Enu> ring) {
  if (ring.length < 2) return ring;
  final first = ring.first;
  final last = ring.last;
  final closed = hypot(first.east - last.east, first.north - last.north) < 1e-6;
  return closed ? ring.sublist(0, ring.length - 1) : ring;
}
