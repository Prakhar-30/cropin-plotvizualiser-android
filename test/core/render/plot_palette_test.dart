import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/core/render/plot_palette.dart';

/// The palette mirrors palette.json, so these check the contract the renderer
/// relies on rather than the specific hues.
void main() {
  test('every slot is fully opaque ARGB', () {
    // Alpha must be baked in at 0xFF: the renderer applies PlotAlpha per
    // surface, and a colour carrying its own transparency would multiply
    // twice and wash the boundary out.
    for (final colour in plotColours) {
      final alpha = (colour.argb >> 24) & 0xFF;
      expect(alpha, 0xFF, reason: 'slot ${colour.index} (${colour.name}) is not opaque');
    }
  });

  test('slots are distinct and densely indexed', () {
    expect(plotColours.map((c) => c.argb).toSet().length, plotColours.length);
    expect(plotColours.map((c) => c.index).toList(), List.generate(plotColours.length, (i) => i));
  });

  test('an out of range colour index wraps rather than throwing', () {
    // A plot arriving with a bad slot must still be drawn. This is the whole
    // reason plotColour does modular arithmetic instead of indexing.
    expect(plotColour(0), same(plotColours[0]));
    expect(plotColour(plotColours.length + 1), same(plotColours[1]));
    expect(plotColour(-1), same(plotColours[plotColours.length - 1]));
  });

  test('no slot is green', () {
    // Green boundaries vanish against a green crop and against satellite
    // imagery of farmland, which is the one background this app always has.
    for (final colour in plotColours) {
      final r = (colour.argb >> 16) & 0xFF;
      final g = (colour.argb >> 8) & 0xFF;
      final b = colour.argb & 0xFF;
      expect(!(g > r + 40 && g > b + 40), isTrue,
          reason: 'slot ${colour.index} (${colour.name}) is dominated by green');
    }
  });

  test('no slot can be mistaken for crop condition', () {
    // Red and yellow mean critical and moderate ground. A red plot beside a
    // yellow plot read in the field exactly like a critical patch beside a
    // moderate one, so plot slots stay out of the red-orange-yellow-pink hues:
    // anything with real colour must sit between cyan and violet.
    for (final colour in plotColours) {
      final r = ((colour.argb >> 16) & 0xFF) / 255.0;
      final g = ((colour.argb >> 8) & 0xFF) / 255.0;
      final b = (colour.argb & 0xFF) / 255.0;
      final hi = [r, g, b].reduce((a, c) => a > c ? a : c);
      final lo = [r, g, b].reduce((a, c) => a < c ? a : c);
      final saturation = hi == 0 ? 0.0 : (hi - lo) / hi;
      if (saturation < 0.2) continue; // white reads as neither
      final delta = hi - lo;
      var hue = hi == r
          ? 60 * (((g - b) / delta) % 6)
          : hi == g
              ? 60 * ((b - r) / delta + 2)
              : 60 * ((r - g) / delta + 4);
      if (hue < 0) hue += 360;
      expect(hue, inInclusiveRange(180, 320), reason: 'slot ${colour.index} (${colour.name}) has hue $hue');
    }
  });
}
