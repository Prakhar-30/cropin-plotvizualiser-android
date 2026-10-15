import 'package:flutter_test/flutter_test.dart';
import 'package:plot_finder/ui/formatting.dart';

void main() {
  test('distances read in metres, then kilometres', () {
    expect(formatDistance(127.9), '127 m');
    expect(formatDistance(1530.0), '1.5 km');
    expect(formatDistance(double.infinity), '—');
  });

  test('areas read in hectares to two places', () {
    expect(formatHectares(25000.0), '2.50 ha');
  });

  test('cache age rounds down to the largest whole unit', () {
    const now = 100 * 24 * 60 * 60000;
    expect(formatCacheAge(now - 30000, nowMs: now), 'just now');
    expect(formatCacheAge(now - 5 * 60000, nowMs: now), '5 min ago');
    expect(formatCacheAge(now - 3 * 60 * 60000, nowMs: now), '3 h ago');
    expect(formatCacheAge(now - 2 * 24 * 60 * 60000, nowMs: now), '2 d ago');
  });

  test('ISO timestamps are trimmed to the date', () {
    expect(formatIsoDate('2026-08-01T10:00:00Z'), '2026-08-01');
    expect(formatIsoDate('2026-08-01'), '2026-08-01');
  });
}
