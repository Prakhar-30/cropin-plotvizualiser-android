import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'entities.dart';

/// The offline cache, on sqflite.
///
/// The file name, table names, column names and `user_version` are exactly the
/// Kotlin app's Room database at version 3. Same applicationId, same
/// `databases/` directory, same file: a phone upgrading from the Kotlin build
/// opens its existing cache instead of starting empty. That matters because the
/// cache is the only copy of the plots an agent has once they are out of
/// signal, and wiping it on upgrade would strand someone mid-visit.
class AppDatabase {
  AppDatabase._(this._db);

  static const int schemaVersion = 3;

  final Database _db;

  late final PlotDao plots = PlotDao(_db);
  late final HealthDao health = HealthDao(_db);
  late final TelemetryDao telemetry = TelemetryDao(_db);

  Future<void> close() async {
    plots._changes.close();
    await _db.close();
  }

  /// [fileName] is the host's choice when embedded; the standalone example
  /// passes the Kotlin app's `plotfinder.db` to inherit its cache.
  static Future<AppDatabase> open(String fileName) async {
    final path = p.join(await getDatabasesPath(), fileName);
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, version) async {
        final batch = db.batch();
        batch.execute(_createPlots);
        batch.execute(_createTelemetry);
        batch.execute(_createHealth);
        await batch.commit(noResult: true);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await _migrate1To2(db);
        if (from < 3) await db.execute(_createHealth);
      },
    );
    return AppDatabase._(db);
  }

  static const String _createPlots = '''
    CREATE TABLE IF NOT EXISTS `plots` (
      `id` TEXT NOT NULL, `name` TEXT NOT NULL, `ringJson` TEXT NOT NULL,
      `centroidLat` REAL NOT NULL, `centroidLng` REAL NOT NULL,
      `accessLat` REAL NOT NULL, `accessLng` REAL NOT NULL,
      `areaSqM` REAL NOT NULL, `landmarkNote` TEXT NOT NULL,
      `colourIndex` INTEGER NOT NULL, `createdAt` TEXT NOT NULL,
      `syncedAtMs` INTEGER NOT NULL, PRIMARY KEY(`id`))''';

  static const String _createTelemetry = '''
    CREATE TABLE IF NOT EXISTS `telemetry` (
      `id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      `timestampMs` INTEGER NOT NULL, `sessionId` TEXT NOT NULL,
      `plotId` TEXT NOT NULL, `lat` REAL NOT NULL, `lng` REAL NOT NULL,
      `reportedAccuracyM` REAL NOT NULL, `headingDeg` REAL NOT NULL,
      `headingSource` TEXT NOT NULL, `headingConfidence` TEXT NOT NULL,
      `renderMode` TEXT NOT NULL, `anchorShiftM` REAL NOT NULL,
      `anchorAgeS` REAL NOT NULL, `deviceModel` TEXT NOT NULL,
      `appVersion` TEXT NOT NULL, `sessionDurationMs` INTEGER NOT NULL,
      `uploaded` INTEGER NOT NULL)''';

  /// Adds the crop-health raster cache. A pure addition: no existing column
  /// moves, so every cached boundary survives untouched.
  static const String _createHealth = '''
    CREATE TABLE IF NOT EXISTS `plot_health` (
      `plotId` TEXT NOT NULL, `capturedOn` TEXT NOT NULL,
      `synthetic` INTEGER NOT NULL, `snapshotJson` TEXT NOT NULL,
      `syncedAtMs` INTEGER NOT NULL, PRIMARY KEY(`plotId`))''';

  /// Adds the boundary colour and the stabiliser telemetry columns.
  ///
  /// Only reachable from a cache written by the earliest Kotlin build. Existing
  /// rows get colour slot 0 and zeroed telemetry, which is honest - those
  /// sessions genuinely did not measure anchor shift.
  static Future<void> _migrate1To2(Database db) async {
    const statements = [
      'ALTER TABLE plots ADD COLUMN colourIndex INTEGER NOT NULL DEFAULT 0',
      "ALTER TABLE telemetry ADD COLUMN sessionId TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE telemetry ADD COLUMN headingConfidence TEXT NOT NULL DEFAULT ''",
      'ALTER TABLE telemetry ADD COLUMN anchorShiftM REAL NOT NULL DEFAULT 0.0',
      'ALTER TABLE telemetry ADD COLUMN anchorAgeS REAL NOT NULL DEFAULT 0.0',
      "ALTER TABLE telemetry ADD COLUMN deviceModel TEXT NOT NULL DEFAULT ''",
      "ALTER TABLE telemetry ADD COLUMN appVersion TEXT NOT NULL DEFAULT ''",
    ];
    for (final sql in statements) {
      await db.execute(sql);
    }
  }
}

