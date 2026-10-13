import 'db/app_database.dart';
import 'db/entities.dart';
import 'net/dtos.dart';
import 'net/plot_api.dart';

/// Records what the app saw, and drains the queue when there is signal.
///
/// Writes are local and unconditional; uploads are best-effort and silent. A
/// failed upload is not an error the agent should ever see - the row simply stays
/// queued, which is why `uploaded` is a column rather than a delete.
class TelemetryRepository {
  TelemetryRepository(this._dao, this._api);

  final TelemetryDao _dao;
  final PlotApi _api;

  Future<void> record(TelemetryEntity row) => _dao.insert(row);

  /// Uploads queued rows. Returns how many made it, zero if offline.
  Future<int> syncPending() async {
    final pending = await _dao.pending();
    if (pending.isEmpty) return 0;
    try {
      await _api.uploadTelemetry([for (final row in pending) _toDto(row)]);
      await _dao.markUploaded([for (final row in pending) row.id]);
      return pending.length;
    } catch (_) {
      return 0;
    }
  }

  TelemetryDto _toDto(TelemetryEntity row) => TelemetryDto(
        timestampMs: row.timestampMs,
        sessionId: row.sessionId,
        plotId: row.plotId,
        lat: row.lat,
        lng: row.lng,
        accuracyM: row.reportedAccuracyM,
        headingDeg: row.headingDeg,
        headingSource: row.headingSource,
        headingConfidence: row.headingConfidence,
        renderMode: row.renderMode,
        anchorShiftM: row.anchorShiftM,
        anchorAgeS: row.anchorAgeS,
        deviceModel: row.deviceModel,
        appVersion: row.appVersion,
        sessionDurationMs: row.sessionDurationMs,
      );
}
