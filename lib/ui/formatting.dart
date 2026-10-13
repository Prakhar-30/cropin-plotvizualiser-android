/// One place to decide how numbers read, so the list, the detail screen and the
/// AR label never disagree about what "120 m" looks like.

String formatDistance(double metres) {
  if (!metres.isFinite) return '—';
  if (metres < 1000) return '${metres.toInt()} m';
  return '${(metres / 1000).toStringAsFixed(1)} km';
}

String formatHectares(double areaSqM) => '${(areaSqM / 10000.0).toStringAsFixed(2)} ha';

String formatLatLng(double lat, double lng) => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';

/// How old the cached copy is.
///
/// Worth showing: offline, the agent has no other way to tell whether the
/// boundary they are standing on was pulled this morning or three weeks ago.
String formatCacheAge(int syncedAtMs, {int? nowMs}) {
  final minutes = ((nowMs ?? DateTime.now().millisecondsSinceEpoch) - syncedAtMs) ~/ 60000;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  if (minutes < 60 * 24) return '${minutes ~/ 60} h ago';
  return '${minutes ~/ (60 * 24)} d ago';
}

/// Trims the API's ISO timestamp to the date, which is all that is meaningful here.
String formatIsoDate(String iso) {
  final date = iso.split('T').first;
  return date.trim().isEmpty ? iso : date;
}
