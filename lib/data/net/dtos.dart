// The companion web tool's wire format, exactly as it is served.
//
// Hand-written rather than generated: there are five small shapes, and the
// parse rules worth knowing - which fields are defaulted, and in which
// direction - read better as code than as annotations. Unknown keys are
// ignored throughout, as the Kotlin client's `ignoreUnknownKeys` did.

typedef Json = Map<String, dynamic>;

double _double(Object? v) => (v as num).toDouble();

int _int(Object? v) => (v as num).toInt();

class PolygonDto {
  const PolygonDto({required this.type, required this.coordinates});

  factory PolygonDto.fromJson(Json json) => PolygonDto(
        type: json['type'] as String,
        coordinates: [
          for (final ring in json['coordinates'] as List<dynamic>)
            [
              for (final pair in ring as List<dynamic>)
                [for (final v in pair as List<dynamic>) _double(v)],
            ],
        ],
      );

  final String type;

  /// Rings of `[lng, lat]` pairs. Only the first is used - plots have no holes.
  final List<List<List<double>>> coordinates;

  Json toJson() => {'type': type, 'coordinates': coordinates};
}

class PlotDto {
  const PlotDto({
    required this.id,
    required this.name,
    required this.polygon,
    required this.centroidLat,
    required this.centroidLng,
    required this.areaSqM,
    required this.landmarkNote,
    required this.colourIndex,
    required this.createdAt,
  });

  factory PlotDto.fromJson(Json json) => PlotDto(
        id: json['id'] as String,
        name: json['name'] as String,
        polygon: PolygonDto.fromJson(json['polygon'] as Json),
        centroidLat: _double(json['centroid_lat']),
        centroidLng: _double(json['centroid_lng']),
        areaSqM: _double(json['area_sq_m']),
        landmarkNote: json['landmark_note'] as String? ?? '',
        // Defaulted so a server that has not been migrated yet still parses;
        // every plot then draws in slot 0, which is wrong but not broken.
        colourIndex: json['colour_index'] == null ? 0 : _int(json['colour_index']),
        createdAt: json['created_at'] as String,
        // The `?near=` response also carries `distance_m`; the app recomputes
        // the distance locally from the agent's live fix, so it is ignored.
      );

  final String id;
  final String name;
  final PolygonDto polygon;
  final double centroidLat;
  final double centroidLng;
  final double areaSqM;
  final String landmarkNote;
  final int colourIndex;
  final String createdAt;
}

/// One crop-condition snapshot, exactly as `GET /api/plots/:id/health` serves it.
///
/// Every cell carries its zone on all three indices; [patches] are the
/// moderate-and-critical areas the AR view turns into drop points. The raw index
/// values, the per-index summaries and the grid size are on the wire too and
/// are deliberately not mapped: nothing in the field app shows a raw NDVI.
///
/// [synthetic] defaults to `false` when missing, the unsafe direction, on
/// purpose: the server always sends it, and a silent `true` would libel a real
/// snapshot as fake.
class HealthDto {
  const HealthDto({
    required this.plotId,
    required this.capturedOn,
    required this.cellSizeM,
    this.cells = const [],
    this.patches = const [],
    this.synthetic = false,
    this.note = '',
  });

  factory HealthDto.fromJson(Json json) => HealthDto(
        plotId: json['plot_id'] as String,
        capturedOn: json['captured_on'] as String,
        cellSizeM: _double(json['cell_size_m']),
        cells: [
          for (final c in json['cells'] as List<dynamic>? ?? const []) HealthCellDto.fromJson(c as Json),
        ],
        patches: [
          for (final p in json['patches'] as List<dynamic>? ?? const []) HealthPatchDto.fromJson(p as Json),
        ],
        synthetic: json['synthetic'] as bool? ?? false,
        note: json['note'] as String? ?? '',
      );

