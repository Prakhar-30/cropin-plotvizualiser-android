import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/geo/projection.dart';
import '../../core/heading/heading_model.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../theme.dart';
import 'ar_controller.dart';

/// Draws a [PlotOverlay] on a 2D canvas composited over the camera preview.
///
/// This is a projection problem, not a scene graph: every point has already been
/// reduced to screen coordinates by `core/render`, so all that is left is
/// strokes and fills. Pulling in a 3D engine to draw a translucent quadrilateral
/// would be several hundred times the dependency for the same pixels.
///
/// Screen coordinates are logical pixels, the same units the intrinsics were
/// built in. Stroke widths and text sizes were tuned in physical pixels on the
/// Kotlin app, so they are divided by [devicePixelRatio] to land at the same
/// physical size.
///
/// It repaints straight off [frame] rather than being rebuilt with new
/// geometry: frames arrive at sensor rate, and nothing but this canvas needs
/// them.
class ArOverlayPainter extends CustomPainter {
  ArOverlayPainter({
    required this.frame,
    required this.plotId,
    required this.areaHectares,
    required this.colourIndex,
    required this.confidence,
    required this.accuracyM,
    required this.devicePixelRatio,
  }) : super(repaint: frame);

  final ValueListenable<ArFrame?> frame;
  final String plotId;
  final double areaHectares;

  /// Palette slot from the plot record, so neighbouring plots never match.
  final int colourIndex;
  final HeadingConfidence confidence;
  final double accuracyM;
  final double devicePixelRatio;

  static const Color _unreliableColour = Color(0xFF9CA3AF);
  static const Color _labelBackground = Color(0xCC0B0F14);

  /// Dark backing for strokes that must survive any background.
  ///
  /// Outdoor camera footage is mostly bright: sky, pale soil, corrugated fencing.
  /// A coloured line on its own competes with whatever it crosses; the same line
  /// over a dark halo reads against all of it, which is why road signs and map
  /// labels have been drawn this way for a century.
  static const Color _outlineBacking = Color(0xFF0B0F14);

  double _px(double physical) => physical / devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    _drawCrosshair(canvas, size);
    final current = frame.value;
    if (current == null) return;
    final overlay = current.overlay;

    // Grey and dim when the heading cannot be trusted. The overlay is still
    // drawn rather than hidden, because "roughly there, direction unknown" is
    // useful and a blank screen is not - but it must not look authoritative,
    // and it must not keep the plot's identity colour. That colour says "this
    // is plot 4, not plot 5", which is a claim about which boundary you are
    // looking at, and that claim is only ever as good as the heading it was
    // drawn with.
    final trusted = confidence != HeadingConfidence.unreliable;
    final tint = trusted ? Color(plotColour(colourIndex).argb) : _unreliableColour;

    // Three tiers. HOLDING is only a nudge: an agent inspecting a small plot
    // walks around it, never across, so a whole visit runs carried. The chip
    // states the source, the age and the expected error in degrees, which is
    // more specific than a dimmer ever was. The dimming marks the genuinely
    // untrustworthy case.
    final alpha = switch (confidence) {
      HeadingConfidence.locked => 1.0,
      HeadingConfidence.holding => 0.85,
      HeadingConfidence.unreliable => 0.45,
    };

    // The raster goes down before anything else, because it lies on the ground
    // and everything else stands on it.
    final health = current.health;
    if (health != null) _drawHealthPatches(canvas, health, alpha);

    // Walls next, in both modes: they are the boundary.
    _drawWalls(canvas, overlay, tint, alpha);

    switch (overlay.mode) {
      case RenderMode.far:
        _drawFarMode(canvas, overlay, tint, alpha);
      case RenderMode.near:
        _drawNearMode(canvas, overlay, tint, alpha);
    }

    // Hotspot markers stand above the walls on purpose: the marker is a
    // walk-to target, and a target hidden behind the fence between you and it
    // is no target at all.
    if (health != null) _drawHotspotMarkers(canvas, health, alpha);

    final offscreen = overlay.offscreenBearingDeg;
    if (offscreen != null) _drawEdgeArrow(canvas, size, offscreen, tint, alpha);

