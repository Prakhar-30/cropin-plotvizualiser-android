import 'dart:math' as math;

import '../geo/enu.dart';
import '../geo/linear.dart';
import '../geo/polygon_geometry.dart';
import '../geo/projection.dart';
import '../math_util.dart';
import 'overlay_geometry.dart';

/// Paints the crop-health raster onto the ground.
///
/// The boundary answers "where is the plot"; this answers "which part of it do I
/// need to walk to". Both are drawn from the same pose, in the same ENU frame,
/// against the same ground plane - a health patch computed in its own frame
/// would sit metres away from the boundary that is supposed to contain it, and
/// the whole claim of the layer is that the brown ground is *inside this plot*.
///
/// Every cell arrives already trimmed to the boundary by the API (see
/// `clipToBoundary` in `@plot/shared`), so nothing here has to clip against the
/// ring. That trimming happens once, server-side, rather than sixty times a
/// second on a phone.

/// One graded ground cell. 0 healthy to 3 critical; see `severityColour`.
///
/// Only what is drawn is carried. The raw index value is deliberately absent:
/// nothing on this screen shows an NDVI number, the band is what decides the
/// colour, and a field parsed a few hundred times per sync to be discarded is
/// work the phone should not be doing.
class HealthCell {
  const HealthCell({required this.severity, required this.centroid, required this.ring});

  final int severity;

  /// Used for range culling before any projection happens.
  final LatLng centroid;

  /// Closed ground ring of the cell, already trimmed to the plot boundary.
  final List<LatLng> ring;
}

/// A cluster of stressed cells worth a walk. [rank] 1 is the worst.
class HealthHotspot {
  const HealthHotspot({required this.rank, required this.severity, required this.centroid});

  final int rank;
  final int severity;
  final LatLng centroid;
}

/// How much of the raster to draw.
///
/// [stress] is the default, and the reason is the whole point of the feature: a
/// plot is mostly healthy, so painting every cell covers the crop the agent came
/// to look at with a green wash and buries the two patches that matter. Hiding
/// band 0 leaves the stressed ground standing alone against the real field.
/// [all] exists because "is that patch bad, or is the whole field like that?" is
/// a fair question, and it can only be answered by showing the healthy cells too.
enum HealthLayer {
  off('Health off'),
  stress('Problem areas'),
  all('All cells');

  const HealthLayer(this.label);

  final String label;

  HealthLayer next() => HealthLayer.values[(index + 1) % HealthLayer.values.length];

  /// The lowest band this layer draws.
  int get minSeverity => this == HealthLayer.all ? 0 : 1;
}

/// Cells beyond this are dropped.
///
/// Not a performance number - a legibility one. A 10 m cell at 150 m subtends
/// about 60 px of width and a handful of pixels of height, because the ground
/// plane is nearly edge-on at that range. Past here the raster stops being a map
/// of the field and becomes a coloured smear along the horizon, which reads as
/// an error in the overlay rather than as information.
const double healthMaxRangeM = 150.0;

/// Hard cap on drawn cells, nearest first.
///
/// A 40 ha plot at 10 m resolution is 4000 cells, and projecting every one of
/// them on a 50 Hz pose stream drops frames on the mid-range hardware this is
/// built for. The nearest 500 are the ones the agent can actually stand on.
const int maxHealthPatches = 500;

/// Ground cells nearer than this are faded, but never below [minPatchOpacity].
///
/// A cell the agent is standing in has its far edge 10 m out and its near edge
/// behind the camera, so it projects across the entire lower half of the frame.
/// At full strength that is a coloured floor blocking the view of the crop -
/// which is the thing the agent came to inspect. Fading the foreground keeps the
/// grading readable without painting over the answer it is pointing at.
const double patchFadeStartM = 6.0;

/// Floor for the foreground fade.
///
/// Raised sharply after field testing, because this number was not acting alone.
/// Three independent factors multiply into the final alpha - the severity band,
/// this fade, and the heading-confidence tier - and each looked reasonable in
/// isolation. Together, a stressed patch underfoot on a carried heading came out
/// at 0.42 x 0.35 x 0.6, which is nine percent: invisible on a phone screen in
/// daylight, and indistinguishable from the feature being broken.
///
/// Compounding multipliers is the trap. Every one of them still exists, because
/// each says something true, but the floors are now set so their product stays
/// legible at the worst combination rather than only at the best.
const double minPatchOpacity = 0.62;

/// How tall a hotspot marker stands. Matches the boundary corner posts.
const double hotspotMarkerHeightM = vertexPostHeightM;

/// One graded cell, projected and ready to fill.
class HealthPatch {
  const HealthPatch(this.corners, this.severity, this.nearestDistanceM, this.opacity);

  final List<ScreenPoint> corners;
  final int severity;
  final double nearestDistanceM;
  final double opacity;
}

/// A stem standing at a hotspot centroid, so the target is visible over the crop.
class HealthMarker {
  const HealthMarker(this.base, this.top, this.rank, this.severity, this.distanceM);

  final ScreenPoint base;
  final ScreenPoint top;
  final int rank;
  final int severity;
  final double distanceM;
}

class HealthOverlay {
  const HealthOverlay(this.patches, this.markers, this.hiddenCellCount);

  final List<HealthPatch> patches;
  final List<HealthMarker> markers;

