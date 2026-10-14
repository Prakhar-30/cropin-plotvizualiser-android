import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/arcore_pose.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/core/render/world_scene.dart';
import 'package:plot_finder/core/math_util.dart';

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
    HealthCell cell(int severity, double e, double n) => HealthCell(
          severity: severity,
          centroid: offset(origin, e + 1, n + 1),
          ring: [offset(origin, e, n), offset(origin, e + 2, n), offset(origin, e + 2, n + 2), offset(origin, e, n + 2)],
        );

    test('the boundary is centred on the origin and its closing vertex dropped', () {
      final scene = buildWorldScene(
        ring: ring,
        origin: centre,
        cells: const [],
        layer: HealthLayer.off,
        tintArgb: 0xFFFF3B30,
        alpha: 1.0,
      );
      expect(scene.ring.length, 8);
      expect(scene.ring[0], closeTo(-5.0, 1e-3));
      expect(scene.ring[1], closeTo(-5.0, 1e-3));
      expect(scene.fill.length, 12);
    });

    test('problem areas leave healthy cells out; off leaves every cell out', () {
      final cells = [cell(0, 0, 0), cell(2, 4, 4)];
      List<double> build(HealthLayer layer) => buildWorldScene(
            ring: ring,
            origin: centre,
            cells: cells,
            layer: layer,
            tintArgb: 0xFFFF3B30,
            alpha: 1.0,
          ).cells;
      // Two triangles per cell, six floats per vertex.
      expect(build(HealthLayer.all).length, 2 * 2 * 3 * 6);
      expect(build(HealthLayer.stress).length, 2 * 3 * 6);
      expect(build(HealthLayer.off), isEmpty);
    });
  });
}
