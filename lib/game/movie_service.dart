import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/catalog.dart';
import '../data/models.dart';

/// A music-video clip for a Movie-edition card.
class MovieClip {
  const MovieClip(this.videoUrl, this.posterUrl);
  final String videoUrl;

  /// A still from the video (used for thumbnails and while loading).
  final String posterUrl;

  Map<String, dynamic> toJson() => {'v': videoUrl, 'p': posterUrl};
  static MovieClip fromJson(Map<String, dynamic> j) => MovieClip(j['v'] as String, j['p'] as String? ?? '');
}

/// Finds music-video previews for songs using Apple's free, keyless iTunes
/// Search API (`entity=musicVideo`), which returns ~30 s .m4v previews.
/// Results (including "no video") are cached on disk.
class MovieService extends ChangeNotifier {
  MovieService(this.dir);
  final Directory dir;
  final http.Client _client = http.Client();
  final Map<int, MovieClip?> _cache = {};
  final Map<int, Future<MovieClip?>> _pending = {};
  final Map<int, int> _noneAt = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _artistVideos = {};
  static const _noneTtl = Duration(days: 5);
  Timer? _save;

  File get _file => File('${dir.path}/movies.json');

  Future<void> load() async {
    // Older versions saved video files; video is streamed now.
    try {
      final old = Directory('${dir.path}/movies');
      if (await old.exists()) await old.delete(recursive: true);
    } catch (_) {}
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final now = DateTime.now().millisecondsSinceEpoch;
      j.forEach((k, v) {
        final id = int.parse(k);
        if (v is Map<String, dynamic> && v.containsKey('v')) {
          _cache[id] = MovieClip.fromJson(v);
        } else if (v is Map<String, dynamic> && (v['none'] as int? ?? 0) > now - _noneTtl.inMilliseconds) {
          // "No video" is only trusted for a while (and old bare-null
          // entries, from a weaker matcher, are looked up again).
          _cache[id] = null;
          _noneAt[id] = v['none'] as int;
        }
      });
    } catch (_) {}
  }

  void _scheduleSave() {
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), () async {
      try {
        await _file.writeAsString(jsonEncode({
          for (final e in _cache.entries) '${e.key}': e.value?.toJson() ?? {'none': _noneAt[e.key] ?? DateTime.now().millisecondsSinceEpoch},
        }));
      } catch (_) {}
    });
  }

  /// True/false once looked up; null while unknown.
  bool? hasMovie(int songId) => _cache.containsKey(songId) ? _cache[songId] != null : null;

  MovieClip? cached(int songId) => _cache[songId];

  Future<MovieClip?> clipFor(Song s) => _clip(s, false);

  // ---- Live Edition: footage of the song performed live. Cached under the
  // negative song id, in the same tables as music videos.

  /// True/false once looked up; null while unknown.
  bool? hasLive(int songId) => _cache.containsKey(-songId) ? _cache[-songId] != null : null;

  MovieClip? cachedLive(int songId) => _cache[-songId];

  Future<MovieClip?> liveClipFor(Song s) => _clip(s, true);

  /// Cache / file key: the song id for its music video, minus it for live.
  static int keyFor(int songId, {bool live = false}) => live ? -songId : songId;

  Future<MovieClip?> _clip(Song s, bool live) {
    final key = keyFor(s.id, live: live);
    if (_cache.containsKey(key)) return Future.value(_cache[key]);
    // (The callback must not return the removed future, or whenComplete
    // would wait on itself.)
    return _pending[key] ??= _lookup(s, live: live).whenComplete(() {
      _pending.remove(key);
    });
  }


  static bool _isAlt(String name) {
    final n = name.toLowerCase();
    return n.contains('lyric') || n.contains('visualizer') || n.contains('audio') || n.contains('live') || n.contains('behind the scenes') || n.contains('dance practice');
  }

  static bool _isLive(Map<String, dynamic> r) =>
      RegExp(r'\blive\b', caseSensitive: false).hasMatch('${r['trackName'] ?? ''}') ||
      RegExp(r'\blive (at|from|in|on)\b|\(live\)|unplugged', caseSensitive: false).hasMatch('${r['collectionName'] ?? ''}');

  /// The best music video in [results] for [s] (with [live]: only footage
  /// of a live performance), or null.
  static MovieClip? _match(Song s, List<Map<String, dynamic>> results, {bool live = false}) {
    final want = Catalog.normalizeTitle(s.title);
    final artist = s.artistName.toLowerCase();
    Map<String, dynamic>? best;
    var bestScore = -1;
    for (final r in results) {
      final url = r['previewUrl'] as String?;
      if (url == null || r['kind'] != 'music-video') continue;
      if (live && !_isLive(r)) continue;
      final name = r['trackName'] as String? ?? '';
      final title = Catalog.normalizeTitle(name);
      final a = (r['artistName'] as String? ?? '').toLowerCase();
      if (title != want || !(a.contains(artist) || artist.contains(a))) continue;
      final score = (_isAlt(name) ? 0 : 2) + (a == artist ? 1 : 0);
      if (score > bestScore) {
        best = r;
        bestScore = score;
      }
    }
    if (best == null) return null;
    final art = (best['artworkUrl100'] as String? ?? '').replaceAll('100x100bb', '600x600bb');
    return MovieClip(best['previewUrl'] as String, art);
  }

  Future<List<Map<String, dynamic>>> _get(Map<String, String> q, [String path = '/search']) async {
    final res = await _client.get(Uri.https('itunes.apple.com', path, q)).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw HttpException('iTunes ${res.statusCode}');
    return (jsonDecode(res.body)['results'] as List).cast<Map<String, dynamic>>();
  }

  /// Every music video of an artist — the keyword search misses many
  /// (e.g. KATSEYE's "Gnarly"), the artist's own video list doesn't.
  Future<List<Map<String, dynamic>>> _videosOf(String artist) => _artistVideos[artist.toLowerCase()] ??= () async {
        final found = await _get({'term': artist, 'entity': 'musicArtist', 'limit': '5'});
        final a = artist.toLowerCase();
        final hit = found.firstWhere((r) => (r['artistName'] as String? ?? '').toLowerCase() == a, orElse: () => found.isEmpty ? const <String, dynamic>{} : found.first);
        final id = hit['artistId'];
        if (id == null) return <Map<String, dynamic>>[];
        return _get({'id': '$id', 'entity': 'musicVideo', 'limit': '200'}, '/lookup');
      }();

  Future<MovieClip?> _lookup(Song s, {bool live = false}) async {
    MovieClip? clip;
    final key = keyFor(s.id, live: live);
    try {
      final term = '${s.artistName} ${Catalog.normalizeTitle(s.title)}${live ? ' live' : ''}';
      clip = _match(s, await _get({'term': term, 'entity': 'musicVideo', 'limit': '25'}), live: live);
      clip ??= _match(s, await _videosOf(s.artistName), live: live);
    } catch (e) {
      debugPrint('movie lookup: $e');
      _artistVideos.remove(s.artistName.toLowerCase());
      return null; // network error: try again later
    }
    _cache[key] = clip;
    if (clip == null) _noneAt[key] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
    notifyListeners();
    return clip;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
