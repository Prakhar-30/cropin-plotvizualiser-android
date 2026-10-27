import 'dart:math' as math;

import '../geo/enu.dart';
import '../geo/linear.dart';
import '../geo/polygon_geometry.dart';
import '../geo/projection.dart';
import '../math_util.dart';
import 'overlay_geometry.dart';

/// Crop condition, as the field app uses it.
///
/// The web tool grades every plot in 3 m cells on three indices - crop
/// greenness (NDVI), crop vigour (NDRE) and water stress (LSWI) - and splits
/// each into the same three zones: normal, moderate, critical. It also groups
/// touching moderate-or-critical cells into **patches**, one per problem area.
///
/// In the field only the problem ground matters. Normal ground is not drawn at
/// all; moderate and critical cells are painted on the ground in yellow and red,
/// and each patch of them becomes one **drop point** - a tall pin standing on
/// the ground at the patch - visible across every nearby plot at once.
///
/// The zone edges and the patching live on the server, so the map and the phone
/// cannot disagree about which ground is red.

/// The three indices, in the order the UI offers them.
enum HealthIndex {
  ndvi('Crop greenness', 'NDVI'),
  ndre('Crop vigour', 'NDRE'),
  lswi('Water stress', 'LSWI');

  const HealthIndex(this.label, this.code);

  /// What the agent sees.
  final String label;

  /// The index's own name, for the curious.
  final String code;

  /// The key the API uses: `ndvi`, `ndre`, `lswi`.
  String get wireName => name;

  static HealthIndex? fromWire(String value) {
    for (final index in values) {
      if (index.wireName == value) return index;
    }
    return null;
  }
}

/// 0 normal, 1 moderate, 2 critical.
const int zoneNormal = 0;
const int zoneModerate = 1;
const int zoneCritical = 2;

/// One graded ground cell. Its zone on each index, in [HealthIndex] order.
class HealthCell {
  const HealthCell({required this.centroid, required this.ring, required this.zones});

  final LatLng centroid;

  /// Closed ground ring of the cell, already trimmed to the plot boundary.
  final List<LatLng> ring;

  /// One zone per [HealthIndex], in declaration order.
  final List<int> zones;

  int zoneFor(HealthIndex index) => index.index < zones.length ? zones[index.index] : zoneNormal;
}

/// A connected patch of moderate or critical ground for one index: one drop point.
class HealthPatch {
  const HealthPatch({
    required this.index,
    required this.rank,
    required this.zone,
    required this.centroid,
    required this.cellCount,
    required this.areaSqM,
  });

  final HealthIndex index;

  /// 1 is the worst patch of this index on its plot.
  final int rank;

  /// [zoneModerate] or [zoneCritical].
  final int zone;

  /// Where the drop point stands: on the patch's worst cells.
  final LatLng centroid;
  final int cellCount;
  final double areaSqM;
}

/// How tall a drop point stands, metres from the ground.
///
/// Taller than the 2.6 m boundary wall on purpose: the wall says where the
/// plot ends, the drop point says where to walk, and a target hidden behind
/// the fence between you and it is no target at all.
const double dropPointHeightM = 4.5;

/// Drop points beyond this are not drawn. Past a few hundred metres a pin is a
/// few pixels on the horizon and reads as noise, not as a place to go.
const double dropPointMaxRangeM = 300.0;

/// A drop point projected for the sensor fallback path.
class DropMarker {
  const DropMarker(this.base, this.top, this.zone, this.distanceM);

  final ScreenPoint base;
  final ScreenPoint top;
  final int zone;
  final double distanceM;
}

/// Projects the drop points of [patches] for one frame, far to near.
///
/// Used only without ARCore; with it, the native renderer draws them in the
/// camera's own GL frame.
List<DropMarker> buildDropMarkers({
  required Iterable<HealthPatch> patches,
  required EnuFrame frame,
  required Enu eye,
  required Mat3 enuToDevice,
  required CameraIntrinsics intrinsics,
  double eyeHeight = eyeHeightM,
  double maxRangeM = dropPointMaxRangeM,
}) {
  final markers = <DropMarker>[];
  for (final patch in patches) {
    final ground = frame.toEnu(patch.centroid, -eyeHeight);
    final distanceM = hypot(ground.east - eye.east, ground.north - eye.north);
    if (distanceM > maxRangeM) continue;
    final base = projectDevice(toDevice(ground, eye, enuToDevice), intrinsics);
    final top = projectDevice(
      toDevice(Enu(ground.east, ground.north, ground.up + dropPointHeightM), eye, enuToDevice),
      intrinsics,
    );
    if (base == null || top == null) continue;
    markers.add(DropMarker(base, top, patch.zone, distanceM));
  }
  markers.sort((a, b) => b.distanceM.compareTo(a.distanceM));
  return markers;
}

/// Drop points of one index across many plots, nearest [limit] within range.
///
/// Many plots can mean many patches; the nearest are the ones the agent can
/// walk to now, and drawing hundreds of pins on the horizon helps nobody.
List<HealthPatch> nearbyPatches(
  Iterable<HealthPatch> patches,
  LatLng agent,
  HealthIndex index, {
  double maxRangeM = dropPointMaxRangeM,
  int limit = 60,
}) {
  final frame = EnuFrame(agent);
  final scored = <(HealthPatch, double)>[];
  for (final patch in patches) {
    if (patch.index != index) continue;
    final d = frame.toEnu(patch.centroid).groundRange;
    if (d <= maxRangeM) scored.add((patch, d));
  }
  scored.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (patch, _) in scored.take(math.max(0, limit))) patch];
}

/// Ground cells beyond this are not drawn on the sensor path. A 3 m square
/// further off is a sliver on the horizon; the drop point says it is there.
const double cellMaxRangeM = 120.0;

/// A moderate or critical ground cell projected for the sensor fallback path.
class CellPolygon {
  const CellPolygon(this.points, this.zone, this.distanceM);

  final List<ScreenPoint> points;
  final int zone;
  final double distanceM;
}

/// Projects the moderate and critical cells of [index] for one frame, far to
/// near, clipped to the near plane so a cell under the agent's feet still
/// draws.
///
/// Used only without ARCore; with it, the native renderer draws the cells in
/// the camera's own GL frame.
List<CellPolygon> buildCellPolygons({
  required Iterable<HealthCell> cells,
  required HealthIndex index,
  required EnuFrame frame,
  required Enu eye,
  required Mat3 enuToDevice,
  required CameraIntrinsics intrinsics,
  double eyeHeight = eyeHeightM,
  double maxRangeM = cellMaxRangeM,
}) {
  final out = <CellPolygon>[];
  for (final cell in cells) {
    final zone = cell.zoneFor(index);
    if (zone < zoneModerate) continue;
    final centre = frame.toEnu(cell.centroid);
    final distanceM = hypot(centre.east - eye.east, centre.north - eye.north);
    if (distanceM > maxRangeM) continue;
    final ring = openRing([for (final p in cell.ring) frame.toEnu(p, -eyeHeight)]);
    if (ring.length < 3) continue;
    final points = projectVisible(
      clipToNearPlane([for (final p in ring) toDevice(p, eye, enuToDevice)]),
      intrinsics,
    );
    if (points.length >= 3) out.add(CellPolygon(points, zone, distanceM));
  }
  out.sort((a, b) => b.distanceM.compareTo(a.distanceM));
  return out;
}
