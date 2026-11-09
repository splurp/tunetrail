import 'dart:convert';

import 'package:http/http.dart' as http;

/// Spotify numbers from kworb.net (public pages built from Spotify's own
/// counts): artists' monthly listeners and every song's all-time streams.
///
/// Used by trivia, where "most popular" should mean all-time streams, not
/// what is hot this week (Deezer's top tracks).
class SpotifyStats {
  SpotifyStats._();
  static final SpotifyStats instance = SpotifyStats._();

  final http.Client _client = http.Client();
  Future<Map<String, (String, int)>>? _listeners;
  final Map<String, Future<List<SpotifySong>>> _songs = {};
  final Map<String, Future<String?>> _ids = {};

  static String _key(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9À-￿]+'), '');

  static final _listenerRow = RegExp(r'<a href="artist/([A-Za-z0-9]{22})_songs\.html">([^<]+)</a></div></td><td>([\d,]+)</td>');
  static final _songRow = RegExp(r'<div>(\* )?<a href="https://open\.spotify\.com/track/[A-Za-z0-9]+"[^>]*>([^<]+)</a></div></td><td>([\d,]+)</td>');

  static int _num(String s) => int.tryParse(s.replaceAll(',', '')) ?? 0;

  static String _unescape(String s) =>
      s.replaceAll('&amp;', '&').replaceAll('&#39;', "'").replaceAll('&quot;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>');

  /// Parses kworb's monthly-listeners chart: normalised name → (Spotify id, listeners).
  static Map<String, (String, int)> parseListeners(String html) => {
        for (final m in _listenerRow.allMatches(html)) _key(_unescape(m.group(2)!)): (m.group(1)!, _num(m.group(3)!)),
      };

  /// Parses an artist's song list (sorted by all-time streams). Songs where
  /// the artist is only featured are marked.
  static List<SpotifySong> parseSongs(String html) => [
        for (final m in _songRow.allMatches(html)) SpotifySong(_unescape(m.group(2)!), _num(m.group(3)!), featured: m.group(1) != null),
      ];

  Future<String> _get(String url) async {
    final res = await _client.get(Uri.parse(url), headers: {'User-Agent': 'Tunetrail/0.2'}).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw StateError('kworb ${res.statusCode}');
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  Future<Map<String, (String, int)>> _chart() => _listeners ??= _get('https://kworb.net/spotify/listeners.html').then(parseListeners).catchError((Object e) {
        _listeners = null;
        throw e;
      });

  /// Spotify monthly listeners, for artists in kworb's top-2500 chart.
  Future<int?> monthlyListeners(String artistName) async => (await _chart())[_key(artistName)]?.$2;

  /// The artist's Spotify id: from the listeners chart, else MusicBrainz's
  /// links for the artist.
  Future<String?> spotifyId(String artistName) => _ids[_key(artistName)] ??= () async {
        try {
          final hit = (await _chart())[_key(artistName)];
          if (hit != null) return hit.$1;
        } catch (_) {}
        try {
          final q = Uri.https('musicbrainz.org', '/ws/2/artist', {'query': 'artist:"$artistName"', 'fmt': 'json', 'limit': '3'});
          final res = await _client.get(q, headers: {'User-Agent': 'Tunetrail/0.2 (https://github.com/splurp/tunetrail)'}).timeout(const Duration(seconds: 12));
          final artists = (jsonDecode(res.body)['artists'] as List? ?? const []).cast<Map<String, dynamic>>();
          final a = artists.where((a) => _key(a['name'] as String? ?? '') == _key(artistName)).firstOrNull;
          if (a == null) return null;
          final rel = await _client.get(Uri.https('musicbrainz.org', '/ws/2/artist/${a['id']}', {'inc': 'url-rels', 'fmt': 'json'}),
              headers: {'User-Agent': 'Tunetrail/0.2 (https://github.com/splurp/tunetrail)'}).timeout(const Duration(seconds: 12));
          for (final r in (jsonDecode(rel.body)['relations'] as List? ?? const []).cast<Map<String, dynamic>>()) {
            final url = (r['url'] as Map?)?['resource'] as String? ?? '';
            final m = RegExp(r'open\.spotify\.com/artist/([A-Za-z0-9]{22})').firstMatch(url);
            if (m != null) return m.group(1);
          }
        } catch (_) {}
        return null;
      }();

  /// The artist's own songs (not features), most streamed of all time first.
  Future<List<SpotifySong>> topSongs(String artistName) async {
    final id = await spotifyId(artistName);
    if (id == null) return const [];
    final all = await (_songs[id] ??= _get('https://kworb.net/spotify/artist/${id}_songs.html').then(parseSongs).catchError((Object e) {
      _songs.remove(id);
      throw e;
    }));
    return [for (final s in all) if (!s.featured) s];
  }
}

class SpotifySong {
  const SpotifySong(this.title, this.streams, {this.featured = false});
  final String title;
  final int streams;
  final bool featured;
}
