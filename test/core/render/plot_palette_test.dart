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
}
