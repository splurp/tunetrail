import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';

/// Apple Music and Spotify buttons for a song: tapping one opens the song
/// in that service (app if installed, else the web player).
class StoreLinks extends StatelessWidget {
  const StoreLinks({super.key, required this.song, this.size = 22, this.gap = 6});
  final Song song;
  final double size;
  final double gap;

  static final http.Client _client = http.Client();
  static final Map<int, String> _appleUrls = {};

  static String _query(Song s) => '${s.title} ${s.artistName}';

  /// The song's Apple Music page (iTunes lookup), or an Apple Music search.
  static Future<Uri> appleMusicUrl(Song s) async {
    final cached = _appleUrls[s.id];
    if (cached != null) return Uri.parse(cached);
    try {
      final res = await _client
          .get(Uri.https('itunes.apple.com', '/search', {'term': _query(s), 'entity': 'song', 'limit': '10'}))
          .timeout(const Duration(seconds: 6));
      final results = (jsonDecode(res.body)['results'] as List? ?? const []).cast<Map<String, dynamic>>();
      String norm(String x) => x.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final hit = results.where((r) => norm(r['artistName'] as String? ?? '').contains(norm(s.artistName).isEmpty ? '#' : norm(s.artistName))).firstOrNull ?? results.firstOrNull;
      final url = hit?['trackViewUrl'] as String?;
      if (url != null) return Uri.parse(_appleUrls[s.id] = url);
    } catch (_) {}
    return Uri.https('music.apple.com', '/search', {'term': _query(s)});
  }

  /// A Spotify search for the song (opens the app when installed).
  static Uri spotifyUrl(Song s) => Uri.parse('https://open.spotify.com/search/${Uri.encodeComponent(_query(s))}');

  static Future<void> _open(Future<Uri> url) async {
    try {
      await launchUrl(await url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _LogoButton(
        tooltip: 'Open in Apple Music',
        size: size,
        painter: _AppleMusicLogo(),
        onTap: () => _open(appleMusicUrl(song)),
      ),
      SizedBox(width: gap),
      _LogoButton(
        tooltip: 'Open in Spotify',
        size: size,
        painter: _SpotifyLogo(),
        onTap: () => _open(Future.value(spotifyUrl(song))),
      ),
    ]);
  }
}

class _LogoButton extends StatelessWidget {
  const _LogoButton({required this.tooltip, required this.size, required this.painter, required this.onTap});
  final String tooltip;
  final double size;
  final CustomPainter painter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: DecoratedBox(
                decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 4)], shape: BoxShape.circle),
                child: CustomPaint(size: Size.square(size), painter: painter),
              ),
            ),
          ),
        ),
      );
}

/// Spotify's mark: a green disc with three curved sound waves.
class _SpotifyLogo extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF1ED760));
    final wave = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final (dy, w, t) in [(-0.28, 1.25, 0.13), (0.02, 1.05, 0.11), (0.28, 0.85, 0.09)]) {
      wave.strokeWidth = r * t * 1.25;
      final arcR = r * w;
      final centre = Offset(c.dx, c.dy + dy * r + arcR * 0.86);
      canvas.drawArc(Rect.fromCircle(center: centre, radius: arcR), -math.pi / 2 - 0.5, 1.0, false, wave);
    }
  }

  @override
  bool shouldRepaint(_SpotifyLogo old) => false;
}

/// Apple Music's mark: a red-pink rounded square with a white note.
class _AppleMusicLogo extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.24)),
      Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFA5A73), Color(0xFFFA233B)]).createShader(rect),
    );
    final w = size.width;
    final white = Paint()..color = Colors.white;
    // Two note heads joined by a beam.
    canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.33, w * 0.70), width: w * 0.24, height: w * 0.18), white);
    canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.68, w * 0.62), width: w * 0.24, height: w * 0.18), white);
    final stem = Paint()
      ..color = Colors.white
      ..strokeWidth = w * 0.07
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.43, w * 0.68), Offset(w * 0.43, w * 0.26), stem);
    canvas.drawLine(Offset(w * 0.78, w * 0.60), Offset(w * 0.78, w * 0.18), stem);
    canvas.drawLine(Offset(w * 0.43, w * 0.28), Offset(w * 0.78, w * 0.20), stem..strokeWidth = w * 0.11);
  }

  @override
  bool shouldRepaint(_AppleMusicLogo old) => false;
}