    final label = overlay.label;
    if (label != null) {
      final text = StringBuffer()
        ..write(plotId)
        ..write('  ')
        ..write('${areaHectares.toStringAsFixed(2)} ha')
        ..write('  ')
        ..write('${label.distanceM.toStringAsFixed(0)} m');
      if (overlay.mode == RenderMode.near) text.write('  ±${accuracyM.toStringAsFixed(0)} m');
      _drawLabel(canvas, text.toString(), label.at, tint, alpha);
    }
  }

  Paint _fill(Color colour, double alpha) => Paint()
    ..color = colour.withAlpha(alpha8(alpha.clamp(0.0, 1.0)))
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  Paint _stroke(Color colour, double alpha, double physicalWidth) => Paint()
    ..color = colour.withAlpha(alpha8(alpha.clamp(0.0, 1.0)))
    ..style = PaintingStyle.stroke
    ..strokeWidth = _px(physicalWidth)
    ..strokeCap = StrokeCap.butt
    ..isAntiAlias = true;

  static Offset _o(ScreenPoint p) => Offset(p.x, p.y);

  static Path? _path(List<ScreenPoint> points) {
    if (points.length < 3) return null;
    return Path()..addPolygon([for (final p in points) _o(p)], true);
  }

  /// Fills the graded ground cells.
  ///
  /// Each cell carries its own opacity from two sources multiplied together: the
  /// severity band and the distance fade. No outline: a stroke around every cell
  /// turns a 500-cell raster into a grid of boxes, and the eye follows the grid
  /// instead of the colour.
  ///
  /// Cells at full strength - everything beyond the foreground fade, which is
  /// nearly all of them - are merged into one path per severity band, so up to
  /// 500 draw calls become four. That is safe only because cells never overlap:
  /// the union of non-overlapping translucent fills is the same picture as the
  /// fills drawn one by one, in any order, and it loses the faint seams where
  /// neighbouring antialiased edges used to double up. Faded foreground cells
  /// each have their own alpha, so they are still drawn individually.
  void _drawHealthPatches(Canvas canvas, HealthOverlay health, double confidenceAlpha) {
    final merged = <int, Path>{};
    for (final patch in health.patches) {
      if (patch.corners.length < 3) continue;
      final polygon = [for (final p in patch.corners) _o(p)];
      if (patch.opacity >= 1.0) {
        (merged[patch.severity] ??= Path()).addPolygon(polygon, true);
        continue;
      }
      final band = severityColour(patch.severity);
      canvas.drawPath(
        Path()..addPolygon(polygon, true),
        _fill(Color(band.argb), band.fillAlpha * patch.opacity * confidenceAlpha),
      );
    }
    merged.forEach((severity, path) {
      final band = severityColour(severity);
      canvas.drawPath(path, _fill(Color(band.argb), band.fillAlpha * confidenceAlpha));
    });
  }

  /// Stands a stem at each hotspot centroid, ranked.
  ///
  /// A patch on the ground vanishes behind the crop the moment the agent is
  /// standing in the field. The stem is drawn tall for the same reason the
  /// boundary posts are: it reads against the sky.
  void _drawHotspotMarkers(Canvas canvas, HealthOverlay health, double confidenceAlpha) {
    for (final marker in health.markers) {
      final colour = Color(severityColour(marker.severity).argb);
      final base = _o(marker.base);
      final top = _o(marker.top);

      canvas.drawLine(base, top, _stroke(_outlineBacking, 0.5 * confidenceAlpha, 14));
      canvas.drawLine(base, top, _stroke(colour, confidenceAlpha, 9));
      canvas.drawCircle(top, _px(23), _fill(_outlineBacking, 0.6 * confidenceAlpha));
      canvas.drawCircle(top, _px(19), _fill(colour, confidenceAlpha));

      // The rank inside the disc. It is the order to walk them in, and an
      // unnumbered marker leaves the agent to guess which patch is worst.
      _drawText(
        canvas,
        '${marker.rank}',
        Offset(top.dx, top.dy + _px(10)),
        TextStyle(
          color: Colors.white.withAlpha(alpha8(confidenceAlpha)),
          fontSize: _px(28),
          fontWeight: FontWeight.bold,
        ),
      );
    }
  }

  /// Draws the standing boundary panels, farthest first as they arrive, then
  /// every top rail over all of them so no rail is overpainted by the panel
  /// standing behind it.
  void _drawWalls(Canvas canvas, PlotOverlay overlay, Color tint, double alpha) {
    for (final wall in overlay.walls) {
      final path = _path(wall.quad);
      if (path == null) continue;
      canvas.drawPath(path, _fill(tint, PlotAlpha.wallFill * alpha * wall.opacity));
    }
    for (final rail in overlay.rails) {
      // Drawn twice: a dark backing stroke, then the colour over it. A single
      // coloured line disappears wherever the background shares its luminance.
      final from = _o(rail.from);
      final to = _o(rail.to);
      canvas.drawLine(from, to, _stroke(_outlineBacking, 0.5 * alpha * rail.opacity, 11));
      canvas.drawLine(from, to, _stroke(tint, PlotAlpha.rail * alpha * rail.opacity, 7));
    }
  }

  void _drawFarMode(Canvas canvas, PlotOverlay overlay, Color tint, double alpha) {
    final path = _path(overlay.fill);
    if (path == null) return;

    // Demoted to a hint. The walls carry the boundary; this only says which side
    // of it the crop is on.
    canvas.drawPath(path, _fill(tint, PlotAlpha.groundFill * alpha));
    canvas.drawPath(path, _stroke(tint, PlotAlpha.outline * alpha, 3));

    // Vertical posts at the corners. Posts read against the horizon and stay
    // legible when heading is a few degrees off.
    for (final post in overlay.posts) {
      final base = _o(post.base);
      final top = _o(post.top);
      canvas.drawLine(base, top, _stroke(_outlineBacking, 0.5 * alpha, 12));
      canvas.drawLine(base, top, _stroke(tint, alpha, 8));
      canvas.drawCircle(top, _px(10), _fill(tint, alpha));
    }
  }

  void _drawNearMode(Canvas canvas, PlotOverlay overlay, Color tint, double alpha) {
    // No fill inside 30 m: claiming an area implies knowing where its edges are
    // to better than the fix allows.
    for (final band in overlay.bands) {
      final path = _path(band.corners);
      if (path == null) continue;
      canvas.drawPath(path, _fill(tint, 0.22 * alpha));
      canvas.drawPath(path, _stroke(tint, 0.5 * alpha, 2));
    }
  }

  /// The plot is out of frame; point at it from the edge of the screen rather
  /// than leaving the agent to sweep the horizon.
  void _drawEdgeArrow(Canvas canvas, Size size, double relativeBearingDeg, Color tint, double alpha) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.38;
    final s = _px(1);

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(relativeBearingDeg * math.pi / 180.0);
    canvas.translate(0, -radius);
    final arrow = Path()
      ..moveTo(0, -28 * s)
      ..lineTo(22 * s, 18 * s)
      ..lineTo(0, 6 * s)
      ..lineTo(-22 * s, 18 * s)
      ..close();
    canvas.drawPath(arrow, _fill(tint, 0.9 * alpha));
    canvas.restore();
  }

  void _drawCrosshair(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final arm = _px(22);
    final paint = _stroke(Colors.white, 0.75, 2);
    canvas.drawLine(centre.translate(-arm, 0), centre.translate(arm, 0), paint);
    canvas.drawLine(centre.translate(0, -arm), centre.translate(0, arm), paint);
    canvas.drawCircle(centre, _px(3), _fill(Colors.white, 0.75));
  }

  void _drawLabel(Canvas canvas, String text, ScreenPoint at, Color tint, double alpha) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: Colors.white.withAlpha(alpha8(alpha)), fontSize: _px(34))),
      textDirection: TextDirection.ltr,
    )..layout();
    final padding = _px(14);
    final rect = Rect.fromLTWH(
      at.x - painter.width / 2 - padding,
      at.y - _px(48),
      painter.width + padding * 2,
      _px(52),
    );
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(_px(8))), _fill(_labelBackground, alpha * 0.8));
    painter.paint(canvas, Offset(at.x - painter.width / 2, rect.center.dy - painter.height / 2));
    canvas.drawCircle(_o(at), _px(5), _fill(tint, alpha));
  }

  /// Text centred horizontally on [baseline]'s x, sitting on its y.
  void _drawText(Canvas canvas, String text, Offset baseline, TextStyle style) {
    final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
      ..layout();
    final ascent = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    painter.paint(canvas, Offset(baseline.dx - painter.width / 2, baseline.dy - ascent));
  }

  @override
  bool shouldRepaint(ArOverlayPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.plotId != plotId ||
      oldDelegate.areaHectares != areaHectares ||
      oldDelegate.confidence != confidence ||
      oldDelegate.accuracyM != accuracyM ||
      oldDelegate.colourIndex != colourIndex ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
