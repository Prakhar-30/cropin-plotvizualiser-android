import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/data/net/dtos.dart';
import 'package:plot_finder/data/plot_mapping.dart';

/// Parses a response in the shape `GET /api/plots/:id/health` serves since the
/// updated flow: 3 m cells graded on three indices, and patches per index.
///
/// The wire contract is the seam most likely to break: a server written in
/// another language, in another repository, deploying on its own schedule. The
/// payload keeps fields the app does not map - `values`, `indices`, the grid
/// size - because ignoring them is only safe if the parser really does.
void main() {
  const captured = '{"plot_id":"PLT-4471","captured_on":"2026-10-27","source":"synthetic","cell_size_m":3,'
      '"grid_cols":2,"grid_rows":1,'
      '"indices":[{"key":"ndvi","label":"Crop greenness","edges":[0.35,0.55],"min":0.3,"max":0.7,"mean":0.5,"zone_counts":[1,0,1]}],'
      '"cells":['
      '{"col":0,"row":0,"centroid_lat":12.918769,"centroid_lng":77.610356,'
      '"cell":{"type":"Polygon","coordinates":[[[77.61034,12.91875],[77.61037,12.91875],[77.61037,12.91878],[77.61034,12.91878],[77.61034,12.91875]]]},'
      '"values":{"ndvi":0.71,"ndre":0.43,"lswi":0.28},"zones":{"ndvi":0,"ndre":0,"lswi":0}},'
      '{"col":1,"row":0,"centroid_lat":12.918769,"centroid_lng":77.610384,'
      '"cell":{"type":"Polygon","coordinates":[[[77.61037,12.91875],[77.6104,12.91875],[77.6104,12.91878],[77.61037,12.91878],[77.61037,12.91875]]]},'
      '"values":{"ndvi":0.3,"ndre":0.19,"lswi":0.12},"zones":{"ndvi":2,"ndre":2,"lswi":1}}],'
      '"patches":['
      '{"index":"ndvi","rank":1,"zone":2,"centroid_lat":12.918769,"centroid_lng":77.610384,"cell_count":2,"area_sq_m":18,"mean_value":0.3},'
      '{"index":"lswi","rank":1,"zone":1,"centroid_lat":12.918769,"centroid_lng":77.610384,"cell_count":2,"area_sq_m":18,"mean_value":0.12},'
      '{"index":"evi","rank":1,"zone":2,"centroid_lat":12.9,"centroid_lng":77.6,"cell_count":2,"area_sq_m":18,"mean_value":0.1}],'
      '"synthetic":true,"note":"Demonstration values for NDVI, NDRE and LSWI."}';

  HealthDto parse() => HealthDto.fromJson(jsonDecode(captured) as Json);

  test('cells carry a zone per index, in the right place on the earth', () {
    final health = parse().toHealth(1000);
    expect(health.cellSizeM, closeTo(3.0, 1e-9));
    expect(health.synthetic, isTrue);
    expect(health.cells.length, 2);
    final stressed = health.cells[1];
    expect(stressed.zoneFor(HealthIndex.ndvi), zoneCritical);
    expect(stressed.zoneFor(HealthIndex.ndre), zoneCritical);
    expect(stressed.zoneFor(HealthIndex.lswi), zoneModerate);
    expect(health.cells[0].zoneFor(HealthIndex.ndvi), zoneNormal);
    // The lng/lat swap: Bengaluru is near 12.9N 77.6E.
    expect(stressed.centroid.lat, inInclusiveRange(12.0, 14.0));
    expect(stressed.centroid.lng, inInclusiveRange(77.0, 78.0));
    expect(stressed.ring.length, greaterThanOrEqualTo(4));
  });

  test('patches become drop points per index; an unknown index is skipped', () {
    final health = parse().toHealth(1000);
    expect(health.patches.length, 2, reason: '"evi" is not an index this build knows');
    expect(health.patchesFor(HealthIndex.ndvi).single.zone, zoneCritical);
    expect(health.patchesFor(HealthIndex.lswi).single.zone, zoneModerate);
    expect(health.patchesFor(HealthIndex.ndre), isEmpty);
  });

  test('a snapshot survives the cache round trip', () {
    final dto = parse();
    final restored = dto.toEntity(syncedAtMs: 42).toHealth();
    expect(restored, isNotNull);
    expect(restored!.syncedAtMs, 42);
    expect(restored.cells.length, dto.cells.length);
    expect(restored.patches.length, 2);
    expect(restored.cells[1].zoneFor(HealthIndex.lswi), zoneModerate);
  });

  test('a snapshot in the old single-index shape parses with no drop points', () {
    // The old shape had no patches and per-cell `severity`. It parses, with no
    // patches and every zone normal - the caller then fetches a fresh one.
    const old = '{"plot_id":"PLT-1","captured_on":"2026-08-25","index_name":"ndvi","cell_size_m":10,'
        '"cells":[],"hotspots":[],"synthetic":true,"note":""}';
    final health = HealthDto.fromJson(jsonDecode(old) as Json).toHealth(0);
    expect(health.patches, isEmpty);
  });
}
