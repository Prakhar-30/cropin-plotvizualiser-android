import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/geo/projection.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/data/db/entities.dart';
import 'package:plot_finder/data/net/dtos.dart';
import 'package:plot_finder/data/plot_mapping.dart';

/// Parses a response captured verbatim from the deployed API.
///
/// The wire contract is the seam this feature is most likely to break at: every
/// key here is a guess about a server written in another language, in another
/// repository, that deploys on its own schedule. This payload was fetched from
/// the live service, so a rename on either side fails the build instead of
/// silently producing a plot with no crop health and no error.
///
/// It deliberately still contains the fields the app does *not* map - `source`,
/// `value`, `grid_cols` and the rest - because ignoring them is only safe if the
/// parser really does.
void main() {
  const captured =
      '{"plot_id":"PLT-9254","captured_on":"2026-08-25","source":"synthetic","index_name":"ndvi","cell_size_m":10,"grid_cols":3,"grid_rows":3,"value_min":-0.02182532349969879,"value_max":0.7673356737933222,"value_mean":0.6112958701311224,"cells":[{"col":0,"row":0,"value":0.7673356737933222,"severity":0,"centroid_lat":12.918769788495025,"centroid_lng":77.61035668799951,"cell":{"type":"Polygon","coordinates":[[[77.61031585449398,12.91881502099005],[77.610318653,12.918735013],[77.61040276999904,12.918731243538161],[77.61040276999904,12.91881502099005],[77.61031585449398,12.91881502099005]]]}},{"col":1,"row":0,"value":0.5316769404150821,"severity":1,"centroid_lat":12.918769788495025,"centroid_lng":77.61044885199856,"cell":{"type":"Polygon","coordinates":[[[77.61040276999904,12.918731243538161],[77.61049493399808,12.918727113473118],[77.61049493399808,12.91881502099005],[77.61040276999904,12.91881502099005],[77.61040276999904,12.918731243538161]]]}}],"hotspots":[],"synthetic":true,"note":"Synthetic NDVI for demonstration. Not derived from satellite imagery."}';

  HealthDto parse() => HealthDto.fromJson(jsonDecode(captured) as Json);

  test('a real API response parses into cells the renderer can use', () {
    final dto = parse();

    expect(dto.plotId, 'PLT-9254');
    expect(dto.indexName, 'ndvi');
    expect(dto.cellSizeM, closeTo(10.0, 1e-9));
    expect(dto.synthetic, isTrue, reason: 'the live service labels its synthetic values');
    expect(dto.note.trim(), isNotEmpty, reason: 'and explains itself');
    expect(dto.cells.length, 2);

    final health = dto.toHealth(1000);
    expect(health.cells.length, 2);

    // The lng/lat swap: Bengaluru is near 12.9N 77.6E. Getting this
    // backwards puts the cell in the Arabian Sea off Somalia, and nothing
    // else in the pipeline would notice.
    final first = health.cells.first;
    expect(first.centroid.lat, inInclusiveRange(12.0, 14.0));
    expect(first.centroid.lng, inInclusiveRange(77.0, 78.0));
    expect(first.ring.length, greaterThanOrEqualTo(4), reason: 'a cell ring must be closed and drawable');
    for (final corner in first.ring) {
      expect(corner.lat, inInclusiveRange(12.0, 14.0));
      expect(corner.lng, inInclusiveRange(77.0, 78.0));
    }
  });

  test('the parsed raster projects onto the screen from inside the plot', () {
    // The full path in one test: wire bytes to filled screen polygons.
    final health = parse().toHealth(1000);
    final agent = health.cells.first.centroid;
    final frame = EnuFrame(agent);
    final intrinsics = CameraIntrinsics(horizontalFovDeg: 60.0, viewportWidthPx: 1080, viewportHeightPx: 1920);

    final overlay = buildHealthOverlay(
      field: HealthField(health.cells, health.hotspots, frame),
      eye: frame.toEnu(agent),
      // Pitched down at the ground the agent is standing on.
      enuToDevice: deviceToEnuFromOrientation(0.0, -50.0).transpose(),
      intrinsics: intrinsics,
      layer: HealthLayer.all,
    );

    expect(overlay.patches, isNotEmpty, reason: 'expected the standing-on cell to survive clipping');
    expect(overlay.patches.every((p) => p.corners.length >= 3), isTrue);
  });

  test('a snapshot survives the cache round trip', () {
    final dto = parse();
    final restored = dto.toEntity(syncedAtMs: 42).toHealth();

    expect(restored, isNotNull);
    expect(restored!.syncedAtMs, 42);
    expect(restored.cells.length, dto.cells.length);
    expect(restored.plotId, dto.plotId);
  });

  test('an unreadable cached snapshot is dropped, not thrown', () {
    // A row written by a build whose DTO has since changed. The boundary is
    // still perfectly usable, so an AR session must not die over a raster.
    const row = HealthEntity(
      plotId: 'PLT-9254',
      capturedOn: '2026-08-25',
      synthetic: true,
      snapshotJson: '{ not json at all',
      syncedAtMs: 1,
    );
    expect(row.toHealth(), isNull);
  });

  test('a cached plot row comes back with lat and lng the right way round', () {
    const dto = PlotDto(
      id: 'PLT-1',
      name: 'North field',
      polygon: PolygonDto(type: 'Polygon', coordinates: [
        [
          [76.72, 12.78],
          [76.73, 12.78],
          [76.73, 12.79],
          [76.72, 12.78],
        ],
      ]),
      centroidLat: 12.785,
      centroidLng: 76.725,
      accessLat: 12.78,
      accessLng: 76.72,
      areaSqM: 25000.0,
      landmarkNote: 'Blue gate',
      colourIndex: 3,
      createdAt: '2026-08-01T10:00:00Z',
    );
    final plot = dto.toEntity(syncedAtMs: 5).toPlot();
    expect(plot.ring.first, const LatLng(12.78, 76.72));
    expect(plot.cornerCount, 3);
    expect(plot.areaHectares, closeTo(2.5, 1e-9));
    expect(plot.colourIndex, 3);
  });

  test('a plot from a server without colour slots still parses', () {
    final dto = PlotDto.fromJson(jsonDecode(
      '{"id":"P","name":"n","polygon":{"type":"Polygon","coordinates":[[[1,2],[3,4],[5,6],[1,2]]]},'
      '"centroid_lat":2,"centroid_lng":1,"access_lat":2,"access_lng":1,"area_sq_m":100,'
      '"created_at":"2026-01-01","distance_m":12.5}',
    ) as Json);
    expect(dto.colourIndex, 0);
    expect(dto.landmarkNote, '');
  });
}
