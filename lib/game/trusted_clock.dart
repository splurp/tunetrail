import 'dart:io';

import 'package:http/http.dart' as http;

/// Wall-clock time that the player can't move by changing the device's
/// date/time: the current UTC time from an HTTPS server's `Date` header,
/// advanced with a monotonic stopwatch between syncs.
class TrustedClock {
  TrustedClock([http.Client? client]) : _client = client ?? http.Client();
  final http.Client _client;
  DateTime? _base;
  final Stopwatch _since = Stopwatch();

  static const _hosts = ['https://api.deezer.com/', 'https://itunes.apple.com/', 'https://tiles.openfreemap.org/'];

  /// Trusted UTC now, or null if no server could be reached.
  Future<DateTime?> now() async {
    final b = _base;
    if (b != null && _since.elapsed < const Duration(minutes: 30)) return b.add(_since.elapsed);
    for (final h in _hosts) {
      try {
        final res = await _client.head(Uri.parse(h)).timeout(const Duration(seconds: 8));
        final d = res.headers['date'];
        if (d == null) continue;
        _base = HttpDate.parse(d).toUtc();
        _since
          ..reset()
          ..start();
        return _base;
      } catch (_) {}
    }
    return b?.add(_since.elapsed);
  }

  /// "yyyy-mm-dd" of [utc] shifted by [offsetMinutes].
  static String dayKey(DateTime utc, int offsetMinutes) {
    final l = utc.add(Duration(minutes: offsetMinutes));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }

  /// Time until the next local midnight.
  static Duration untilMidnight(DateTime utc, int offsetMinutes) {
    final l = utc.add(Duration(minutes: offsetMinutes));
    final next = DateTime.utc(l.year, l.month, l.day).add(const Duration(days: 1));
    return next.difference(DateTime.utc(l.year, l.month, l.day, l.hour, l.minute, l.second));
  }
}
