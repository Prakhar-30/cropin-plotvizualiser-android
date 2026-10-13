import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/heading/course_over_ground_detector.dart';
import 'package:plot_finder/core/heading/heading_model.dart';
import 'package:plot_finder/sim/simulation_engine.dart';

void main() {
  const start = LatLng(12.7862, 76.7201);

  test('walking with the pad produces fixes the walk detector accepts', () {
    // The simulator exists so a course-over-ground lock can be produced from a
    // desk. If its fixes did not look like a real walk, the lock - the thing
    // most worth testing - could never be reached.
    var now = 1000000;
    final engine = SimulationEngine(start, clockMs: () => now);
    final detector = CourseOverGroundDetector();
    engine.start();
    // The first pad event has no previous one to measure a step against.
    engine.move(1.4, 0.0);
    expect(engine.location.value!.bearingDeg, isNull);

    double? locked;
    // 1.4 m/s due east, sampled every 0.5 s (the step cap), for 20 s.
    for (var i = 0; i < 40; i++) {
      now += 500;
      engine.move(1.4, 0.0);
      final fix = engine.location.value!;
      expect(fix.bearingDeg, closeTo(90.0, 1e-9));
      locked ??= detector.add(fix);
    }
    expect(locked, isNotNull);
    expect(locked!, closeTo(90.0, 0.5));
    expect(distanceM(start, engine.truePosition), closeTo(1.4 * 0.5 * 40, 0.5));
  });

  test('injected heading error moves the drawn heading but not the fusion', () {
    var now = 1000000;
    final engine = SimulationEngine(start, clockMs: () => now);
    engine.aim(30.0);
    engine.applyHeadingFix(30.0, HeadingSource.landmarkSnap);
    expect(engine.pose.value.headingDeg, closeTo(30.0, 1e-6));
    expect(engine.headingStatus.value.confidence, HeadingConfidence.locked);

    engine.headingErrorDeg = 20.0;
    now += 100;
    engine.refresh();
    expect(engine.pose.value.headingDeg, closeTo(50.0, 1e-6));
  });

  test('injected GNSS error displaces the reported fix, not the agent', () {
    final engine = SimulationEngine(start, clockMs: () => 1000000);
    engine.gnssErrorM = 10.0;
    engine.refresh();
    expect(distanceM(start, engine.location.value!.position), closeTo(10.0, 0.01));
    expect(bearingDeg(start, engine.location.value!.position), closeTo(45.0, 0.01));
    expect(engine.truePosition, start);
  });

  test('standing still reports no bearing', () {
    final engine = SimulationEngine(start, clockMs: () => 1000000);
    engine.teleport(LatLng(start.lat + 0.001, start.lng));
    expect(engine.location.value!.bearingDeg, isNull);
    expect(engine.location.value!.speedMps, 0.0);
  });
}
