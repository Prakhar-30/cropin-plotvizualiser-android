import '../core/geo/enu.dart';
import '../core/render/health_geometry.dart';

/// A plot in the form the rest of the app uses: degrees in, metres computed later.
class Plot {
  const Plot({
    required this.id,
    required this.name,
    required this.ring,
    required this.centroid,
    required this.accessPoint,
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
  final LatLng accessPoint;
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

/// A crop-health snapshot for one plot, as the app uses it.
///
/// [HealthCell] and [HealthHotspot] are the `core/render` types rather than
/// copies of them. Mirroring a four-field shape across the data and render
/// layers buys nothing but a mapping function and the chance for the two to
/// disagree about what `severity` means.
class PlotHealth {
  const PlotHealth({
    required this.plotId,
    required this.capturedOn,
    required this.indexName,
    required this.synthetic,
    required this.note,
    required this.cellSizeM,
    required this.cells,
    required this.hotspots,
    required this.syncedAtMs,
  });

  final String plotId;

  /// Capture date of the underlying imagery, `YYYY-MM-DD`.
  final String capturedOn;

  /// Which index was graded, e.g. `ndvi`.
  final String indexName;

  /// True when the values are a stand-in rather than measured imagery.
  ///
  /// Surfaced in the AR view, not just logged. An agent acting on a made-up
  /// NDVI is the one failure mode of this feature that costs real money, and
  /// the overlay is convincing enough that nothing but an explicit label will
  /// stop it being believed.
  final bool synthetic;

  /// The server's own wording for any caveat, shown verbatim - see [synthetic].
  final String note;
  final double cellSizeM;
  final List<HealthCell> cells;
  final List<HealthHotspot> hotspots;
  final int syncedAtMs;

  /// Cells at or above the "stressed" band. The count the readout leads with.
  int get stressedCellCount => cells.where((c) => c.severity >= 2).length;

  /// Ground area graded as stressed or worse.
  double get stressedAreaSqM => stressedCellCount * cellSizeM * cellSizeM;
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
