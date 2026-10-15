import '../core/geo/enu.dart';
import 'db/app_database.dart';
import 'net/dtos.dart';
import 'net/plot_api.dart';
import 'plot.dart';
import 'plot_mapping.dart';

/// The cache is the source of truth.
///
/// Every read goes to the database and nothing on a screen ever waits for the
/// network: rural sites have no data, and an app that degrades when the radio
/// drops is an app that does not work where it is used. Sync is a separate,
/// explicitly triggered action that refills the cache when there happens to be
/// signal.
class PlotRepository {
  PlotRepository(this._dao, this._healthDao, this._api);

  final PlotDao _dao;
  final HealthDao _healthDao;
  final PlotApi _api;

  Stream<List<Plot>> observePlots() =>
      _dao.observeAll().map((rows) => [for (final r in rows) r.toPlot()]);

  Future<Plot?> findById(String id) async => (await _dao.findById(id))?.toPlot();

  /// The cached crop-health raster for a plot, or null if none was ever pulled.
  ///
  /// Reads the cache only. The AR screen opens with the radio off as often as
  /// not, and blocking the overlay on a network call would mean the boundary
  /// waits for the raster - the boundary is the thing the agent came for.
  Future<PlotHealth?> healthFor(String plotId) async => (await _healthDao.findByPlot(plotId))?.toHealth();

  /// Pulls plots from the API into the cache.
  ///
  /// With an [around] position it fetches only what is within [radiusM], which
  /// is what a dispatched agent actually needs; without one it takes the lot,
  /// which is fine for a prototype's worth of plots.
  Future<SyncResult> sync({LatLng? around, int radiusM = 5000}) async {
    try {
      final List<PlotDto> nearby =
          around == null ? const [] : await _api.listPlotsNear('${around.lat},${around.lng}', radiusM);

      // Falling back to the whole set when nothing is within the radius. "0
      // plots near you" is indistinguishable on screen from "the sync failed",
      // and the honest reading of an empty radius is usually that the boundary
      // was drawn somewhere else - not that there is nothing to show.
      final dtos = nearby.isEmpty ? await _api.listPlots() : nearby;
      final fellBack = around != null && nearby.isEmpty && dtos.isNotEmpty;

      final ids = [for (final d in dtos) d.id];
      await _dao.replaceAll([for (final d in dtos) d.toEntity()]);
      await _healthDao.deleteMissing(ids);

      // Rasters are pulled after the boundaries are safely committed, and a
      // failure here is swallowed per plot. The health layer is an extra; a
      // sync that lands every boundary and misses one raster is a success.
      final healthCount = await _syncHealthFor(ids);

      return SyncSuccess(dtos.length, healthCount: healthCount, widenedToEverything: fellBack);
    } catch (e) {
      // Offline is the expected case, not an error worth shouting about. The
      // cached plots stay exactly as they were.
      return SyncFailed(_describe(e));
    }
  }

  /// Pulls the health raster for one plot on its own.
  ///
  /// Used when the agent opens a plot that synced before the health layer
  /// existed. Returns false when there was no signal, which the caller shows as
  /// "not cached" rather than as "this plot is healthy" - the difference
  /// matters and only the caller can word it.
  Future<bool> syncHealth(String plotId) async => await _syncHealthFor([plotId]) > 0;

  /// Fetches rasters concurrently, tolerating individual failures.
  ///
  /// Concurrent because these are independent round trips and a dispatched
  /// agent syncing a dozen plots over rural HSPA would otherwise wait a dozen
  /// latencies in a row. Each one is guarded separately: one plot whose raster
  /// 404s must not cost the other eleven.
  Future<int> _syncHealthFor(List<String> plotIds) async {
    final results = await Future.wait([
      for (final id in plotIds)
        () async {
          try {
            await _healthDao.upsert((await _api.health(id)).toEntity());
            return 1;
          } catch (_) {
            return 0;
          }
        }(),
    ]);
    return results.fold<int>(0, (a, b) => a + b);
  }

  static String _describe(Object e) {
    final text = e.toString();
    return text.isEmpty ? e.runtimeType.toString() : text;
  }
}
