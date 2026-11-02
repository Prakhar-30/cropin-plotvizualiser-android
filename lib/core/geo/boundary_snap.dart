import 'dart:math' as math;

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
///
/// Was 10 m. Closer means the anchor is taken nearer the boundary, so less of
/// the GPS error between "where GPS says" and "the boundary point" is baked in;
/// it also means a weak fix may not get close enough to anchor at all, which is
/// why [steadyFix] below decides when a fix is good enough to try.
const double autoSnapDistanceM = 5.0;

/// Only fixes reporting at least this accuracy are used to anchor.
const double anchorMaxAccuracyM = 8.0;

/// The anchor averages the fixes of this long a window...
const int anchorWindowMs = 5000;

/// ...needs at least this many of them...
const int anchorMinFixes = 4;

/// ...and needs them to agree: none further than this from their average.
const double anchorMaxSpreadM = 4.0;

/// One GPS fix for the anchor, already carried forward to the present by the
/// motion measured since it was taken, so a walking agent's fixes agree.
class AnchorFix {
  const AnchorFix(this.position, this.accuracyM, this.timestampMs);

  final LatLng position;
  final double accuracyM;
  final int timestampMs;
}

/// Where to anchor from: the accuracy-weighted average of the recent [fixes],
/// or null while they are too few, too inaccurate or disagree.
///
/// One fix is a sample of the error, not of the position. Under trees the
/// receiver bounces between reflections, and a single fix taken at the wrong
/// moment fixed the whole session several metres out. Five seconds of fixes
/// that each claim better than [anchorMaxAccuracyM] and sit within
/// [anchorMaxSpreadM] of their mean are much less likely to share one bad
/// reflection - and when they do not agree, waiting is the honest answer.
LatLng? steadyFix(List<AnchorFix> fixes, int nowMs) {
  final recent = [
    for (final f in fixes)
      if (nowMs - f.timestampMs <= anchorWindowMs) f,
  ];
  if (recent.length < anchorMinFixes) return null;
  if (recent.any((f) => f.accuracyM > anchorMaxAccuracyM)) return null;

  final frame = EnuFrame(recent.last.position);
  var sumE = 0.0;
  var sumN = 0.0;
  var sumW = 0.0;
  final points = <Enu>[];
  for (final f in recent) {
    final p = frame.toEnu(f.position);
    final w = 1.0 / (f.accuracyM * f.accuracyM);
    points.add(p);
    sumE += p.east * w;
    sumN += p.north * w;
    sumW += w;
  }
  final mean = Enu(sumE / sumW, sumN / sumW);
  for (final p in points) {
    if (hypot(p.east - mean.east, p.north - mean.north) > anchorMaxSpreadM) return null;
  }
  return frame.toLatLng(mean);
}

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

/// A plot becomes "the one you are in" once you are this far inside its edge...
const double insideEnterM = 1.5;

/// ...and stops being it only once you are this far outside its edge.
///
/// The band between the two is what keeps the raised boundary from flickering
/// between two plots as you walk along the edge they share: GPS and the anchor
/// put you a metre or two either side of it from one second to the next.
const double insideLeaveM = 2.0;

/// The plot the agent is confirmed inside: [current] while they have not left
/// it by [insideLeaveM], otherwise the first plot of [rings] (by id) they are
/// at least [insideEnterM] inside, otherwise none.
String? confirmedInside(Map<String, List<LatLng>> rings, LatLng at, String? current) {
  final held = current == null ? null : rings[current];
  if (held != null && (insideRing(held, at) || distanceToRingM(held, at) < insideLeaveM)) return current;
  for (final MapEntry(key: id, value: ring) in rings.entries) {
    if (insideRing(ring, at) && distanceToRingM(ring, at) >= insideEnterM) return id;
  }
  return null;
}

/// A point inside [ring] to stand a plot's marker and label on: its [centroid]
/// when that is inside, otherwise the inside point furthest from any edge.
///
/// The centroid of an L-shaped or crescent plot can fall outside it - in the
/// neighbour's field, or on the track between them - and a marker there says
/// the wrong plot needs attention.
LatLng interiorPoint(List<LatLng> ring, LatLng centroid) {
  if (ring.length < 3 || insideRing(ring, centroid)) return centroid;
  final lats = [for (final p in ring) p.lat];
  final lngs = [for (final p in ring) p.lng];
  final south = lats.reduce(math.min);
  final north = lats.reduce(math.max);
  final west = lngs.reduce(math.min);
  final east = lngs.reduce(math.max);
  const steps = 16;
  LatLng? best;
  var bestDepth = -1.0;
  for (var i = 0; i < steps; i++) {
    for (var j = 0; j < steps; j++) {
      final p = LatLng(south + (i + 0.5) / steps * (north - south), west + (j + 0.5) / steps * (east - west));
      if (!insideRing(ring, p)) continue;
      final depth = distanceToRingM(ring, p);
      if (depth > bestDepth) {
        bestDepth = depth;
        best = p;
      }
    }
  }
  return best ?? centroid;
}
