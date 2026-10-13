/// AR plot boundary finder, as an embeddable feature.
///
/// ```dart
/// if (plotFinderSupported) {
///   Navigator.of(context).push(MaterialPageRoute<void>(
///     builder: (_) => const PlotFinderScreen(
///       config: PlotFinderConfig(apiBaseUrl: 'https://plots.example.com/'),
///     ),
///   ));
/// }
/// ```
library;

export 'config.dart' show PlotFinderConfig;
export 'ui/plot_finder_screen.dart' show PlotFinderScreen, plotFinderSupported;
