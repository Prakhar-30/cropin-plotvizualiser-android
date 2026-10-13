import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dtos.dart';

/// The companion web tool's API, exactly as it is served.
///
/// `near` is the endpoint that matters: the agent is dispatched to a place, and
/// the app caches everything within a radius of it so the whole visit works with
/// the radio off.
abstract interface class PlotApi {
  Future<List<PlotDto>> listPlots();

  /// [near] is formatted as "lat,lng".
  Future<List<PlotDto>> listPlotsNear(String near, int radiusM);

  /// The crop-health raster for one plot.
  ///
  /// Separate from the plot itself because it is an order of magnitude larger -
  /// a few hundred graded cells against one boundary ring - and because it has
  /// a different lifetime: a boundary is drawn once, a health snapshot is
  /// re-derived every time new imagery lands. Bundling them would force a
  /// re-download of every boundary to refresh a raster.
  Future<HealthDto> health(String id);

  /// Telemetry upload. The web service does not implement this yet; the client
  /// side is built now so that switching it on is a server change alone.
  Future<void> uploadTelemetry(List<TelemetryDto> rows);
}

/// Where the companion web tool's API lives.
///
/// The app cannot create a plot of its own - boundaries come from the web tool
/// and nowhere else - so an unreachable API means an empty list. 10.0.2.2 is
/// only the emulator's route to the host; a real handset needs the dev
/// machine's LAN address, or a deployed URL:
///
///     flutter run --dart-define=PLOT_API_BASE_URL=http://192.168.1.20:4000/
const String defaultApiBaseUrl =
    String.fromEnvironment('PLOT_API_BASE_URL', defaultValue: 'http://10.0.2.2:4000/');

/// [PlotApi] over plain `dart:io` HTTP.
///
/// The timeouts are short on purpose. Sync is opportunistic: at a rural site the
/// radio either works within a couple of seconds or it does not work at all, and
/// a request hanging for thirty seconds is a spinner the agent watches instead of
/// a cached plot they could already be walking to.
class HttpPlotApi implements PlotApi {
  HttpPlotApi({String baseUrl = defaultApiBaseUrl})
      : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  static const Duration _readTimeout = Duration(seconds: 8);

  final Uri _base;
  final HttpClient _client;

  @override
  Future<List<PlotDto>> listPlots() async => _plots(await _get('api/plots'));

  @override
  Future<List<PlotDto>> listPlotsNear(String near, int radiusM) async =>
      _plots(await _get('api/plots', {'near': near, 'radius_m': '$radiusM'}));

  @override
  Future<HealthDto> health(String id) async =>
      HealthDto.fromJson(await _get('api/plots/${Uri.encodeComponent(id)}/health') as Json);

  @override
  Future<void> uploadTelemetry(List<TelemetryDto> rows) async {
    final request = await _client.postUrl(_base.resolve('api/telemetry'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode([for (final r in rows) r.toJson()]));
    await _read(await request.close().timeout(_readTimeout));
  }

  List<PlotDto> _plots(Object? body) => [
        for (final p in body as List<dynamic>) PlotDto.fromJson(p as Json),
      ];

  void close() => _client.close(force: true);

  Future<Object?> _get(String path, [Map<String, String>? query]) async {
    var uri = _base.resolve(path);
    if (query != null) uri = uri.replace(queryParameters: query);
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final text = await _read(await request.close().timeout(_readTimeout));
    return jsonDecode(text);
  }

  Future<String> _read(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join().timeout(_readTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: null);
    }
    return text;
  }
}
