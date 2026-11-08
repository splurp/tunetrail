import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Thin client for the free, key-less Deezer public API.
///
/// Deezer allows ~50 requests / 5 seconds per IP; requests are queued and
/// spaced out so crawling the catalog never trips the quota.
class DeezerApi {
  DeezerApi({http.Client? client}) : _client = client ?? http.Client();

  static const base = 'https://api.deezer.com';
  final http.Client _client;
  final Queue<Completer<void>> _waiters = Queue();
  final List<DateTime> _recent = [];
  bool _pumping = false;
  static const _maxPerWindow = 40;
  static const _window = Duration(seconds: 5);

  Future<void> _slot() {
    final c = Completer<void>();
    _waiters.add(c);
    _pump();
    return c.future;
  }

  void _pump() async {
    if (_pumping) return;
    _pumping = true;
    while (_waiters.isNotEmpty) {
      final now = DateTime.now();
      _recent.removeWhere((t) => now.difference(t) > _window);
      if (_recent.length >= _maxPerWindow) {
        await Future<void>.delayed(
            _window - now.difference(_recent.first) + const Duration(milliseconds: 20));
        continue;
      }
      _recent.add(now);
      _waiters.removeFirst().complete();
    }
    _pumping = false;
  }

  Future<Map<String, dynamic>> getJson(String path,
      {Map<String, String>? query, int retries = 3}) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    for (var attempt = 0;; attempt++) {
      await _slot();
      try {
        final res = await _client.get(uri).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) {
          throw DeezerException('HTTP ${res.statusCode}');
        }
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is Map<String, dynamic>) {
          final err = body['error'];
          if (err is Map) {
            // Code 4 = quota exceeded: back off and retry.
            if (err['code'] == 4 && attempt < retries) {
              await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
              continue;
            }
            throw DeezerException('${err['type']}: ${err['message']}');
          }
          return body;
        }
        throw DeezerException('Unexpected response');
      } on TimeoutException {
        if (attempt >= retries) rethrow;
      } on http.ClientException {
        if (attempt >= retries) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 + attempt));
      }
    }
  }

  List<Map<String, dynamic>> _data(Map<String, dynamic> j) =>
      [for (final x in (j['data'] as List? ?? const [])) x as Map<String, dynamic>];

  Future<List<Song>> chartTracks(int genreId, {int limit = 100}) async {
    final j = await getJson('/chart/$genreId/tracks', query: {'limit': '$limit'});
    return [
      for (final t in _data(j)) ?Song.fromDeezer(t, genreId: genreId)
    ];
  }

  Future<List<ArtistInfo>> genreArtists(int genreId) async {
    final j = await getJson('/genre/$genreId/artists');
    return [
      for (final a in _data(j))
        ArtistInfo(
          id: (a['id'] as num).toInt(),
          name: a['name'] as String? ?? '',
          picMd5: md5FromUrl(a['picture_small'] as String?),
          genreId: genreId,
        )
    ];
  }

  Future<ArtistInfo> artist(int id) async {
    final a = await getJson('/artist/$id');
    return ArtistInfo(
      id: (a['id'] as num).toInt(),
      name: a['name'] as String? ?? '',
      picMd5: md5FromUrl(a['picture_small'] as String?),
      fans: (a['nb_fan'] as num?)?.toInt() ?? 0,
      albumCount: (a['nb_album'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<Song>> artistTop(int id, {int limit = 30, int genreId = 0}) async {
    final j = await getJson('/artist/$id/top', query: {'limit': '$limit'});
    return [for (final t in _data(j)) ?Song.fromDeezer(t, genreId: genreId)];
  }

  Future<List<ArtistInfo>> related(int id, {int limit = 20}) async {
    final j = await getJson('/artist/$id/related', query: {'limit': '$limit'});
    return [
      for (final a in _data(j))
        ArtistInfo(
          id: (a['id'] as num).toInt(),
          name: a['name'] as String? ?? '',
          picMd5: md5FromUrl(a['picture_small'] as String?),
          fans: (a['nb_fan'] as num?)?.toInt() ?? 0,
        )
    ];
  }

  /// Full discography (albums, EPs and singles), newest first.
  Future<List<AlbumInfo>> artistAlbums(int id, String artistName) async {
    final out = <AlbumInfo>[];
    var index = 0;
    while (true) {
      final j = await getJson('/artist/$id/albums',
          query: {'limit': '100', 'index': '$index'});
      final page = _data(j);
      for (final a in page) {
        out.add(AlbumInfo(
          id: (a['id'] as num).toInt(),
          title: a['title'] as String? ?? '',
          coverMd5: a['md5_image'] as String? ?? md5FromUrl(a['cover_small'] as String?),
          artistId: id,
          artistName: artistName,
          releaseDate: a['release_date'] as String? ?? '',
          recordType: a['record_type'] as String? ?? 'album',
          genreId: (a['genre_id'] as num?)?.toInt() ?? 0,
          fans: (a['fans'] as num?)?.toInt() ?? 0,
        ));
      }
      final total = (j['total'] as num?)?.toInt() ?? out.length;
      index += page.length;
      if (page.isEmpty || index >= total || index >= 500) break;
    }
    return out;
  }

  /// Album with its tracks in official order.
  Future<(AlbumInfo, List<Song>)> album(int id) async {
    final a = await getJson('/album/$id');
    final artist = a['artist'] as Map<String, dynamic>? ?? const {};
    final md5 = a['md5_image'] as String? ?? md5FromUrl(a['cover_small'] as String?);
    final genreId = (a['genre_id'] as num?)?.toInt() ?? 0;
    final title = a['title'] as String? ?? '';
    final tracks = <Song>[
      for (final t in [
        for (final x in ((a['tracks'] as Map?)?['data'] as List? ?? const []))
          x as Map<String, dynamic>
      ])
        ?Song.fromDeezer(t,
            genreId: genreId, albumId: id, albumTitle: title, albumMd5: md5)
    ];
    final info = AlbumInfo(
      id: id,
      title: title,
      coverMd5: md5,
      artistId: (artist['id'] as num?)?.toInt() ?? 0,
      artistName: artist['name'] as String? ?? '',
      releaseDate: a['release_date'] as String? ?? '',
      recordType: a['record_type'] as String? ?? 'album',
      trackIds: [for (final t in tracks) t.id],
      genreId: genreId,
      fans: (a['fans'] as num?)?.toInt() ?? 0,
    );
    return (info, tracks);
  }

  /// Fresh 30-second preview URL (Deezer preview links expire).
  Future<String?> previewUrl(int trackId) async {
    final t = await getJson('/track/$trackId');
    final p = t['preview'] as String?;
    return (p == null || p.isEmpty) ? null : p;
  }

  Future<List<Song>> searchTracks(String q, {int limit = 50}) async {
    final j = await getJson('/search/track', query: {'q': q, 'limit': '$limit'});
    return [for (final t in _data(j)) ?Song.fromDeezer(t)];
  }

  Future<List<ArtistInfo>> searchArtists(String q, {int limit = 25}) async {
    final j = await getJson('/search/artist', query: {'q': q, 'limit': '$limit'});
    return [
      for (final a in _data(j))
        ArtistInfo(
          id: (a['id'] as num).toInt(),
          name: a['name'] as String? ?? '',
          picMd5: md5FromUrl(a['picture_small'] as String?),
          fans: (a['nb_fan'] as num?)?.toInt() ?? 0,
          albumCount: (a['nb_album'] as num?)?.toInt() ?? 0,
        )
    ];
  }
}

class DeezerException implements Exception {
  DeezerException(this.message);
  final String message;
  @override
  String toString() => 'Deezer: $message';
}
