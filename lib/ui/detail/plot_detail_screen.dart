import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/geo/enu.dart';
import '../../core/geo/polygon_geometry.dart';
import '../../data/plot.dart';
import '../formatting.dart';
import '../theme.dart';

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
    if (plot == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Plot details')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'This plot is not in the offline cache.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: GrowColors.mutedText),
            ),
          ),
        ),
      );
    }

    final distance = distanceM;
    final landmark = plot.landmarkNote.trim();
    // Scrollable: at a large system font scale the content falls below the
    // fold. The actions are pinned below it so "Find this plot" is always
    // reachable.
    return Scaffold(
      appBar: AppBar(title: const Text('Plot details')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              plot.name,
              style: const TextStyle(fontSize: 22, height: 1.27, fontWeight: FontWeight.w700, color: GrowColors.text),
            ),
            const SizedBox(height: 4),
            Text(
              '${plot.id} · ${formatHectares(plot.areaSqM)}'
              '${distance == null ? '' : ' · ${formatDistance(distance)} away'}',
              style: const TextStyle(fontSize: 13, color: GrowColors.mutedText),
            ),
            const SizedBox(height: 12),
            _SketchCard(plot: plot),
            const SizedBox(height: 12),
            _Card(
              title: 'Getting there',
              children: [
                _InfoRow(
                  icon: Icons.flag_outlined,
                  iconColour: GrowColors.warning,
                  iconBackground: GrowColors.warningTint,
                  label: 'Landmark at the access point',
                  value: landmark.isEmpty ? 'none recorded' : landmark,
                ),
                const Divider(height: 20),
                _CoordinateRow(
                  label: 'Access point',
                  value: formatLatLng(plot.accessPoint.lat, plot.accessPoint.lng),
                ),
                const Divider(height: 20),
                _CoordinateRow(
                  label: 'Centroid',
                  value: formatLatLng(plot.centroid.lat, plot.centroid.lng),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _Fact('Corners', '${plot.cornerCount}')),
                const SizedBox(width: 8),
                Expanded(child: _Fact('Surveyed', formatIsoDate(plot.createdAt))),
                const SizedBox(width: 8),
                Expanded(child: _Fact('Cached', formatCacheAge(plot.syncedAtMs))),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: GrowColors.surface,
          border: Border(top: BorderSide(color: GrowColors.outline)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                if (simulationAvailable) ...[
                  Expanded(
                    child: OutlinedButton(onPressed: () => onFindPlot(true), child: const Text('Simulate')),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => onFindPlot(false),
                    icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
                    label: const Text('Find this plot'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SketchCard extends StatelessWidget {
  const _SketchCard({required this.plot});

  final Plot plot;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: GrowColors.sketchPlate,
          child: AspectRatio(
            aspectRatio: 1.6,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    label: 'Plan view of the plot boundary with the access point marked',
                    child: CustomPaint(painter: PlotSketchPainter(plot)),
                  ),
                ),
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(color: Color(0xCC0F1A20), shape: BoxShape.circle),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.navigation, size: 12, color: Colors.white),
                        Text('N', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: const Color(0xCC0F1A20), borderRadius: BorderRadius.circular(12)),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 12, height: 3, child: ColoredBox(color: PlotSketchPainter.boundaryColour)),
                        SizedBox(width: 5),
                        Text('Boundary', style: TextStyle(color: Color(0xFFE5E7EB), fontSize: 11)),
                        SizedBox(width: 12),
                        DecoratedBox(
                          decoration: BoxDecoration(color: PlotSketchPainter.accessColour, shape: BoxShape.circle),
                          child: SizedBox(width: 8, height: 8),
                        ),
                        SizedBox(width: 5),
                        Text('Access point', style: TextStyle(color: Color(0xFFE5E7EB), fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: GrowColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: GrowColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: GrowColors.text)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.iconColour,
    required this.iconBackground,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color iconColour;
  final Color iconBackground;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: iconBackground, shape: BoxShape.circle),
            child: Icon(icon, size: 16, color: iconColour),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: GrowColors.mutedText)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 14, height: 1.43, color: GrowColors.text)),
              ],
            ),
          ),
        ],
      );
}

class _CoordinateRow extends StatelessWidget {
  const _CoordinateRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: GrowColors.mutedText)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    color: GrowColors.text,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy $label coordinates',
            icon: const Icon(Icons.copy_outlined, size: 18, color: GrowColors.primary),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
            },
          ),
        ],
      );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: GrowColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: GrowColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: GrowColors.mutedText)),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: GrowColors.text),
            ),
          ],
        ),
      );
}

/// Plan view of the boundary with the access point marked, drawn in metres and
/// scaled to fit. Purely offline.
class PlotSketchPainter extends CustomPainter {
  PlotSketchPainter(this.plot);

  final Plot plot;

  static const Color boundaryColour = Color(0xFF38BDF8);
  static const Color accessColour = Color(0xFFF59E0B);

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
    canvas.drawPath(path, Paint()..color = boundaryColour.withAlpha(alpha8(0.18)));
    canvas.drawPath(
      path,
      Paint()
        ..color = boundaryColour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final vertexPaint = Paint()..color = boundaryColour;
    for (final vertex in ring) {
      canvas.drawCircle(toScreen(vertex), 3.5, vertexPaint);
    }
    canvas.drawCircle(toScreen(access), 6, Paint()..color = accessColour);
  }

  @override
  bool shouldRepaint(PlotSketchPainter oldDelegate) => oldDelegate.plot != plot;
}
