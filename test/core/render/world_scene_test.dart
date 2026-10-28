import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/arcore_pose.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/core/render/overlay_geometry.dart';
import 'package:plot_finder/core/render/plot_palette.dart';
import 'package:plot_finder/core/render/world_scene.dart';
import 'package:plot_finder/core/math_util.dart';
import 'package:plot_finder/data/plot.dart';

void main() {
  const origin = LatLng(12.7862, 76.7201);
  final metresPerDegLng = math.cos(toRadians(origin.lat)) * metresPerDegLngAtEquator;
  LatLng offset(LatLng from, double eastM, double northM) =>
      LatLng(from.lat + northM / metresPerDegLat, from.lng + eastM / metresPerDegLng);

  double area(List<Enu> polygon, List<int> triangles) {
    var total = 0.0;
    for (var i = 0; i < triangles.length; i += 3) {
      final a = polygon[triangles[i]];
      final b = polygon[triangles[i + 1]];
      final c = polygon[triangles[i + 2]];
      total += ((b.east - a.east) * (c.north - a.north) - (b.north - a.north) * (c.east - a.east)).abs() / 2.0;
    }
    return total;
  }

  group('triangulate', () {
    test('a square is two triangles covering its area, either winding', () {
      const square = [Enu(0, 0), Enu(10, 0), Enu(10, 10), Enu(0, 10)];
      final ccw = triangulate(square);
      final cw = triangulate(square.reversed.toList());
      expect(ccw.length, 6);
      expect(area(square, ccw), closeTo(100.0, 1e-9));
      expect(area(square.reversed.toList(), cw), closeTo(100.0, 1e-9));
    });

    test('an L-shaped field is covered exactly, with nothing outside it', () {
      // 20 x 20 with a 10 x 10 notch: 300 m². A fan from vertex 0 would cover
      // the notch and report 400.
      const l = [Enu(0, 0), Enu(20, 0), Enu(20, 10), Enu(10, 10), Enu(10, 20), Enu(0, 20)];
      final triangles = triangulate(l);
      expect(triangles.length, 12);
      expect(area(l, triangles), closeTo(300.0, 1e-9));
    });

    test('fewer than three points is nothing to fill', () {
      expect(triangulate(const [Enu(0, 0), Enu(1, 1)]), isEmpty);
    });
  });

  group('placePlot', () {
    test('with no yaw offset, the plot sits where it is, beside the camera', () {
      final plot = offset(origin, 0.0, 10.0);
      final p = placePlot(plotOrigin: plot, agent: origin, sessionCamera: const Enu(2.0, 3.0), yawOffsetDeg: 0.0);
      expect(p.tEast, closeTo(2.0, 1e-6));
      expect(p.tNorth, closeTo(13.0, 1e-6));
    });

    test('a 30 degree offset turns true north into session bearing 330', () {
      final plot = offset(origin, 0.0, 10.0);
      final p = placePlot(plotOrigin: plot, agent: origin, sessionCamera: const Enu(0.0, 0.0), yawOffsetDeg: 30.0);
      expect(p.tEast, closeTo(10.0 * math.sin(toRadians(330.0)), 1e-6));
      expect(p.tNorth, closeTo(10.0 * math.cos(toRadians(330.0)), 1e-6));
    });

    test('is the exact inverse of the motion rotation the pose source uses', () {
      // A point placed in the session and then rotated back with arEnuToEnu
      // must land where it started in true ENU, or the plot and the walked
      // motion would disagree about which way is north.
      const yaw = 73.0;
      const camera = Enu(-4.0, 6.5);
      final plot = offset(origin, 17.0, -9.0);
      final p = placePlot(plotOrigin: plot, agent: origin, sessionCamera: camera, yawOffsetDeg: yaw);
      final corner = p.apply(const Enu(3.0, 4.0));
      final back = arEnuToEnu(Enu(corner.east - camera.east, corner.north - camera.north), yaw);
      final expected = EnuFrame(origin).toEnu(offset(plot, 3.0, 4.0));
      expect(back.east, closeTo(expected.east, 1e-3));
      expect(back.north, closeTo(expected.north, 1e-3));
    });

    test('walking - agent and camera moving together - leaves it unchanged', () {
      final plot = offset(origin, 5.0, 20.0);
      final before = placePlot(plotOrigin: plot, agent: origin, sessionCamera: const Enu(0, 0), yawOffsetDeg: 0.0);
      final after = placePlot(
        plotOrigin: plot,
        agent: offset(origin, 1.0, 4.0),
        sessionCamera: const Enu(1.0, 4.0),
        yawOffsetDeg: 0.0,
      );
      expect(after.isCloseTo(before), isTrue);
    });
  });

  group('buildWorldScene', () {
    final ring = [
      origin,
      offset(origin, 10.0, 0.0),
      offset(origin, 10.0, 10.0),
      offset(origin, 0.0, 10.0),
      origin,
    ];
    final centre = offset(origin, 5.0, 5.0);
    Plot plot(String id, List<LatLng> ring, int colour) => Plot(
          id: id,
          name: id,
          ring: ring,
          centroid: ring.first,
          areaSqM: 100,
          landmarkNote: '',
          colourIndex: colour,
          createdAt: '2026-10-01',
          syncedAtMs: 0,
        );

    test('each plot is centred on the shared origin, closing vertex dropped, in its own colour', () {
      final scene = buildWorldScene(
        plots: [plot('A', ring, 0), plot('B', [for (final p in ring) offset(p, 20, 0)], 3)],
        patches: const [],
        origin: centre,
        alpha: 1.0,
      );
      expect(scene.plots.length, 2);
      expect(scene.plots[0].ring.length, 8);
      expect(scene.plots[0].ring[0], closeTo(-5.0, 1e-3));
      expect(scene.plots[0].ring[1], closeTo(-5.0, 1e-3));
      expect(scene.plots[0].inner.length, 8);
      // The ribbon runs from the boundary into the plot: its inner edge's
      // south-west corner sits the ribbon width north-east of the boundary's.
      expect(scene.plots[0].inner[0], closeTo(-5.0 + boundaryRibbonWidthM, 1e-3));
      expect(scene.plots[0].inner[1], closeTo(-5.0 + boundaryRibbonWidthM, 1e-3));
      expect(scene.plots[0].primary, isTrue, reason: 'the first plot given is the nearest');
      expect(scene.plots[1].primary, isFalse);
      final message = scene.toMessage();
      expect(message.containsKey('fillAlpha'), isFalse, reason: 'plots have no tinted floor');
      expect(message.containsKey('wallHeight'), isFalse, reason: 'nothing stands up but the drop points');
      expect(scene.plots[1].ring[0], closeTo(15.0, 1e-3), reason: 'the second plot, 20 m east, same frame');
      expect(scene.plots[0].tintArgb, plotColour(0).argb);
      expect(scene.plots[1].tintArgb, plotColour(3).argb);
    });

    test('drop points carry their position and their zone colour', () {
      final scene = buildWorldScene(
        plots: [plot('A', ring, 0)],
        patches: [
          HealthPatch(
            index: HealthIndex.ndvi,
            rank: 1,
            zone: zoneCritical,
            centroid: offset(origin, 7, 3),
            cellCount: 4,
            areaSqM: 36,
          ),
        ],
        origin: centre,
        alpha: 1.0,
      );
      expect(scene.drops.length, 5);
      expect(scene.drops[0], closeTo(2.0, 1e-3));
      expect(scene.drops[1], closeTo(-2.0, 1e-3));
      final red = severityColour(zoneCritical).argb;
      expect(scene.drops[2], closeTo(((red >> 16) & 0xFF) / 255.0, 1e-6));
      final message = scene.toMessage();
      expect(message['dropHeight'], dropPointHeightM);
      expect((message['plots']! as List).length, 1);
    });

    test('moderate and critical cells of the chosen index lie on the ground; normal ones do not', () {
      HealthCell cell(double e, double n, List<int> zones) {
        final sw = offset(origin, e, n);
        return HealthCell(
          centroid: offset(origin, e + 1.5, n + 1.5),
          ring: [sw, offset(origin, e + 3, n), offset(origin, e + 3, n + 3), offset(origin, e, n + 3), sw],
          zones: zones,
        );
      }

      final cells = [
        cell(0, 0, [zoneCritical, zoneNormal, zoneNormal]),
        cell(3, 0, [zoneNormal, zoneModerate, zoneNormal]),
      ];
      final ndvi = buildWorldScene(
        plots: [plot('A', ring, 0)],
        cells: cells,
        index: HealthIndex.ndvi,
        patches: const [],
        origin: centre,
        alpha: 1.0,
      );
      // One square, two triangles, six floats per vertex.
      expect(ndvi.cells.length, 2 * 3 * 6);
      final red = severityColour(zoneCritical);
      expect(ndvi.cells[2], closeTo(((red.argb >> 16) & 0xFF) / 255.0, 1e-6));
      expect(ndvi.cells[5], closeTo(red.fillAlpha, 1e-6));
      final xs = [for (var i = 0; i < ndvi.cells.length; i += 6) ndvi.cells[i]];
      expect(xs.reduce(math.min), closeTo(-5.0, 1e-3));
      expect(xs.reduce(math.max), closeTo(-2.0, 1e-3));

      final ndre = buildWorldScene(
        plots: [plot('A', ring, 0)],
        cells: cells,
        index: HealthIndex.ndre,
        patches: const [],
        origin: centre,
        alpha: 1.0,
      );
      expect(ndre.cells.length, 2 * 3 * 6, reason: 'only the second cell is graded on NDRE');
      expect(ndre.cells[5], closeTo(severityColour(zoneModerate).fillAlpha, 1e-6));
      expect(ndre.toMessage()['cells'], same(ndre.cells));
    });
  });

  test('far plots go to the renderer as one marker each, in the plot colour', () {
    final ring = [
      origin,
      offset(origin, 10.0, 0.0),
      offset(origin, 10.0, 10.0),
      offset(origin, 0.0, 10.0),
      origin,
    ];
    final far = Plot(
      id: 'F',
      name: 'F',
      ring: ring,
      centroid: offset(origin, 3.0, 4.0),
      areaSqM: 100,
      landmarkNote: '',
      colourIndex: 2,
      createdAt: '2026-10-01',
      syncedAtMs: 0,
    );
    final scene = buildWorldScene(plots: const [], markerPlots: [far], patches: const [], origin: origin, alpha: 1.0);
    expect(scene.plots, isEmpty, reason: 'a marker plot has no boundary in the scene');
    expect(scene.markers.length, 5);
    expect(scene.markers[0], closeTo(3.0, 1e-3));
    expect(scene.markers[1], closeTo(4.0, 1e-3));
    final argb = plotColour(2).argb;
    expect(scene.markers[2], closeTo(((argb >> 16) & 0xFF) / 255.0, 1e-6));
    final message = scene.toMessage();
    expect(message['markerHeight'], plotMarkerHeightM);
    expect((message['markers']! as List).length, 5);
  });
}
