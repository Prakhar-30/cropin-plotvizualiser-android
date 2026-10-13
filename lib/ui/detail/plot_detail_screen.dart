import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/geo/enu.dart';
import '../../core/geo/polygon_geometry.dart';
import '../../data/plot.dart';
import '../formatting.dart';

/// Screen 2: what the agent reads before setting off.
///
/// The thumbnail is drawn from the cached ring rather than fetched as a map tile.
/// A tile would be a blank grey square at the exact moment it is needed - the
/// agent is standing at the roadside with no data - whereas the shape is already
/// on the device and is the thing that lets them recognise the field.
class PlotDetailScreen extends StatelessWidget {
  const PlotDetailScreen({
    super.key,
    required this.plot,
    required this.distanceM,
    required this.simulationAvailable,
    required this.onFindPlot,
  });

  final Plot? plot;
  final double? distanceM;
  final bool simulationAvailable;
  final void Function(bool simulated) onFindPlot;

  @override
  Widget build(BuildContext context) {
    final plot = this.plot;
    final back = TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back'));
    if (plot == null) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [back, const Text('This plot is not in the offline cache.')],
            ),
          ),
        ),
      );
    }

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final distance = distanceM;
    // Scrollable: at a large system font scale the action buttons fall below the
    // fold, and an unreachable "Find this plot" makes the screen useless.
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              back,
              Text(plot.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              Text(
                '${plot.id}  ·  ${formatHectares(plot.areaSqM)}'
                '${distance == null ? '' : '  ·  ${formatDistance(distance)} away'}',
                style: TextStyle(fontSize: 13, color: muted),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: AspectRatio(
                  aspectRatio: 1.4,
                  child: CustomPaint(painter: PlotSketchPainter(plot), size: Size.infinite),
                ),
              ),
              _DetailRow('Access point', formatLatLng(plot.accessPoint.lat, plot.accessPoint.lng)),
              _DetailRow('Landmark', plot.landmarkNote.trim().isEmpty ? 'none recorded' : plot.landmarkNote),
              _DetailRow('Centroid', formatLatLng(plot.centroid.lat, plot.centroid.lng)),
              _DetailRow('Corners', '${plot.cornerCount}'),
              _DetailRow('Surveyed', formatIsoDate(plot.createdAt)),
              _DetailRow('Cached', formatCacheAge(plot.syncedAtMs)),
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Wrap(
                  spacing: 10,
                  children: [
                    FilledButton(onPressed: () => onFindPlot(false), child: const Text('Find this plot')),
                    if (simulationAvailable)
                      TextButton(onPressed: () => onFindPlot(true), child: const Text('Simulate')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value, style: const TextStyle(fontSize: 14)),
          ],
        ),
      );
}

/// Plan view of the boundary with the access point marked, drawn in metres and
/// scaled to fit. Purely offline.
class PlotSketchPainter extends CustomPainter {
  PlotSketchPainter(this.plot);

  final Plot plot;

  static const Color _line = Color(0xFF38BDF8);
  static const Color _access = Color(0xFFF59E0B);

  @override
  void paint(Canvas canvas, Size size) {
    final frame = EnuFrame(plot.centroid);
    final ring = openRing([for (final p in plot.ring) frame.toEnu(p)]);
    final access = frame.toEnu(plot.accessPoint);
    if (ring.length < 3) return;

    final points = [...ring, access];
    final minE = points.map((p) => p.east).reduce(math.min);
    final maxE = points.map((p) => p.east).reduce(math.max);
    final minN = points.map((p) => p.north).reduce(math.min);
    final maxN = points.map((p) => p.north).reduce(math.max);

    const padding = 24.0;
    final spanE = math.max(maxE - minE, 1.0);
    final spanN = math.max(maxN - minN, 1.0);
    // One scale for both axes, so the sketch keeps the plot's real shape.
    final scale = math.min((size.width - padding * 2) / spanE, (size.height - padding * 2) / spanN);
    final offsetX = (size.width - spanE * scale) / 2;
    final offsetY = (size.height - spanN * scale) / 2;

    // North is up, so the north axis is inverted against screen y.
    Offset toScreen(Enu p) => Offset(
          offsetX + (p.east - minE) * scale,
          size.height - offsetY - (p.north - minN) * scale,
        );

    final path = Path()..addPolygon([for (final p in ring) toScreen(p)], true);
    canvas.drawPath(path, Paint()..color = _line.withValues(alpha: 0.18));
    canvas.drawPath(
      path,
      Paint()
        ..color = _line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final vertexPaint = Paint()..color = _line;
    for (final vertex in ring) {
      canvas.drawCircle(toScreen(vertex), 3.5, vertexPaint);
    }
    canvas.drawCircle(toScreen(access), 6, Paint()..color = _access);
  }

  @override
  bool shouldRepaint(PlotSketchPainter oldDelegate) => oldDelegate.plot != plot;
}