  /// Cells inside range that this layer chose not to draw, for the readout.
  final int hiddenCellCount;
}

/// One cell, in metres. [centre] is on the ground plane, like [ring].
class PreparedCell {
  const PreparedCell(this.severity, this.centre, this.ring);

  final int severity;
  final Enu centre;
  final List<Enu> ring;
}

class PreparedHotspot {
  const PreparedHotspot(this.rank, this.severity, this.at);

  final int rank;
  final int severity;
  final Enu at;
}

/// The raster converted to metres, once.
///
/// Degrees-to-metres is trigonometry per point, and a few hundred cells at four
/// corners each is a few thousand conversions - cheap once, wasteful sixty times
/// a second. Nothing here depends on where the camera is looking, only on where
/// the frame is anchored, so it survives every pose update and is rebuilt only
/// when the agent walks far enough for [EnuFrame] to re-anchor.
class HealthField {
  HealthField(List<HealthCell> cells, List<HealthHotspot> hotspots, this._frame)
      : cells = _prepareCells(cells, _frame),
        hotspots = [
          for (final h in hotspots) PreparedHotspot(h.rank, h.severity, _frame.toEnu(h.centroid, _groundUp)),
        ];

  static const double _groundUp = -eyeHeightM;

  final EnuFrame _frame;
  final List<PreparedCell> cells;
  final List<PreparedHotspot> hotspots;

  static List<PreparedCell> _prepareCells(List<HealthCell> cells, EnuFrame frame) {
    final prepared = <PreparedCell>[];
    for (final cell in cells) {
      final ring = openRing([for (final p in cell.ring) frame.toEnu(p, _groundUp)]);
      if (ring.length < 3) continue;
      prepared.add(PreparedCell(cell.severity, frame.toEnu(cell.centroid, _groundUp), ring));
    }
    return prepared;
  }

  /// True when this field was built against [other] and can still be reused.
  bool matches(EnuFrame other) => identical(_frame, other);

  bool get isEmpty => cells.isEmpty && hotspots.isEmpty;
}

/// Projects the visible part of the raster for one frame.
///
/// Patches come back sorted far-to-near for the same reason the walls do:
/// translucent fills composited in grid order let a far cell paint over a near
/// one, and on a ground plane that reads as the grading being scrambled.
HealthOverlay buildHealthOverlay({
  required HealthField field,
  required Enu eye,
  required Mat3 enuToDevice,
  required CameraIntrinsics intrinsics,
  required HealthLayer layer,
  double maxRangeM = healthMaxRangeM,
  int maxPatches = maxHealthPatches,
}) {
  if (layer == HealthLayer.off) return const HealthOverlay([], [], 0);

  final maxRangeSq = maxRangeM * maxRangeM;
  var hidden = 0;

  // Range-cull and band-filter before any projection. Squared distance on the
  // ground plane only - the eye-height offset is a constant 1.6 m and cannot
  // move a cell across a 150 m threshold.
  final candidates = <(PreparedCell, double)>[];
  for (final cell in field.cells) {
    final dEast = cell.centre.east - eye.east;
    final dNorth = cell.centre.north - eye.north;
    final distanceSq = dEast * dEast + dNorth * dNorth;
    if (distanceSq > maxRangeSq) continue;
    if (cell.severity < layer.minSeverity) {
      hidden++;
      continue;
    }
    candidates.add((cell, distanceSq));
  }

  // Keep the nearest, then draw them back to front. Capping by distance rather
  // than by grid order means the cells that survive are the ones underfoot,
  // which is where the agent is about to look.
  candidates.sort((a, b) => a.$2.compareTo(b.$2));
  final kept = candidates.take(maxPatches).toList()..sort((a, b) => b.$2.compareTo(a.$2));

  final patches = <HealthPatch>[];
  for (final (cell, _) in kept) {
    final projected = projectVisible(
      clipToNearPlane([for (final p in cell.ring) toDevice(p, eye, enuToDevice)]),
      intrinsics,
    );
    if (projected.length < 3) continue;

    final nearest = projected.map((p) => p.distanceM).reduce(math.min);
    patches.add(HealthPatch(
      projected,
      cell.severity,
      nearest,
      linearFade(nearest, 0.0, patchFadeStartM, floor: minPatchOpacity),
    ));
  }

  // Markers ignore the band filter: a hotspot is by definition stressed, and
  // it is the walk-to target, so it stays visible in every layer that is on.
  final markers = <HealthMarker>[];
  for (final hotspot in field.hotspots) {
    final distanceM = hypot(hotspot.at.east - eye.east, hotspot.at.north - eye.north);
    if (distanceM > maxRangeM) continue;

    final base = projectDevice(toDevice(hotspot.at, eye, enuToDevice), intrinsics);
    if (base == null) continue;
    final top = projectDevice(
      toDevice(
        Enu(hotspot.at.east, hotspot.at.north, hotspot.at.up + hotspotMarkerHeightM),
        eye,
        enuToDevice,
      ),
      intrinsics,
    );
    if (top == null) continue;

    markers.add(HealthMarker(base, top, hotspot.rank, hotspot.severity, distanceM));
  }
  markers.sort((a, b) => b.distanceM.compareTo(a.distanceM));

  return HealthOverlay(patches, markers, hidden);
}
