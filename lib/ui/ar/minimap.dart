import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/geo/enu.dart';
import '../../core/geo/polygon_geometry.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../data/plot.dart';
import '../theme.dart';
import 'ar_controller.dart';

/// A plan view in the corner of the camera, as games do it.
///
/// Centred on the agent and north up: every nearby plot's boundary in its own
/// colour, the moderate and critical ground of the chosen index in yellow and
/// red (normal ground is left out, as in the camera), a dot on each drop point,
/// and the agent as a blue arrow turning with the phone. The camera answers
/// "what is in front of me"; this answers "where are the problem patches from
/// here, in every direction".
///
/// Tap to enlarge - which also widens the radius shown - tap again to shrink.
class PlotMinimap extends StatefulWidget {
  const PlotMinimap({
    super.key,
    required this.plots,
    required this.health,
    required this.index,
    required this.frame,
  });

  final List<Plot> plots;
  final Map<String, PlotHealth> health;
  final HealthIndex index;

  /// Per-frame position and heading.
  final ValueListenable<ArFrame?> frame;

  @override
  State<PlotMinimap> createState() => _PlotMinimapState();
}

class _PlotMinimapState extends State<PlotMinimap> {
  bool _large = false;
  MinimapLayer? _layer;

  MinimapLayer? _layerFor(LatLng? origin) {
    final existing = _layer;
    if (existing != null &&
        identical(existing.plots, widget.plots) &&
        identical(existing.health, widget.health) &&
        existing.index == widget.index) {
      return existing;
    }
    if (origin == null) return null;
    return _layer = MinimapLayer(widget.plots, widget.health, widget.index, origin);
  }

  @override
  Widget build(BuildContext context) {
    final side = _large ? 220.0 : 132.0;
    return Semantics(
      label: 'Map of nearby plots. Tap to ${_large ? 'shrink' : 'enlarge'}',
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
              ValueListenableBuilder<ArFrame?>(
                valueListenable: widget.frame,
                builder: (context, current, _) {
                  final layer = _layerFor(current?.agent);
                  if (layer == null || current?.agent == null) return const SizedBox.shrink();
                  return CustomPaint(
                    painter: _MinimapPainter(
                      layer,
                      current!.agent!,
                      current.headingDeg,
                      _large ? 120.0 : 60.0,
                    ),
                  );
                },
              ),
              const Positioned(
                top: 4,
                left: 6,
                child: Text(
                  'N ↑',
                  style: TextStyle(color: PlotFinderColors.mutedText, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
              Positioned(
                bottom: 4,
                right: 6,
                child: Text(
                  '${_large ? 120 : 60} m',
                  style: const TextStyle(color: PlotFinderColors.mutedText, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The plots and the problem ground, in metres around a fixed origin, as paths.
///
/// Built once per plot set, snapshot set and index - not per frame. Each frame
/// only moves and scales the canvas under them, which is cheap however many
/// cells there are.
class MinimapLayer {
  MinimapLayer(this.plots, this.health, this.index, this.origin) {
    final frame = EnuFrame(origin);
    Offset at(LatLng p) {
      final e = frame.toEnu(p);
      return Offset(e.east, e.north);
    }

    for (final plot in plots) {
      final ring = openRing([for (final p in plot.ring) frame.toEnu(p)]);
      if (ring.length < 3) continue;
      boundaries.add((
        Path()..addPolygon([for (final e in ring) Offset(e.east, e.north)], true),
        Color(plotColour(plot.colourIndex).argb),
      ));
    }
    for (final snapshot in health.values) {
      for (final cell in snapshot.cells) {
        final zone = cell.zoneFor(index);
        if (zone < zoneModerate || cell.ring.length < 3) continue;
        (zone == zoneCritical ? critical : moderate).addPolygon([for (final p in cell.ring) at(p)], true);
      }
      for (final patch in snapshot.patchesFor(index)) {
        drops.add((at(patch.centroid), patch.zone));
      }
    }
  }

  final List<Plot> plots;
  final Map<String, PlotHealth> health;
  final HealthIndex index;
  final LatLng origin;

  final List<(Path, Color)> boundaries = [];
  final Path moderate = Path();
  final Path critical = Path();
  final List<(Offset, int)> drops = [];
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter(this.layer, this.agent, this.headingDeg, this.radiusM);

  final MinimapLayer layer;
  final LatLng agent;
  final double headingDeg;

  /// Metres from the centre to the edge of the map.
  final double radiusM;

  static const Color _blue = Color(0xFF3B82F6);

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final scale = (size.shortestSide / 2) / radiusM;
    final here = EnuFrame(layer.origin).toEnu(agent);

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    // North up: screen y runs down, so north is flipped.
    canvas.scale(scale, -scale);
    canvas.translate(-here.east, -here.north);

    final hairline = 1.0 / scale;
    canvas.drawPath(layer.moderate, Paint()..color = Color(severityColour(zoneModerate).argb).withAlpha(alpha8(0.8)));
    canvas.drawPath(layer.critical, Paint()..color = Color(severityColour(zoneCritical).argb).withAlpha(alpha8(0.85)));
    for (final (path, colour) in layer.boundaries) {
      canvas.drawPath(path, Paint()..color = colour.withAlpha(alpha8(0.12)));
      canvas.drawPath(
        path,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * hairline
          ..isAntiAlias = true,
      );
    }
    for (final (at, zone) in layer.drops) {
      canvas.drawCircle(at, 4.5 * hairline, Paint()..color = const Color(0xFF0B0F14));
      canvas.drawCircle(at, 3.2 * hairline, Paint()..color = Color(severityColour(zone).argb));
    }
    canvas.restore();

    // The agent, always at the centre, turning with the camera.
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(headingDeg * math.pi / 180.0);
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
  bool shouldRepaint(_MinimapPainter oldDelegate) =>
      !identical(oldDelegate.layer, layer) ||
      oldDelegate.agent != agent ||
      oldDelegate.headingDeg != headingDeg ||
      oldDelegate.radiusM != radiusM;
}
