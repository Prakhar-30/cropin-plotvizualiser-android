import '../math_util.dart';
import 'enu.dart';

/// Where to anchor the AR view on the ground, without asking anyone.
///
/// The old flow had the agent walk to a surveyed access point and say so. Here
/// every plot's boundary is the anchor: its corners are known coordinates, and
/// so is every point on the straight edge between two adjacent corners. The
/// point of all nearby boundaries closest to where GPS puts the agent - a corner,
/// or a point computed on an edge - is treated as where they stand, once they
/// are within [autoSnapDistanceM] of it.
///
/// What this buys and what it does not, stated plainly: the snap point comes
/// from the same GPS fix, so it cannot remove GPS error - an agent 6 m from the
/// boundary by GPS may really be 2 m or 10 m from it. What it does is pin the
/// session to one fixed point on the plot's own geometry, after which ARCore
/// carries every step from there and GPS is reduced to a slow drift correction:
/// the overlay stops swimming with each new fix. Standing on the boundary when
/// the snap happens makes it exact.

/// Snap once GPS puts the agent this close to any plot boundary.
const double autoSnapDistanceM = 10.0;

/// After moving this far from the last snap point, another boundary may snap
/// the session again - the agent has walked on to the next plot.
const double resnapAfterM = 60.0;

class BoundaryPoint {
  const BoundaryPoint({required this.ringIndex, required this.point, required this.distanceM});

  /// Which of the rings it lies on.
  final int ringIndex;

  /// The point itself: a corner, or a point on the edge between two corners.
  final LatLng point;

  /// Ground distance from the query position.
  final double distanceM;
}

/// The point on any of [rings] closest to [at], or null with no usable ring.
///
/// Each edge is the straight segment between two adjacent corners; the closest
/// point on it is the perpendicular foot, clamped to the segment - so it is
/// either a corner or a point computed between two.
BoundaryPoint? nearestBoundaryPoint(List<List<LatLng>> rings, LatLng at) {
  final frame = EnuFrame(at);
  BoundaryPoint? best;
  for (var r = 0; r < rings.length; r++) {
    final ring = [for (final p in rings[r]) frame.toEnu(p)];
    if (ring.length < 2) continue;
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
      final dE = b.east - a.east;
      final dN = b.north - a.north;
      final lengthSq = dE * dE + dN * dN;
      // The query point is the frame origin, so (0,0) - a is just -a.
      final t = lengthSq < 1e-12 ? 0.0 : (-(a.east * dE + a.north * dN) / lengthSq).clamp(0.0, 1.0);
      final foot = Enu(a.east + t * dE, a.north + t * dN);
      final d = hypot(foot.east, foot.north);
      if (best == null || d < best.distanceM) {
        best = BoundaryPoint(ringIndex: r, point: frame.toLatLng(foot), distanceM: d);
      }
    }
  }
  return best;
}

/// Ground distance from [at] to the nearest edge of [ring], metres.
double distanceToRingM(List<LatLng> ring, LatLng at) =>
    nearestBoundaryPoint([ring], at)?.distanceM ?? double.infinity;

/// True when [at] lies inside [ring] (even-odd rule).
bool insideRing(List<LatLng> ring, LatLng at) {
  final frame = EnuFrame(at);
  final pts = [for (final p in ring) frame.toEnu(p)];
  var inside = false;
  for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    final a = pts[i];
    final b = pts[j];
    if ((a.north > 0) != (b.north > 0) && 0 < (b.east - a.east) * (0 - a.north) / (b.north - a.north) + a.east) {
      inside = !inside;
    }
  }
  return pts.length >= 3 && inside;
}
