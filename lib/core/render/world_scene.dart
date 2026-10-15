import 'dart:typed_data';

import '../geo/enu.dart';
import '../geo/linear.dart';
import '../geo/polygon_geometry.dart';
import '../geo/projection.dart';
import '../heading/heading_model.dart';
import '../math_util.dart';
import 'health_geometry.dart';
import 'overlay_geometry.dart';
import 'plot_palette.dart';

/// The plot as the native ARCore renderer draws it, and where it stands.
///
/// On the ARCore path the boundary is no longer projected here and painted on
/// the Flutter canvas. Painting it there meant it was always drawn with the pose
/// of a frame or two ago, over a camera image that was already newer - so it
/// trailed every turn of the hand and slid back when the hand stopped. Instead
/// the geometry is handed to the GL renderer that draws the camera image, which
/// projects it with that same frame's camera.
///
/// Two messages, deliberately separate:
///
///  - a [WorldScene]: the plot in its own metric frame (east, north, up from the
///    plot's centroid). Sent when the plot, the health layer or the heading
///    confidence changes - a handful of times a session.
///  - a [WorldPlacement]: how that frame sits in ARCore's session. Sent only when
///    the geo-registration moves - a pin, a heading lock, a GNSS drift
///    correction - and never because the camera moved, since ARCore already
///    knows where the camera is.

/// Colour the plot is drawn in: its palette slot, or grey when the heading
/// cannot be trusted. See `ArOverlayPainter` for why identity colour depends
/// on the heading.
const int unreliableTintArgb = 0xFF9CA3AF;

int overlayTintArgb(HeadingConfidence confidence, int colourIndex) =>
    confidence == HeadingConfidence.unreliable ? unreliableTintArgb : plotColour(colourIndex).argb;

/// Overall opacity for a heading-confidence tier.
double overlayConfidenceAlpha(HeadingConfidence confidence) => switch (confidence) {
      HeadingConfidence.locked => 1.0,
      HeadingConfidence.holding => 0.85,
      HeadingConfidence.unreliable => 0.45,
    };

class WorldScene {
  const WorldScene({
    required this.fill,
    required this.ring,
    required this.cells,
    required this.tintArgb,
    required this.alpha,
  });

  /// Ground fill, triangulated: (east, north) per vertex.
  final Float32List fill;

  /// Boundary, open ring: (east, north) per vertex.
  final Float32List ring;

  /// Health cells, triangulated: (east, north, r, g, b, a) per vertex.
  final Float32List cells;
  final int tintArgb;
  final double alpha;

  Map<String, Object> toMessage() => {
        'fill': fill,
        'ring': ring,
        'cells': cells,
        'wallHeight': boundaryWallHeightM,
        'postHeight': vertexPostHeightM,
        'tint': tintArgb,
        'alpha': alpha,
        'wallAlpha': PlotAlpha.wallFill,
        'fillAlpha': PlotAlpha.groundFill,
        'railAlpha': PlotAlpha.rail,
      };
}

/// Builds the scene in the frame centred on [origin], normally the plot's
/// centroid.
WorldScene buildWorldScene({
  required List<LatLng> ring,
  required LatLng origin,
  required List<HealthCell> cells,
  required HealthLayer layer,
  required int tintArgb,
  required double alpha,
}) {
  final frame = EnuFrame(origin);
  final boundary = openRing([for (final p in ring) frame.toEnu(p)]);

  final fill = <double>[];
  for (final i in triangulate(boundary)) {
    fill
      ..add(boundary[i].east)
      ..add(boundary[i].north);
  }

  final cellData = <double>[];
  if (layer != HealthLayer.off) {
    for (final cell in cells) {
      if (cell.severity < layer.minSeverity) continue;
      final cellRing = openRing([for (final p in cell.ring) frame.toEnu(p)]);
      final band = severityColour(cell.severity);
      final r = ((band.argb >> 16) & 0xFF) / 255.0;
      final g = ((band.argb >> 8) & 0xFF) / 255.0;
      final b = (band.argb & 0xFF) / 255.0;
      for (final i in triangulate(cellRing)) {
        cellData.addAll([cellRing[i].east, cellRing[i].north, r, g, b, band.fillAlpha]);
      }
    }
  }

  return WorldScene(
    fill: Float32List.fromList(fill),
    ring: Float32List.fromList([
      for (final p in boundary) ...[p.east, p.north],
    ]),
    cells: Float32List.fromList(cellData),
    tintArgb: tintArgb,
    alpha: alpha,
  );
}

