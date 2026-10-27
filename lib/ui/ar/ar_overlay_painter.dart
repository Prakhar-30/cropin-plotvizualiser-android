import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/geo/projection.dart';
import '../../core/heading/heading_model.dart';
import '../../core/render/health_geometry.dart';
import '../../core/render/overlay_geometry.dart';
import '../../core/render/plot_palette.dart';
import '../../core/render/world_scene.dart';
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
    required this.confidence,
    required this.accuracyM,
    required this.devicePixelRatio,
    this.drawGeometry = true,
  }) : super(repaint: frame);

  final ValueListenable<ArFrame?> frame;
  final HeadingConfidence confidence;
  final double accuracyM;
  final double devicePixelRatio;

  /// False on the ARCore path, where the boundaries and the drop points are
  /// drawn natively in the camera's own GL frame. This canvas then carries only
  /// text and screen furniture: the labels, the off-screen arrow, the crosshair.
  final bool drawGeometry;

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

    // Three tiers. HOLDING is only a nudge; the chip states the source, age
    // and expected error. The dimming marks the genuinely untrustworthy case.
    final alpha = overlayConfidenceAlpha(confidence);

    if (drawGeometry) {
      // Graded ground first; the boundary ribbons lie over it.
      for (final cell in current.cells) {
        final path = _path(cell.points);
        if (path == null) continue;
        final colour = severityColour(cell.zone);
        canvas.drawPath(path, _fill(Color(colour.argb), colour.fillAlpha * alpha));
      }
      // Farthest plot first, so a near plot's boundary paints over a far one's.
      // The nearest plot's line is drawn a little bolder.
      final plots = current.plots;
      for (var i = plots.length - 1; i >= 0; i--) {
        final drawn = plots[i];
        _drawBoundary(canvas, drawn.overlay, Color(overlayTintArgb(confidence, drawn.plot.colourIndex)), alpha,
            primary: i == 0);
      }
      // Drop points stand over every boundary: a walk-to target is the thing to
      // find on screen.
      for (final drop in current.drops) {
        _drawDropPoint(canvas, drop, alpha);
      }
    }

    // When no plot is on screen, point at the nearest one.
    if (current.plots.isNotEmpty) {
      final nearest = current.plots.first;
      final offscreen = nearest.overlay.offscreenBearingDeg;
      if (offscreen != null && current.plots.every((p) => p.overlay.offscreenBearingDeg != null)) {
        _drawEdgeArrow(canvas, size, offscreen, Color(overlayTintArgb(confidence, nearest.plot.colourIndex)), alpha);
      }
    }

    // A label per plot, pinned to a point on the ground inside it: which plot,
    // how big, how far. Nearest first, and each later one is lifted clear of
    // those already placed, so neighbouring plots never print over each other.
    final placed = <Rect>[];
    for (final (i, drawn) in current.plots.indexed) {
      final label = drawn.overlay.label;
      if (label == null) continue;
      final near = drawn.overlay.mode == RenderMode.near;
      final text = '${drawn.plot.name}  ${drawn.plot.areaHectares.toStringAsFixed(2)} ha  '
          '${label.distanceM.toStringAsFixed(0)} m${near ? '  ±${accuracyM.toStringAsFixed(0)} m' : ''}';
      _drawLabel(
        canvas,
        text,
        label.at,
        Color(overlayTintArgb(confidence, drawn.plot.colourIndex)),
        alpha,
        placed,
        primary: i == 0,
      );
    }
  }

  /// A drop point on the sensor path: a stem from the ground to above the
  /// walls, and a disc in the zone's colour on top.
  void _drawDropPoint(Canvas canvas, DropMarker drop, double alpha) {
    final colour = Color(severityColour(drop.zone).argb);
    final base = _o(drop.base);
    final top = _o(drop.top);
    canvas.drawLine(base, top, _stroke(_outlineBacking, 0.55 * alpha, 14));
    canvas.drawLine(base, top, _stroke(colour, alpha, 8));
    final radius = _px(26) * (10.0 / drop.distanceM.clamp(4.0, 60.0)).clamp(0.4, 1.3);
    canvas.drawCircle(top, radius + _px(4), _fill(_outlineBacking, 0.7 * alpha));
    canvas.drawCircle(top, radius, _fill(colour, alpha));
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

  /// A plot's boundary, flat on the ground: the ribbon from the boundary into
  /// the plot, then the line down its middle on a dark backing, so it reads
  /// against bright sky, pale soil and crop alike.
  void _drawBoundary(Canvas canvas, PlotOverlay overlay, Color tint, double alpha, {required bool primary}) {
    for (final ribbon in overlay.ribbons) {
      final path = _path(ribbon.corners);
      if (path == null) continue;
      canvas.drawPath(path, _fill(tint, PlotAlpha.ribbon * alpha));
    }
    for (final line in overlay.lines) {
      final from = _o(line.from);
      final to = _o(line.to);
      canvas.drawLine(from, to, _stroke(_outlineBacking, 0.5 * alpha, primary ? 11 : 9));
      canvas.drawLine(from, to, _stroke(tint, PlotAlpha.outline * alpha, primary ? 7 : 5));
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

  /// A label standing on [at], a ground point inside its plot, with a stalk
  /// down to a dot on that point. Lifted above any rectangle in [placed] it
  /// would overlap, then added to it.
  void _drawLabel(
    Canvas canvas,
    String text,
    ScreenPoint at,
    Color tint,
    double alpha,
    List<Rect> placed, {
    required bool primary,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: Colors.white.withAlpha(alpha8(alpha)), fontSize: _px(primary ? 34 : 28)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final padding = _px(14);
    final height = painter.height + _px(14);
    var rect = Rect.fromLTWH(
      at.x - painter.width / 2 - padding,
      at.y - _px(16) - height,
      painter.width + padding * 2,
      height,
    );
    for (var tries = 0; tries < 6 && placed.any((r) => r.overlaps(rect.inflate(_px(4)))); tries++) {
      rect = rect.translate(0, -(height + _px(8)));
    }
    placed.add(rect);

    final ground = _o(at);
    canvas.drawLine(ground, Offset(ground.dx, rect.bottom), _stroke(tint, 0.9 * alpha, 3));
    canvas.drawCircle(ground, _px(7), _fill(_outlineBacking, 0.6 * alpha));
    canvas.drawCircle(ground, _px(5), _fill(tint, alpha));
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(_px(8))), _fill(_labelBackground, alpha * 0.8));
    // A strip of the plot's colour on the left says which outline it belongs to.
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(rect.left, rect.top, _px(6), rect.height),
        topLeft: Radius.circular(_px(8)),
        bottomLeft: Radius.circular(_px(8)),
      ),
      _fill(tint, alpha),
    );
    painter.paint(canvas, Offset(rect.left + padding, rect.center.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(ArOverlayPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.confidence != confidence ||
      oldDelegate.accuracyM != accuracyM ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      oldDelegate.drawGeometry != drawGeometry;
}
