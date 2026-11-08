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
  Timer? _save;

  File get _file => File('${dir.path}/movies.json');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      j.forEach((k, v) => _cache[int.parse(k)] = v == null ? null : MovieClip.fromJson(v as Map<String, dynamic>));
    } catch (_) {}
  }

  void _scheduleSave() {
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), () async {
      try {
        await _file.writeAsString(jsonEncode({for (final e in _cache.entries) '${e.key}': e.value?.toJson()}));
      } catch (_) {}
    });
  }

  /// True/false once looked up; null while unknown.
  bool? hasMovie(int songId) => _cache.containsKey(songId) ? _cache[songId] != null : null;

  MovieClip? cached(int songId) => _cache[songId];

  Future<MovieClip?> clipFor(Song s) {
    if (_cache.containsKey(s.id)) return Future.value(_cache[s.id]);
    // (The callback must not return the removed future, or whenComplete
    // would wait on itself.)
    return _pending[s.id] ??= _lookup(s).whenComplete(() {
      _pending.remove(s.id);
    });
  }

  final Map<int, Future<File?>> _downloads = {};

  /// Downloads (once) and caches a clip's video file locally, so playback
  /// doesn't depend on the player's own network stack.
  Future<File?> videoFile(int songId, MovieClip clip) => _downloads[songId] ??= () async {
        final d = Directory('${dir.path}/movies');
        final f = File('${d.path}/$songId.m4v');
        if (await f.exists() && await f.length() > 1000) return f;
        try {
          await d.create(recursive: true);
          final res = await _client.get(Uri.parse(clip.videoUrl)).timeout(const Duration(seconds: 40));
          if (res.statusCode != 200 && res.statusCode != 206) return null;
          final tmp = File('${f.path}.part');
          await tmp.writeAsBytes(res.bodyBytes, flush: true);
          await tmp.rename(f.path);
          return f;
        } catch (e) {
          debugPrint('movie download: $e');
          return null;
        } finally {
          // Allow a retry after a failure.
          Future<void>.delayed(const Duration(seconds: 1), () async {
            if (!await f.exists()) _downloads.remove(songId);
          });
        }
      }();

  Future<MovieClip?> _lookup(Song s) async {
    MovieClip? clip;
    try {
      final term = '${s.artistName} ${Catalog.normalizeTitle(s.title)}';
      final uri = Uri.https('itunes.apple.com', '/search', {'term': term, 'entity': 'musicVideo', 'limit': '10'});
      final res = await _client.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null; // transient: don't cache
      final results = (jsonDecode(res.body)['results'] as List).cast<Map<String, dynamic>>();
      final want = Catalog.normalizeTitle(s.title);
      final artist = s.artistName.toLowerCase();
      for (final r in results) {
        final url = r['previewUrl'] as String?;
        if (url == null) continue;
        final title = Catalog.normalizeTitle(r['trackName'] as String? ?? '');
        final a = (r['artistName'] as String? ?? '').toLowerCase();
        if (title != want || !(a.contains(artist) || artist.contains(a))) continue;
        final art = (r['artworkUrl100'] as String? ?? '').replaceAll('100x100bb', '600x600bb');
        clip = MovieClip(url, art);
        break;
      }
    } catch (e) {
      debugPrint('movie lookup: $e');
      return null; // network error: try again later
    }
    _cache[s.id] = clip;
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