/// How the plot's frame sits in ARCore's session: a rotation from true
/// east-north into the session's arbitrary east-north, then where the plot's
/// origin lands in it.
///
/// `session = [a b; c d] · local + (tEast, tNorth)`.
class WorldPlacement {
  const WorldPlacement(this.a, this.b, this.c, this.d, this.tEast, this.tNorth);

  final double a;
  final double b;
  final double c;
  final double d;
  final double tEast;
  final double tNorth;

  Float64List toList() => Float64List.fromList([a, b, c, d, tEast, tNorth]);

  /// Session position of a point given in the plot's frame.
  Enu apply(Enu local) => Enu(a * local.east + b * local.north + tEast, c * local.east + d * local.north + tNorth);

  /// Within a few millimetres and a few hundredths of a degree: not worth a
  /// message to the renderer.
  bool isCloseTo(WorldPlacement other) =>
      (a - other.a).abs() < 3e-4 &&
      (b - other.b).abs() < 3e-4 &&
      (c - other.c).abs() < 3e-4 &&
      (d - other.d).abs() < 3e-4 &&
      hypot(tEast - other.tEast, tNorth - other.tNorth) < 0.005;
}

/// Places the plot whose frame is centred on [plotOrigin].
///
/// [agent] is where the camera is believed to be on the earth, and
/// [sessionCamera] where ARCore has it in the session, at the same moment.
/// [yawOffsetDeg] is true heading minus session heading. Walking moves both
/// camera positions by the same amount, so the result only changes when the
/// geo-registration itself does.
WorldPlacement placePlot({
  required LatLng plotOrigin,
  required LatLng agent,
  required Enu sessionCamera,
  required double yawOffsetDeg,
}) {
  final toSession = yawAboutUp(-yawOffsetDeg);
  final fromAgent = EnuFrame(agent).toEnu(plotOrigin);
  final rotated = toSession.timesVec(Vec3(fromAgent.east, fromAgent.north, 0.0));
  return WorldPlacement(
    toSession.m00,
    toSession.m01,
    toSession.m10,
    toSession.m11,
    rotated.x + sessionCamera.east,
    rotated.y + sessionCamera.north,
  );
}

/// Ear-clipping triangulation of a simple polygon, either winding.
///
/// Returns vertex indices, three per triangle. Plot boundaries are concave
/// often enough - an L-shaped field, a notch around a well - that a fan from
/// one vertex would paint ground outside the plot.
List<int> triangulate(List<Enu> polygon) {
  final n = polygon.length;
  if (n < 3) return const [];

  var twiceArea = 0.0;
  for (var i = 0; i < n; i++) {
    final p = polygon[i];
    final q = polygon[(i + 1) % n];
    twiceArea += p.east * q.north - q.east * p.north;
  }
  final counterClockwise = twiceArea > 0.0;

  double cross(Enu a, Enu b, Enu c) => (b.east - a.east) * (c.north - a.north) - (b.north - a.north) * (c.east - a.east);

  bool inside(Enu p, Enu a, Enu b, Enu c) {
    final d1 = cross(a, b, p);
    final d2 = cross(b, c, p);
    final d3 = cross(c, a, p);
    final negative = d1 < 0 || d2 < 0 || d3 < 0;
    final positive = d1 > 0 || d2 > 0 || d3 > 0;
    return !(negative && positive);
  }

  final remaining = List<int>.generate(n, (i) => i);
  final out = <int>[];
  while (remaining.length > 3) {
    var clipped = false;
    final len = remaining.length;
    for (var i = 0; i < len; i++) {
      final ip = remaining[(i - 1 + len) % len];
      final ic = remaining[i];
      final inx = remaining[(i + 1) % len];
      final a = polygon[ip];
      final b = polygon[ic];
      final c = polygon[inx];
      final turn = cross(a, b, c);
      // Reflex or degenerate corner: not an ear.
      if (counterClockwise ? turn <= 1e-12 : turn >= -1e-12) continue;
      var blocked = false;
      for (final j in remaining) {
        if (j == ip || j == ic || j == inx) continue;
        if (inside(polygon[j], a, b, c)) {
          blocked = true;
          break;
        }
      }
      if (blocked) continue;
      out.addAll([ip, ic, inx]);
      remaining.removeAt(i);
      clipped = true;
      break;
    }
    if (!clipped) {
      // Self-intersecting or fully degenerate input. A fan over what is left
      // still draws something rather than nothing.
      for (var i = 1; i < remaining.length - 1; i++) {
        out.addAll([remaining[0], remaining[i], remaining[i + 1]]);
      }
      return out;
    }
  }
  out.addAll(remaining);
  return out;
}