  final String plotId;
  final String capturedOn;
  final double cellSizeM;
  final List<HealthCellDto> cells;
  final List<HealthPatchDto> patches;
  final bool synthetic;
  final String note;

  Json toJson() => {
        'plot_id': plotId,
        'captured_on': capturedOn,
        'cell_size_m': cellSizeM,
        'cells': [for (final c in cells) c.toJson()],
        'patches': [for (final p in patches) p.toJson()],
        'synthetic': synthetic,
        'note': note,
      };
}

class HealthCellDto {
  const HealthCellDto({
    required this.zones,
    required this.centroidLat,
    required this.centroidLng,
    required this.cell,
  });

  factory HealthCellDto.fromJson(Json json) => HealthCellDto(
        zones: {
          for (final MapEntry(:key, :value) in (json['zones'] as Json? ?? const {}).entries) key: _int(value),
        },
        centroidLat: _double(json['centroid_lat']),
        centroidLng: _double(json['centroid_lng']),
        cell: PolygonDto.fromJson(json['cell'] as Json),
      );

  /// Zone per index key - `ndvi`, `ndre`, `lswi` - 0 normal to 2 critical.
  final Map<String, int> zones;
  final double centroidLat;
  final double centroidLng;

  /// The cell square, already trimmed to the plot boundary by the API.
  final PolygonDto cell;

  Json toJson() => {
        'zones': zones,
        'centroid_lat': centroidLat,
        'centroid_lng': centroidLng,
        'cell': cell.toJson(),
      };
}

class HealthPatchDto {
  const HealthPatchDto({
    required this.index,
    required this.rank,
    required this.zone,
    required this.centroidLat,
    required this.centroidLng,
    required this.cellCount,
    required this.areaSqM,
  });

  factory HealthPatchDto.fromJson(Json json) => HealthPatchDto(
        index: json['index'] as String,
        rank: _int(json['rank']),
        zone: _int(json['zone']),
        centroidLat: _double(json['centroid_lat']),
        centroidLng: _double(json['centroid_lng']),
        cellCount: json['cell_count'] == null ? 0 : _int(json['cell_count']),
        areaSqM: json['area_sq_m'] == null ? 0.0 : _double(json['area_sq_m']),
      );

  final String index;
  final int rank;
  final int zone;
  final double centroidLat;
  final double centroidLng;
  final int cellCount;
  final double areaSqM;

  Json toJson() => {
        'index': index,
        'rank': rank,
        'zone': zone,
        'centroid_lat': centroidLat,
        'centroid_lng': centroidLng,
        'cell_count': cellCount,
        'area_sq_m': areaSqM,
      };
}

class TelemetryDto {
  const TelemetryDto({
    required this.timestampMs,
    required this.sessionId,
    required this.plotId,
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.headingDeg,
    required this.headingSource,
    required this.headingConfidence,
    required this.renderMode,
    required this.anchorShiftM,
    required this.anchorAgeS,
    required this.deviceModel,
    required this.appVersion,
    required this.sessionDurationMs,
  });

  final int timestampMs;
  final String sessionId;
  final String plotId;
  final double lat;
  final double lng;
  final double accuracyM;
  final double headingDeg;
  final String headingSource;
  final String headingConfidence;
  final String renderMode;
  final double anchorShiftM;
  final double anchorAgeS;
  final String deviceModel;
  final String appVersion;
  final int sessionDurationMs;

  Json toJson() => {
        'timestamp_ms': timestampMs,
        'session_id': sessionId,
        'plot_id': plotId,
        'lat': lat,
        'lng': lng,
        'accuracy_m': accuracyM,
        'heading_deg': headingDeg,
        'heading_source': headingSource,
        'heading_confidence': headingConfidence,
        'render_mode': renderMode,
        'anchor_shift_m': anchorShiftM,
        'anchor_age_s': anchorAgeS,
        'device_model': deviceModel,
        'app_version': appVersion,
        'session_duration_ms': sessionDurationMs,
      };
}
