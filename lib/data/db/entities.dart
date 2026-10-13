// Cache rows, column for column the same as the Kotlin app's Room schema
// (version 3), so a device upgrading from that build keeps its cached plots.

/// A plot as cached on the device. Mirrors the web tool's `plots` table.
///
/// The boundary is stored as the raw GeoJSON ring so the cache is a faithful copy
/// of what the server sent; it is parsed into metres once per AR session, against
/// the agent's own local frame.
class PlotEntity {
  const PlotEntity({
    required this.id,
    required this.name,
    required this.ringJson,
    required this.centroidLat,
    required this.centroidLng,
    required this.accessLat,
    required this.accessLng,
    required this.areaSqM,
    required this.landmarkNote,
    required this.colourIndex,
    required this.createdAt,
    required this.syncedAtMs,
  });

  factory PlotEntity.fromMap(Map<String, Object?> m) => PlotEntity(
        id: m['id'] as String,
        name: m['name'] as String,
        ringJson: m['ringJson'] as String,
        centroidLat: (m['centroidLat'] as num).toDouble(),
        centroidLng: (m['centroidLng'] as num).toDouble(),
        accessLat: (m['accessLat'] as num).toDouble(),
        accessLng: (m['accessLng'] as num).toDouble(),
        areaSqM: (m['areaSqM'] as num).toDouble(),
        landmarkNote: m['landmarkNote'] as String,
        colourIndex: m['colourIndex'] as int,
        createdAt: m['createdAt'] as String,
        syncedAtMs: m['syncedAtMs'] as int,
      );

  final String id;
  final String name;

  /// JSON array of `[lng, lat]` pairs, closed, exactly as the API returned it.
  final String ringJson;
  final double centroidLat;
  final double centroidLng;
  final double accessLat;
  final double accessLng;
  final double areaSqM;
  final String landmarkNote;

  /// Palette slot 0-7, assigned server-side so neighbouring plots differ.
  final int colourIndex;
  final String createdAt;

  /// When this row was last pulled from the API, for showing cache age offline.
  final int syncedAtMs;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'ringJson': ringJson,
        'centroidLat': centroidLat,
        'centroidLng': centroidLng,
        'accessLat': accessLat,
        'accessLng': accessLng,
        'areaSqM': areaSqM,
        'landmarkNote': landmarkNote,
        'colourIndex': colourIndex,
        'createdAt': createdAt,
        'syncedAtMs': syncedAtMs,
      };
}

/// One cached crop-health snapshot, keyed by plot.
///
/// The raster is kept as the API's own JSON in [snapshotJson] rather than
/// exploded into a row per cell: it is read as a whole and never queried by
/// cell, it is replaced as a whole when new imagery lands, and keeping the
/// server's own shape means a new field in the snapshot is not a migration.
///
/// The two scalar columns beside it are the ones that answer a question about
/// the snapshot without opening it - how old the imagery is, and whether it is
/// real.
class HealthEntity {
  const HealthEntity({
    required this.plotId,
    required this.capturedOn,
    required this.synthetic,
    required this.snapshotJson,
    required this.syncedAtMs,
  });

  factory HealthEntity.fromMap(Map<String, Object?> m) => HealthEntity(
        plotId: m['plotId'] as String,
        capturedOn: m['capturedOn'] as String,
        synthetic: (m['synthetic'] as int) != 0,
        snapshotJson: m['snapshotJson'] as String,
        syncedAtMs: m['syncedAtMs'] as int,
      );

  final String plotId;

  /// Capture date of the imagery, so staleness is answerable without parsing.
  final String capturedOn;
  final bool synthetic;

  /// The whole snapshot, exactly as the API serialised it.
  final String snapshotJson;

  /// When this row was last pulled, for showing cache age offline.
  final int syncedAtMs;

  Map<String, Object?> toMap() => {
        'plotId': plotId,
        'capturedOn': capturedOn,
        'synthetic': synthetic ? 1 : 0,
        'snapshotJson': snapshotJson,
        'syncedAtMs': syncedAtMs,
      };
}

/// One sample of what the app actually saw in the field. No UI, ever.
///
/// This table is the point of shipping v0. It produces the real accuracy
/// distribution across the actual device fleet - how often heading is locked
/// versus compass-only, what horizontal accuracy the phones really report, how
/// long a session takes - and that distribution is what justifies (or kills)
/// phase 2. Guessing at it from a spec is how teams end up buying RTK receivers
/// they did not need.
class TelemetryEntity {
  const TelemetryEntity({
    this.id = 0,
    required this.timestampMs,
    required this.sessionId,
    required this.plotId,
    required this.lat,
    required this.lng,
    required this.reportedAccuracyM,
    required this.headingDeg,
    required this.headingSource,
    required this.headingConfidence,
    required this.renderMode,
    required this.anchorShiftM,
    required this.anchorAgeS,
    required this.deviceModel,
    required this.appVersion,
    required this.sessionDurationMs,
    this.uploaded = false,
  });

  factory TelemetryEntity.fromMap(Map<String, Object?> m) => TelemetryEntity(
        id: m['id'] as int,
        timestampMs: m['timestampMs'] as int,
        sessionId: m['sessionId'] as String,
        plotId: m['plotId'] as String,
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        reportedAccuracyM: (m['reportedAccuracyM'] as num).toDouble(),
        headingDeg: (m['headingDeg'] as num).toDouble(),
        headingSource: m['headingSource'] as String,
        headingConfidence: m['headingConfidence'] as String,
        renderMode: m['renderMode'] as String,
        anchorShiftM: (m['anchorShiftM'] as num).toDouble(),
        anchorAgeS: (m['anchorAgeS'] as num).toDouble(),
        deviceModel: m['deviceModel'] as String,
        appVersion: m['appVersion'] as String,
        sessionDurationMs: m['sessionDurationMs'] as int,
        uploaded: (m['uploaded'] as int) != 0,
      );

  final int id;
  final int timestampMs;

  /// Groups every row from one AR session, so drift can be read as a series.
  final String sessionId;
  final String plotId;
  final double lat;
  final double lng;

  /// Horizontal accuracy the receiver claimed, in metres.
  final double reportedAccuracyM;
  final double headingDeg;

  /// Wire name of a `HeadingSource`.
  final String headingSource;

  /// Wire name of a `HeadingConfidence`.
  final String headingConfidence;

  /// Wire name of a `RenderMode`, or `NONE`.
  final String renderMode;

  /// Largest single-update movement of the stabilised position recorded while
  /// the agent was standing still, in metres. If it creeps back above a few
  /// tens of centimetres on some handset, the overlay is drifting there and the
  /// fleet data will say so before a farmer does.
  final double anchorShiftM;

  /// Seconds since the local frame last re-anchored.
  final double anchorAgeS;
  final String deviceModel;
  final String appVersion;
  final int sessionDurationMs;
  final bool uploaded;

  /// Without `id`: the column autoincrements on insert.
  Map<String, Object?> toInsertMap() => {
        'timestampMs': timestampMs,
        'sessionId': sessionId,
        'plotId': plotId,
        'lat': lat,
        'lng': lng,
        'reportedAccuracyM': reportedAccuracyM,
        'headingDeg': headingDeg,
        'headingSource': headingSource,
        'headingConfidence': headingConfidence,
        'renderMode': renderMode,
        'anchorShiftM': anchorShiftM,
        'anchorAgeS': anchorAgeS,
        'deviceModel': deviceModel,
        'appVersion': appVersion,
        'sessionDurationMs': sessionDurationMs,
        'uploaded': uploaded ? 1 : 0,
      };
}
