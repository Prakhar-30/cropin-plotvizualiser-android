import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/heading/heading_model.dart';
import 'package:plot_finder/core/render/health_geometry.dart';
import 'package:plot_finder/data/plot.dart';
import 'package:plot_finder/pose/pose_source.dart';
import 'package:plot_finder/ui/ar/ar_controller.dart';
import 'package:plot_finder/ui/ar/heading_chip.dart';
import 'package:plot_finder/ui/ar/minimap.dart';
import 'package:plot_finder/ui/ar/startup_loader.dart';
import 'package:plot_finder/ui/home/home_screen.dart';
import 'package:plot_finder/ui/plots/plot_list_controller.dart';
import 'package:plot_finder/ui/theme.dart';

void main() {
  Widget host(Widget child) => MaterialApp(theme: plotFinderTheme(), home: Scaffold(body: child));

  testWidgets('an unreliable heading tells the agent how to fix it', (tester) async {
    await tester.pumpWidget(host(const HeadingChip(
      status: HeadingStatus(
        source: HeadingSource.magnetometer,
        confidence: HeadingConfidence.unreliable,
        ageSeconds: 0,
        expectedErrorDeg: 20,
      ),
    )));
    expect(find.text('Heading unreliable'), findsOneWidget);
    expect(find.text('compass only — walk a few steps to lock direction'), findsOneWidget);
  });

  testWidgets('a carried heading reports its age', (tester) async {
    await tester.pumpWidget(host(const HeadingChip(
      status: HeadingStatus(
        source: HeadingSource.courseOverGround,
        confidence: HeadingConfidence.holding,
        ageSeconds: 75,
        expectedErrorDeg: 4,
      ),
    )));
    expect(find.text('gyro-carried  75s since fix'), findsOneWidget);
  });

  testWidgets('home: with plots cached, Start AR view opens the camera directly', (tester) async {
    const plot = Plot(
      id: 'PLT-1',
      name: 'North field',
      ring: [
        LatLng(12.7860, 76.7200),
        LatLng(12.7860, 76.7210),
        LatLng(12.7870, 76.7210),
        LatLng(12.7860, 76.7200),
      ],
      centroid: LatLng(12.7863, 76.7207),
      areaSqM: 25000,
      landmarkNote: '',
      colourIndex: 2,
      createdAt: '2026-08-01T10:00:00Z',
      syncedAtMs: 0,
    );
    var started = false;
    var synced = false;
    await tester.pumpWidget(MaterialApp(
      theme: growTheme(),
      home: HomeScreen(
        state: const PlotListState(
          items: [PlotListItem(plot, 1530)],
          hasFix: true,
          lastSyncMessage: 'Cached 1 plot(s), 1 with crop condition',
        ),
        onSync: () => synced = true,
        onStart: () => started = true,
      ),
    ));
    expect(find.text('1 plot'), findsOneWidget);
    expect(find.text('North field · 1.5 km'), findsOneWidget);
    expect(find.text('Cached 1 plot(s), 1 with crop condition'), findsOneWidget);
    await tester.tap(find.text('Sync now'));
    expect(synced, isTrue);
    await tester.tap(find.text('Start AR view'));
    expect(started, isTrue);
  });

  testWidgets('home: with nothing cached, the camera waits for a sync', (tester) async {
    var started = false;
    await tester.pumpWidget(MaterialApp(
      theme: growTheme(),
      home: HomeScreen(
        state: const PlotListState(syncing: true),
        onSync: () {},
        onStart: () => started = true,
      ),
    ));
    expect(find.text('Nothing synced yet'), findsOneWidget);
    expect(find.text('Syncing…'), findsOneWidget);
    await tester.tap(find.text('Syncing plots…'));
    expect(started, isFalse, reason: 'no plots, nothing to show in the camera yet');
  });

  testWidgets('the minimap grows when tapped', (tester) async {
    const plot = Plot(
      id: 'PLT-2',
      name: 'South field',
      ring: [
        LatLng(12.7860, 76.7200),
        LatLng(12.7860, 76.7210),
        LatLng(12.7870, 76.7210),
        LatLng(12.7860, 76.7200),
      ],
      centroid: LatLng(12.7863, 76.7207),
      areaSqM: 25000,
      landmarkNote: '',
      colourIndex: 0,
      createdAt: '2026-08-01T10:00:00Z',
      syncedAtMs: 0,
    );
    final frame = ValueNotifier<ArFrame?>(const ArFrame(agent: LatLng(12.7862, 76.7205)));
    addTearDown(frame.dispose);
    await tester.pumpWidget(host(Align(
      alignment: Alignment.bottomRight,
      child: PlotMinimap(plots: const [plot], health: const {}, index: HealthIndex.ndvi, frame: frame),
    )));
    final map = find.byType(PlotMinimap);
    expect(tester.getSize(map), const Size(132, 132));
    expect(find.text('60 m'), findsOneWidget, reason: 'the scale is shown');
    await tester.tap(map);
    await tester.pumpAndSettle();
    expect(tester.getSize(map), const Size(220, 220));
    expect(find.text('120 m'), findsOneWidget, reason: 'enlarging also widens the radius');
  });

  testWidgets('the startup loader says what it is still waiting for, and when it is slow', (tester) async {
    await tester.pumpWidget(host(const StartupLoader(hasFix: false, usesTracking: true, tracking: true)));
    expect(find.text('Finding your position'), findsOneWidget);
    expect(find.text('Motion tracking'), findsOneWidget);
    expect(find.text('GPS'), findsOneWidget);
    expect(find.text('ready'), findsNWidgets(2), reason: 'camera and tracking are in; GPS is not');
    expect(find.textContaining('Taking longer'), findsNothing);
    // Release the clock and the pulse before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  test('the loader is done only when everything it waits for is in', () {
    expect(StartupLoader.done(hasFix: true, usesTracking: true, tracking: false), isFalse);
    expect(StartupLoader.done(hasFix: true, usesTracking: false, tracking: false), isTrue);
    expect(StartupLoader.done(hasFix: false, usesTracking: false, tracking: false), isFalse);
  });

  test('the AR state collects drop points of the chosen index across plots', () {
    PlotHealth health(String id, List<HealthPatch> patches) => PlotHealth(
          plotId: id,
          capturedOn: '2026-10-01',
          synthetic: true,
          note: '',
          cellSizeM: 3,
          cells: const [],
          patches: patches,
          syncedAtMs: 0,
        );
    HealthPatch patch(HealthIndex index, int zone) => HealthPatch(
          index: index,
          rank: 1,
          zone: zone,
          centroid: const LatLng(12.78, 76.72),
          cellCount: 3,
          areaSqM: 27,
        );
    final state = ArUiState(health: {
      'A': health('A', [patch(HealthIndex.ndvi, 2), patch(HealthIndex.lswi, 1)]),
      'B': health('B', [patch(HealthIndex.ndvi, 1)]),
    });
    expect(state.patches.length, 2, reason: 'NDVI patches from both plots');
    expect(state.copyWith(index: HealthIndex.lswi).patches.length, 1);
    expect(state.copyWith(index: HealthIndex.ndre).patches, isEmpty);
    expect(state.synthetic, isTrue);
    expect(state.snapped, isFalse);
    expect(state.copyWith(snappedTo: () => 'A').snapped, isTrue);
  });
}
