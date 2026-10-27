import '../core/geo/enu.dart';
import '../core/render/health_geometry.dart';

/// A plot in the form the rest of the app uses: degrees in, metres computed later.
class Plot {
  const Plot({
    required this.id,
    required this.name,
    required this.ring,
    required this.centroid,
    required this.areaSqM,
    required this.landmarkNote,
    required this.colourIndex,
    required this.createdAt,
    required this.syncedAtMs,
  });

  final String id;
  final String name;

  /// Closed ring of WGS84 positions, in the order the surveyor drew them.
  final List<LatLng> ring;
  final LatLng centroid;
  final double areaSqM;
  final String landmarkNote;

  /// Palette slot; see `plotColour`.
  final int colourIndex;
  final String createdAt;
  final int syncedAtMs;

  double get areaHectares => areaSqM / 10000.0;

  /// Corners the surveyor placed, ignoring the ring's closing repeat.
  int get cornerCount => ring.length >= 2 && ring.first == ring.last ? ring.length - 1 : ring.length;
}

/// A crop-condition snapshot for one plot, as the app uses it.
///
/// [HealthCell] and [HealthPatch] are the `core/render` types rather than
/// copies of them, so the data and render layers cannot disagree about what a
/// zone means.
class PlotHealth {
  const PlotHealth({
    required this.plotId,
    required this.capturedOn,
    required this.synthetic,
    required this.note,
    required this.cellSizeM,
    required this.cells,
    required this.patches,
    required this.syncedAtMs,
  });

  final String plotId;

  /// Capture date of the underlying imagery, `YYYY-MM-DD`.
  final String capturedOn;

  /// True when the values are demonstration values rather than measured
  /// imagery. Surfaced in the AR view, not just logged.
  final bool synthetic;

  /// The server's own wording for any caveat, shown verbatim.
  final String note;
  final double cellSizeM;
  final List<HealthCell> cells;

  /// Moderate and critical patches on every index: the drop points.
  final List<HealthPatch> patches;
  final int syncedAtMs;

  /// Patches of one index, worst first.
  List<HealthPatch> patchesFor(HealthIndex index) => [
        for (final p in patches)
          if (p.index == index) p,
      ];
}

/// What a sync produced.
sealed class SyncResult {
  const SyncResult();
}

class SyncSuccess extends SyncResult {
  const SyncSuccess(this.plotCount, {this.healthCount = 0, this.widenedToEverything = false});

  final int plotCount;

  /// How many rasters came with them. Reported separately because it can
  /// legitimately be lower than [plotCount], and a silent shortfall would look
  /// like plots that are simply healthy.
  final int healthCount;

  /// True when nothing was within the radius and the whole set was taken.
  final bool widenedToEverything;
}

class SyncFailed extends SyncResult {
  const SyncFailed(this.reason);

  final String reason;
}
