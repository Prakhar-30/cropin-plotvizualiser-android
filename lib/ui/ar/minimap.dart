import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/geo/enu.dart';
import '../../core/geo/polygon_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../data/plot.dart';
import '../theme.dart';
import 'ar_controller.dart';

/// A plan view of the plot in the corner of the camera, as games do it.
///
/// The camera answers "what is in front of me"; this answers "where am I in
/// the field, and where is the bad patch from here". North up, like the web
/// map the plots were drawn on: the boundary, the crop-health cells in the same
/// severity colours, the access point, the ranked hotspots, and the agent as a
/// blue arrow turning with the phone.
///
/// Tap to enlarge, tap again to shrink.
class PlotMinimap extends StatefulWidget {
  const PlotMinimap({super.key, required this.plot, required this.health, required this.frame});

  final Plot plot;
  final PlotHealth? health;

  /// Per-frame position and heading; only the agent marker listens to it.
  final ValueListenable<ArFrame?> frame;

  @override
  State<PlotMinimap> createState() => _PlotMinimapState();
}

class _PlotMinimapState extends State<PlotMinimap> {
  bool _large = false;
  MinimapGeometry? _geometry;

  MinimapGeometry _geometryFor(Plot plot, PlotHealth? health) {
    final existing = _geometry;
    if (existing != null && identical(existing.plot, plot) && identical(existing.health, health)) return existing;
    return _geometry = MinimapGeometry(plot, health);
  }

  @override
  Widget build(BuildContext context) {
    final geometry = _geometryFor(widget.plot, widget.health);
    final side = _large ? 220.0 : 132.0;
    return Semantics(
      label: 'Plot map. Tap to ${_large ? 'shrink' : 'enlarge'}',
      button: true,
      child: GestureDetector(
        onTap: () => setState(() => _large = !_large),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: side,
          height: side,
          decoration: BoxDecoration(
            color: const Color(0xD90B0F14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The field itself changes only with the plot or the raster, so
              // it sits on its own layer and is not repainted per frame.
              RepaintBoundary(child: CustomPaint(painter: _FieldPainter(geometry))),
              CustomPaint(painter: _AgentPainter(geometry, widget.frame)),
              const Positioned(
                top: 4,
                left: 6,
                child: Text(
                  'N ↑',
                  style: TextStyle(color: PlotFinderColors.mutedText, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The plot and its raster in metres around the centroid, north up, plus the
/// one transform both layers draw with.
class MinimapGeometry {
  MinimapGeometry(this.plot, this.health) : _frame = EnuFrame(plot.centroid) {
    ring = openRing([for (final p in plot.ring) _frame.toEnu(p)]);
    access = _frame.toEnu(plot.accessPoint);
    cells = [
      for (final cell in health?.cells ?? const [])
        (cell.severity, openRing([for (final p in cell.ring) _frame.toEnu(p)])),
    ];
    hotspots = [
      for (final h in health?.hotspots ?? const []) (h.rank, h.severity, _frame.toEnu(h.centroid)),
    ];
    final points = [...ring, access];
    _minE = points.map((p) => p.east).reduce(math.min);
    _maxE = points.map((p) => p.east).reduce(math.max);
    _minN = points.map((p) => p.north).reduce(math.min);
    _maxN = points.map((p) => p.north).reduce(math.max);
  }

  final Plot plot;
  final PlotHealth? health;
  final EnuFrame _frame;
  late final List<Enu> ring;
  late final Enu access;
  late final List<(int, List<Enu>)> cells;
  late final List<(int, int, Enu)> hotspots;
  late final double _minE, _maxE, _minN, _maxN;

  static const double padding = 12.0;

  Enu toEnu(LatLng p) => _frame.toEnu(p);

  /// Metres to pixels for a box of [size]: one scale for both axes, so the
  /// field keeps its real shape, centred, north up.
  Offset Function(Enu) transform(Size size) {
    final spanE = math.max(_maxE - _minE, 1.0);
    final spanN = math.max(_maxN - _minN, 1.0);
    final scale = math.min((size.width - padding * 2) / spanE, (size.height - padding * 2) / spanN);
    final offsetX = (size.width - spanE * scale) / 2;
    final offsetY = (size.height - spanN * scale) / 2;
    return (p) => Offset(offsetX + (p.east - _minE) * scale, size.height - offsetY - (p.north - _minN) * scale);
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter(this.geometry);

  final MinimapGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.ring.length < 3) return;
    final at = geometry.transform(size);
    final tint = Color(plotColour(geometry.plot.colourIndex).argb);
    final boundary = Path()..addPolygon([for (final p in geometry.ring) at(p)], true);

    canvas.drawPath(boundary, Paint()..color = tint.withAlpha(alpha8(0.12)));

    // Every severity, healthy included: on a map nothing is hidden behind
    // anything, and green is what makes the red read as a patch.
    final bySeverity = <int, Path>{};
    for (final (severity, ring) in geometry.cells) {
      if (ring.length < 3) continue;
      (bySeverity[severity] ??= Path()).addPolygon([for (final p in ring) at(p)], true);
    }
    bySeverity.forEach((severity, path) {
      canvas.drawPath(path, Paint()..color = Color(severityColour(severity).argb).withAlpha(alpha8(0.8)));
    });

    canvas.drawPath(
      boundary,
      Paint()
        ..color = tint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = true,
    );

    for (final (rank, severity, centre) in geometry.hotspots) {
      final c = at(centre);
      canvas.drawCircle(c, 7, Paint()..color = const Color(0xFF0B0F14));
      canvas.drawCircle(c, 5.5, Paint()..color = Color(severityColour(severity).argb));
      final text = TextPainter(
        text: TextSpan(
          text: '$rank',
          style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w800),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, c - Offset(text.width / 2, text.height / 2));
    }

    // The access point, as on the plot's detail sketch.
    canvas.drawCircle(at(geometry.access), 4.5, Paint()..color = const Color(0xFFF59E0B));
  }

  @override
  bool shouldRepaint(_FieldPainter oldDelegate) => !identical(oldDelegate.geometry, geometry);
}

/// The agent: a blue arrow pointing where the camera faces. Outside the map
/// it waits at the edge, still pointing, so the agent knows which side of the
/// field they are on.
class _AgentPainter extends CustomPainter {
  _AgentPainter(this.geometry, this.frame) : super(repaint: frame);

  final MinimapGeometry geometry;
  final ValueListenable<ArFrame?> frame;

  static const Color _blue = Color(0xFF3B82F6);

  @override
  void paint(Canvas canvas, Size size) {
    final current = frame.value;
    final agent = current?.agent;
    if (current == null || agent == null) return;
    final at = geometry.transform(size);
    var p = at(geometry.toEnu(agent));
    const inset = 8.0;
    p = Offset(p.dx.clamp(inset, size.width - inset), p.dy.clamp(inset, size.height - inset));

    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(current.headingDeg * math.pi / 180.0);
    final arrow = Path()
      ..moveTo(0, -9)
      ..lineTo(6.5, 6)
      ..lineTo(0, 3)
      ..lineTo(-6.5, 6)
      ..close();
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(arrow, Paint()..color = _blue);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AgentPainter oldDelegate) =>
      !identical(oldDelegate.geometry, geometry) || oldDelegate.frame != frame;
}
