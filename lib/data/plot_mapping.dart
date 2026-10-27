import 'dart:convert';

import '../core/geo/enu.dart';
import '../core/render/health_geometry.dart';
import 'db/entities.dart';
import 'net/dtos.dart';
import 'plot.dart';

/// Wire format to cache row to domain object.
///
/// Split out of the repository so there is exactly one path from bytes to
/// geometry - the lng/lat swap below is the one line in the app where a mistake
/// silently relocates every plot, and it should exist once.

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// A GeoJSON ring as WGS84 positions.
///
/// The boundary and every health cell are the same shape on the wire, and the
/// lng-then-lat swap is the one line in the app where a mistake silently
/// relocates geometry. It exists once, here, and both callers go through it.
List<LatLng> _ringOf(List<List<List<double>>> coordinates) {
  if (coordinates.isEmpty) return const [];
  return [
    for (final pair in coordinates.first)
      if (pair.length >= 2) LatLng(pair[1], pair[0]),
  ];
}

extension PlotDtoMapping on PlotDto {
  PlotEntity toEntity({int? syncedAtMs}) => PlotEntity(
        id: id,
        name: name,
        ringJson: jsonEncode(polygon.coordinates.isEmpty ? const <List<double>>[] : polygon.coordinates.first),
        centroidLat: centroidLat,
        centroidLng: centroidLng,
        areaSqM: areaSqM,
        landmarkNote: landmarkNote,
        colourIndex: colourIndex,
        createdAt: createdAt,
        syncedAtMs: syncedAtMs ?? _nowMs(),
      );
}

extension HealthDtoMapping on HealthDto {
  HealthEntity toEntity({int? syncedAtMs}) => HealthEntity(
        plotId: plotId,
        capturedOn: capturedOn,
        synthetic: synthetic,
        // Re-serialised from the parsed DTO rather than kept as the raw body, so
        // the cache can only ever hold something this app can read back.
        snapshotJson: jsonEncode(toJson()),
        syncedAtMs: syncedAtMs ?? _nowMs(),
      );

  PlotHealth toHealth(int syncedAtMs) => PlotHealth(
        plotId: plotId,
        capturedOn: capturedOn,
        synthetic: synthetic,
        note: note,
        cellSizeM: cellSizeM,
        cells: [
          for (final c in cells)
            HealthCell(
              centroid: LatLng(c.centroidLat, c.centroidLng),
              ring: _ringOf(c.cell.coordinates),
              // Clamped, not trusted. A zone the renderer has no colour for
              // would otherwise index off the end of the ramp mid-frame.
              zones: [for (final index in HealthIndex.values) (c.zones[index.wireName] ?? zoneNormal).clamp(0, 2)],
            ),
        ],
        patches: [
          for (final p in patches)
            // An index this build does not know is skipped, not guessed at.
            if (HealthIndex.fromWire(p.index) case final index?)
              // Normal ground is never a drop point, whatever the wire says.
              if (p.zone >= zoneModerate)
                HealthPatch(
                  index: index,
                  rank: p.rank,
                  zone: p.zone.clamp(zoneModerate, zoneCritical),
                  centroid: LatLng(p.centroidLat, p.centroidLng),
                  cellCount: p.cellCount,
                  areaSqM: p.areaSqM,
                ),
        ],
        syncedAtMs: syncedAtMs,
      );
}

extension HealthEntityMapping on HealthEntity {
  /// Cache row back to domain, via the wire type.
  ///
  /// Decoding to [HealthDto] and reusing `toHealth` rather than writing a
  /// second parser means the cached path and the network path cannot disagree
  /// about what a snapshot means. A snapshot written by an older build that no
  /// longer parses is treated as absent - the raster is a convenience, and a
  /// stale one is not worth crashing an AR session for.
  PlotHealth? toHealth() {
    try {
      return HealthDto.fromJson(jsonDecode(snapshotJson) as Json).toHealth(syncedAtMs);
    } catch (_) {
      return null;
    }
  }
}

extension PlotEntityMapping on PlotEntity {
  Plot toPlot() {
    final ring = [
      for (final pair in jsonDecode(ringJson) as List<dynamic>)
        [for (final v in pair as List<dynamic>) (v as num).toDouble()],
    ];
    return Plot(
      id: id,
      name: name,
      // GeoJSON is lng-then-lat. Getting this backwards puts Karnataka in the
      // Indian Ocean, so the swap happens in exactly one place: `_ringOf`.
      ring: _ringOf([ring]),
      centroid: LatLng(centroidLat, centroidLng),
      areaSqM: areaSqM,
      landmarkNote: landmarkNote,
      colourIndex: colourIndex,
      createdAt: createdAt,
      syncedAtMs: syncedAtMs,
    );
  }
}