/// `?, ?, ?` for an `IN (...)` clause.
String _placeholders(int n) => List.filled(n, '?').join(', ');

class PlotDao {
  PlotDao(this._db);

  final Database _db;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Every cached plot, by name, re-emitted whenever the table changes.
  ///
  /// Subscribes to changes *before* the first query runs. Querying first and
  /// subscribing after would drop a sync that lands while that query is in
  /// flight, and the list would show the stale cache until the next one.
  /// sqflite runs queries in order, so emissions arrive in order too.
  Stream<List<PlotEntity>> observeAll() {
    late final StreamController<List<PlotEntity>> out;
    StreamSubscription<void>? changes;
    Future<void> emit() async {
      final rows = await _all();
      if (!out.isClosed) out.add(rows);
    }

    out = StreamController<List<PlotEntity>>(
      onListen: () {
        changes = _changes.stream.listen((_) => emit());
        emit();
      },
      onCancel: () => changes?.cancel(),
    );
    return out.stream;
  }

  Future<List<PlotEntity>> _all() async =>
      (await _db.query('plots', orderBy: 'name')).map(PlotEntity.fromMap).toList();

  Future<PlotEntity?> findById(String id) async {
    final rows = await _db.query('plots', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : PlotEntity.fromMap(rows.first);
  }

  /// Replaces the cache in one transaction. A half-written cache is worse than a
  /// stale one: the agent is standing in a field with no signal, and a plot that
  /// vanished mid-sync cannot be fetched again.
  Future<void> replaceAll(List<PlotEntity> plots) async {
    await _db.transaction((txn) async {
      final keep = [for (final p in plots) p.id];
      if (keep.isEmpty) {
        await txn.delete('plots');
      } else {
        await txn.delete('plots', where: 'id NOT IN (${_placeholders(keep.length)})', whereArgs: keep);
      }
      final batch = txn.batch();
      for (final plot in plots) {
        batch.insert('plots', plot.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    _changes.add(null);
  }
}

class HealthDao {
  HealthDao(this._db);

  final Database _db;

  Future<HealthEntity?> findByPlot(String plotId) async {
    final rows = await _db.query('plot_health', where: 'plotId = ?', whereArgs: [plotId]);
    return rows.isEmpty ? null : HealthEntity.fromMap(rows.first);
  }

  Future<void> upsert(HealthEntity row) =>
      _db.insert('plot_health', row.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);

  /// Drops rasters for plots that no longer exist, so the cache cannot hold a
  /// raster for a boundary it can no longer draw - which would be a coloured
  /// patch of ground with nothing containing it.
  Future<void> deleteMissing(List<String> keepIds) async {
    if (keepIds.isEmpty) {
      await _db.delete('plot_health');
    } else {
      await _db.delete(
        'plot_health',
        where: 'plotId NOT IN (${_placeholders(keepIds.length)})',
        whereArgs: keepIds,
      );
    }
  }
}

class TelemetryDao {
  TelemetryDao(this._db);

  final Database _db;

  Future<void> insert(TelemetryEntity row) => _db.insert('telemetry', row.toInsertMap());

  Future<List<TelemetryEntity>> pending({int limit = 200}) async => (await _db.query(
        'telemetry',
        where: 'uploaded = 0',
        orderBy: 'timestampMs',
        limit: limit,
      ))
          .map(TelemetryEntity.fromMap)
          .toList();

  Future<void> markUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    await _db.update(
      'telemetry',
      {'uploaded': 1},
      where: 'id IN (${_placeholders(ids.length)})',
      whereArgs: ids,
    );
  }
}
