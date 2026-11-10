import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tunetrail_core/tunetrail_core.dart';

import 'store.dart';

/// The server's own song catalogue, crawled from Deezer like the game does,
/// so spawns, packs and rarities are decided by the server.
class ServerCatalog {
  ServerCatalog(this.store, {http.Client? client}) : _http = client ?? http.Client();
  final Store store;
  final http.Client _http;

  final Map<int, SongInfo> songs = {};
  final Map<int, int> fans = {};
  final Set<int> _crawledArtists = {};
  SongPool _pool = SongPool(const []);
  int _poolSize = -1;
  bool crawling = false;

  static const targetSongs = 60000;
  static const nonEnglishMinFans = 500000;
  static const relatedMinFans = 100000;

  int _poolAt = 0;

  /// The pool spawns and packs draw from. Rebuilding it (rarities for every
  /// song) takes a while, so while the catalogue grows it's rebuilt at most
  /// every two minutes, or when the catalogue has grown by a tenth.
  SongPool get pool {
    final n = songs.length;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_poolSize != n && (_poolSize <= 0 || now - _poolAt > 120000 || n > _poolSize * 1.1)) {
      _pool = SongPool(songs.values, fansOf: (a) => fans[a] ?? 0);
      _poolSize = n;
      _poolAt = now;
    }
    return _pool;
  }

  /// The pool including every song added so far (rebuilt now if needed):
  /// for songs that were only just added, such as a blind box's.
  SongPool get freshPool {
    if (_poolSize != songs.length) _poolSize = -1;
    return pool;
  }

  Rarity rarityOf(int songId) => pool.rarityOf(songId);

  Future<void> load() async {
    final (s, f) = await store.loadCatalog();
    for (final x in s) {
      songs[x.id] = x;
    }
    fans.addAll(f);
    _crawledArtists.addAll(f.keys);
    stdout.writeln('Catalogue: ${songs.length} songs, ${fans.length} artists');
  }

  int _lastCall = 0;

  /// Deezer allows ~50 requests per 5 s; stay well under.
  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? q]) async {
    final wait = 150 - (DateTime.now().millisecondsSinceEpoch - _lastCall);
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    _lastCall = DateTime.now().millisecondsSinceEpoch;
    final res = await _http.get(Uri.https('api.deezer.com', path, q)).timeout(const Duration(seconds: 15));
    final j = jsonDecode(res.body);
    if (j is! Map<String, dynamic> || j['error'] != null) throw StateError('Deezer: ${j is Map ? j['error'] : res.statusCode}');
    return j;
  }

  static List<Map<String, dynamic>> _data(Map<String, dynamic> j) => [for (final x in (j['data'] as List? ?? const [])) x as Map<String, dynamic>];

  static String _md5(String? url) => RegExp(r'/images/(?:artist|cover)/([0-9a-f]{32})/').firstMatch(url ?? '')?.group(1) ?? '';

  static SongInfo? _song(Map<String, dynamic> t, int genreId) {
    final id = (t['id'] as num?)?.toInt();
    if (id == null || id <= 0 || t['readable'] == false) return null;
    final artist = t['artist'] as Map<String, dynamic>? ?? const {};
    final album = t['album'] as Map<String, dynamic>? ?? const {};
    return SongInfo(
      id: id,
      title: (t['title'] as String?)?.isNotEmpty == true ? t['title'] as String : (t['title_short'] as String? ?? 'Unknown'),
      artistId: (artist['id'] as num?)?.toInt() ?? 0,
      artistName: artist['name'] as String? ?? 'Unknown Artist',
      albumId: (album['id'] as num?)?.toInt() ?? 0,
      albumTitle: album['title'] as String? ?? '',
      coverMd5: (t['md5_image'] as String?) ?? (album['md5_image'] as String?) ?? _md5(album['cover_small'] as String?),
      artistPicMd5: _md5(artist['picture_small'] as String?),
      genreId: genreId,
      rank: (t['rank'] as num?)?.toInt() ?? 0,
      duration: (t['duration'] as num?)?.toInt() ?? 0,
    );
  }

  final List<SongInfo> _pendingSongs = [];
  final Map<int, int> _pendingFans = {};

  void _add(Iterable<SongInfo> list) {
    for (final s in list) {
      final old = songs[s.id];
      // Keep the first real genre a song was found under.
      if (old != null && (old.genreId != 0 || s.genreId == 0)) continue;
      songs[s.id] = s;
      _pendingSongs.add(s);
    }
  }

  Future<void> _flush() async {
    if (_pendingSongs.isEmpty && _pendingFans.isEmpty) return;
    final s = List.of(_pendingSongs), f = Map.of(_pendingFans);
    _pendingSongs.clear();
    _pendingFans.clear();
    try {
      await store.saveCatalog(s, f);
    } catch (e) {
      stderr.writeln('catalogue save failed: $e');
    }
  }

  /// The genre Deezer gives an album, if it's one of the world's genres.
  Future<int?> _albumGenre(int albumId) async {
    if (albumId <= 0) return null;
    final g = ((await _get('/album/$albumId'))['genre_id'] as num?)?.toInt();
    return g != null && g > 0 && kWorldGenres.any((x) => x.id == g) ? g : null;
  }

  /// [guessGenre]: [genreId] is only a guess (an artist found through a
  /// related artist, or a favourite) — use their top album's genre.
  Future<void> _artist(int id, int genreId, {int knownFans = 0, bool nonEnglish = false, bool guessGenre = false}) async {
    if (!_crawledArtists.add(id)) return;
    try {
      var f = knownFans;
      if (f == 0) f = ((await _get('/artist/$id'))['nb_fan'] as num?)?.toInt() ?? 0;
      fans[id] = f;
      _pendingFans[id] = f;
      if (nonEnglish && f < nonEnglishMinFans) return;
      final top = _data(await _get('/artist/$id/top', {'limit': '30'}));
      if ((guessGenre || genreId == 0) && top.isNotEmpty) {
        final album = ((top.first['album'] as Map<String, dynamic>?)?['id'] as num?)?.toInt() ?? 0;
        genreId = await _albumGenre(album) ?? genreId;
      }
      _add([for (final t in top) ?_song(t, genreId)]);
    } catch (e) {
      stderr.writeln('crawl artist $id: $e');
    }
  }

  /// Makes sure favourite artists' songs are in the catalogue (they spawn
  /// more often for the players who follow them).
  Future<void> ensureArtists(Iterable<int> ids) async {
    var added = false;
    for (final id in ids) {
      if (_crawledArtists.contains(id)) continue;
      await _artist(id, 0);
      added = true;
    }
    if (added) await _flush();
  }

  /// An artist's name, Deezer fans and top songs (up to 100), for blind
  /// boxes. The songs join the catalogue.
  Future<({String name, int fans, List<SongInfo> songs})> artistTop(int id) async {
    final a = await _get('/artist/$id');
    final f = (a['nb_fan'] as num?)?.toInt() ?? 0;
    fans[id] = f;
    _pendingFans[id] = f;
    final known = songs.values.firstWhere((s) => s.artistId == id && s.genreId != 0, orElse: () => const SongInfo(id: 0, title: '', artistId: 0, artistName: '')).genreId;
    final list = [for (final t in _data(await _get('/artist/$id/top', {'limit': '100'}))) ?_song(t, known)];
    _add(list);
    _crawledArtists.add(id);
    await _flush();
    return (name: a['name'] as String? ?? 'Unknown Artist', fans: f, songs: [for (final s in list) songs[s.id] ?? s]);
  }

  /// An album's details and tracks (for album quests).
  Future<({String title, String recordType, String coverMd5, List<SongInfo> tracks})> album(int id) async {
    final a = await _get('/album/$id');
    final genre = (a['genre_id'] as num?)?.toInt() ?? 0;
    final cover = (a['md5_image'] as String?) ?? _md5(a['cover_small'] as String?);
    final tracks = <SongInfo>[];
    for (final t in _data(a['tracks'] as Map<String, dynamic>? ?? const {})) {
      final s = _song({
        ...t,
        'album': {'id': id, 'title': a['title'], 'md5_image': cover},
      }, genre < 0 ? 0 : genre);
      if (s != null) tracks.add(s);
    }
    return (title: a['title'] as String? ?? '', recordType: a['record_type'] as String? ?? 'album', coverMd5: cover, tracks: tracks);
  }

  /// Corrects the genre of artists already in the catalogue: artists found
  /// through related artists used to inherit the genre of the artist they
  /// were found from (Coldplay as Hip Hop). Each artist's songs take the
  /// genre of their top song's album. Runs in the background, once per
  /// artist (remembered across restarts).
  Future<void> fixGenres() async {
    final checked = <int>{for (final x in (await store.loadBlob('genreChecked') as List? ?? const [])) (x as num).toInt()};
    final byArtist = <int, List<SongInfo>>{};
    for (final s in songs.values) {
      byArtist.putIfAbsent(s.artistId, () => []).add(s);
    }
    var fixed = 0, done = 0;
    for (final e in byArtist.entries) {
      if (checked.contains(e.key) || e.key == 0) continue;
      try {
        final top = (List.of(e.value)..sort((a, b) => b.rank.compareTo(a.rank))).first;
        final g = await _albumGenre(top.albumId);
        if (g != null) {
          final wrong = [
            for (final s in e.value)
              if (s.genreId != g) s,
          ];
          for (final s in wrong) {
            final t = SongInfo.fromJson({...s.toJson(), 'g': g});
            songs[s.id] = t;
            _pendingSongs.add(t);
          }
          if (wrong.isNotEmpty) fixed++;
        }
        checked.add(e.key);
      } catch (_) {
        continue;
      }
      if (++done % 100 == 0) {
        await _flush();
        await store.saveBlob('genreChecked', checked.toList());
      }
    }
    await _flush();
    await store.saveBlob('genreChecked', checked.toList());
    _poolSize = -1;
    if (done > 0) stdout.writeln('Genres checked for $done artists; corrected $fixed');
  }

  /// Grows the catalogue in the background (charts, then each genre's
  /// popular artists, then related artists). Safe to call repeatedly.
  Future<void> crawl({bool chartsOnly = false}) async {
    if (crawling) return;
    crawling = true;
    try {
      for (final g in kWorldGenres) {
        try {
          _add([for (final t in _data(await _get('/chart/${g.id}/tracks', {'limit': '100'}))) ?_song(t, g.id)]);
        } catch (e) {
          stderr.writeln('chart ${g.id}: $e');
        }
      }
      await _flush();
      if (chartsOnly) return;
      for (final g in kWorldGenres.where((g) => g.id != 0)) {
        if (songs.length >= targetSongs) break;
        List<Map<String, dynamic>> list;
        try {
          list = _data(await _get('/genre/${g.id}/artists'));
        } catch (_) {
          continue;
        }
        for (final a in list) {
          if (songs.length >= targetSongs) break;
          await _artist((a['id'] as num).toInt(), g.id, nonEnglish: g.nonEnglish);
        }
        await _flush();
      }
      final seeds = fans.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final seed in seeds.take(150)) {
        if (songs.length >= targetSongs) break;
        final genre = songs.values.firstWhere((s) => s.artistId == seed.key, orElse: () => const SongInfo(id: 0, title: '', artistId: 0, artistName: '')).genreId;
        final g = kWorldGenres.firstWhere((x) => x.id == genre, orElse: () => kWorldGenres[1]);
        try {
          for (final r in _data(await _get('/artist/${seed.key}/related', {'limit': '20'}))) {
            final f = (r['nb_fan'] as num?)?.toInt() ?? 0;
            if (f < (g.nonEnglish ? nonEnglishMinFans : relatedMinFans)) continue;
            await _artist((r['id'] as num).toInt(), g.id, knownFans: f, guessGenre: true);
          }
        } catch (_) {}
        await _flush();
      }
      stdout.writeln('Catalogue crawl done: ${songs.length} songs');
    } finally {
      await _flush();
      crawling = false;
    }
  }
}

/// Songs that can appear as Sample editions (the game's sample library).
const kSampleSongs = [
  SongInfo(
    id: 630827252,
    title: 'I Wonder',
    artistId: 230,
    artistName: 'Kanye West',
    albumId: 86994002,
    albumTitle: 'Graduation',
    coverMd5: '8c6578a2099561992fb7544e6826f767',
    genreId: 116,
    rank: 763200,
    duration: 243,
  ),
];
