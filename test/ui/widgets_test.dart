import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/geo/enu.dart';
import 'package:plot_finder/core/heading/heading_model.dart';
import 'package:plot_finder/data/plot.dart';
import 'package:plot_finder/pose/pose_source.dart';
import 'package:plot_finder/ui/ar/ar_controller.dart';
import 'package:plot_finder/ui/ar/heading_chip.dart';
import 'package:plot_finder/ui/ar/minimap.dart';
import 'package:plot_finder/ui/detail/plot_detail_screen.dart';
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

  testWidgets('the detail screen shows the plot and opens the finder', (tester) async {
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
      accessPoint: LatLng(12.7860, 76.7200),
      areaSqM: 25000,
      landmarkNote: '',
      colourIndex: 2,
      createdAt: '2026-08-01T10:00:00Z',
      syncedAtMs: 0,
    );
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      theme: growTheme(),
      home: PlotDetailScreen(
        plot: plot,
        distanceM: 1530,
        onFindPlot: () => opened = true,
      ),
    ));
    expect(find.text('North field'), findsOneWidget);
    expect(find.text('PLT-1 · 2.50 ha · 1.5 km away'), findsOneWidget);
    expect(find.text('none recorded'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'three corners, not counting the closing repeat');
    expect(find.text('2026-08-01'), findsOneWidget);

    expect(find.text('Simulate'), findsNothing);
    await tester.tap(find.text('Find this plot'));
    expect(opened, isTrue);
  });

  testWidgets('the minimap draws the field and grows when tapped', (tester) async {
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
      accessPoint: LatLng(12.7860, 76.7200),
      areaSqM: 25000,
      landmarkNote: '',
      colourIndex: 0,
      createdAt: '2026-08-01T10:00:00Z',
      syncedAtMs: 0,
    );
    final frame = ValueNotifier<ArFrame?>(null);
    addTearDown(frame.dispose);
    await tester.pumpWidget(host(Align(
      alignment: Alignment.bottomRight,
      child: PlotMinimap(plot: plot, health: null, frame: frame),
    )));
    final map = find.byType(PlotMinimap);
    expect(tester.getSize(map), const Size(132, 132));
    await tester.tap(map);
    await tester.pumpAndSettle();
    expect(tester.getSize(map), const Size(220, 220));
  });
}
