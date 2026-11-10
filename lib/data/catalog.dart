import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:tunetrail_core/tunetrail_core.dart';

import 'deezer_api.dart';
import 'models.dart';

/// The local song catalog: every song the game knows about.
///
/// Built progressively from the Deezer API (genre charts, then each genre's
/// most popular artists' top tracks, then related artists) and persisted as
/// an append-only JSON-lines file so it loads in milliseconds next launch.
class Catalog extends ChangeNotifier {
  Catalog(this.api, this.dir) {
    artistGenreLookup = artistGenre;
  }

  final DeezerApi api;
  final Directory dir;

  final Map<int, Song> songs = {};
  final Map<int, ArtistInfo> artists = {};
  final Map<int, List<int>> _genrePools = {};
  final Set<int> _crawledArtists = {};
  final Map<int, AlbumInfo> _albumCache = {};
  final Map<int, List<AlbumInfo>> _discographyCache = {};

  /// Deezer fan threshold for non-English artists (popular-only).
  static const nonEnglishMinFans = 500000;

  /// Fan threshold for artists discovered through "related artists".
  static const relatedMinFans = 100000;

  bool crawling = false;
  String crawlStatus = '';
  int version = 0;
  IOSink? _sink;
  File get _file => File('${dir.path}/catalog.jsonl');

  // ------------------------------------------------------------- loading
  Future<void> load() async {
    if (await _file.exists()) {
      final text = await _file.readAsString();
      final parsed = await compute(_parseCatalog, text);
      for (final s in parsed.songs) {
        songs[s.id] = s;
      }
      for (final a in parsed.artists) {
        artists[a.id] = a;
      }
      _crawledArtists.addAll(parsed.crawled);
      _playsDone.addAll(parsed.playsDone);
      _rebuildPools();
    }
    _sink = _file.openWrite(mode: FileMode.append);
    version++;
    notifyListeners();
  }

  void _rebuildPools() {
    _genrePools.clear();
    final ids = songs.keys.toList()..sort();
    for (final id in ids) {
      final s = songs[id]!;
      _genrePools.putIfAbsent(s.genreId, () => []).add(id);
    }
  }

  void _write(Map<String, dynamic> line) {
    _sink?.writeln(jsonEncode(line));
  }

  /// Adds or updates songs; returns how many were new.
  int addSongs(Iterable<Song> list) {
    var added = 0;
    for (final s in list) {
      final existing = songs[s.id];
      if (existing != null) {
        // Keep the first genre a song was discovered under (stable pools).
        if (existing.coverMd5.isNotEmpty || s.coverMd5.isEmpty) continue;
      }
      final song = existing != null && existing.genreId != 0 && s.genreId != existing.genreId
          ? Song(
              id: s.id,
              title: s.title,
              artistId: s.artistId,
              artistName: s.artistName,
              albumId: s.albumId,
              albumTitle: s.albumTitle,
              coverMd5: s.coverMd5,
              artistPicMd5: s.artistPicMd5,
              genreId: existing.genreId,
              rank: s.rank,
              duration: s.duration)
          : s;
      songs[s.id] = song;
      if (song.genreId != 0) _artistSongGenre.putIfAbsent(song.artistId, () => song.genreId);
      if (existing == null) {
        _genrePools.putIfAbsent(song.genreId, () => []).add(song.id);
        added++;
      }
      _write({'s': song.toJson()});
    }
    if (added > 0) {
      version++;
      notifyListeners();
    }
    return added;
  }

  /// An artist's genre: from the artist, else the genre most of their
  /// known songs were found under (0 when unknown).
  int artistGenre(int artistId) {
    final a = artists[artistId];
    if (a != null && a.genreId != 0) return a.genreId;
    return _artistSongGenre[artistId] ?? 0;
  }

  final Map<int, int> _artistSongGenre = {};

  void addArtist(ArtistInfo a) {
    final existing = artists[a.id];
    if (existing != null) {
      if (a.fans > 0) existing.fans = a.fans;
      if (a.picMd5.isNotEmpty) existing.picMd5 = a.picMd5;
      if (a.albumCount > 0) existing.albumCount = a.albumCount;
      if (a.genreId != 0 && existing.genreId == 0) existing.genreId = a.genreId;
      _write({'a': existing.toJson()});
      return;
    }
    artists[a.id] = a;
    _write({'a': a.toJson()});
  }

  /// Takes the genre the server gives a song (the server corrects genres
  /// it had wrong; songs found through related artists used to inherit the
  /// genre of the artist they were found from).
  void adoptGenre(int songId, int genreId) {
    final s = songs[songId];
    if (s == null || genreId == 0 || s.genreId == genreId) return;
    _genrePools[s.genreId]?.remove(songId);
    final t = Song(
      id: s.id,
      title: s.title,
      artistId: s.artistId,
      artistName: s.artistName,
      albumId: s.albumId,
      albumTitle: s.albumTitle,
      coverMd5: s.coverMd5,
      artistPicMd5: s.artistPicMd5,
      genreId: genreId,
      rank: s.rank,
      duration: s.duration,
      plays: s.plays,
    );
    songs[songId] = t;
    _genrePools.putIfAbsent(genreId, () => []).add(songId);
    _artistSongGenre[s.artistId] = genreId;
    _write({'s': t.toJson()});
    version++;
  }

  /// The genre Deezer gives an artist's top album (null if unknown or not
  /// one of the game's genres).
  Future<int?> _topAlbumGenre(int artistId) async {
    try {
      final top = await api.artistTop(artistId, limit: 1);
      if (top.isEmpty || top.first.albumId <= 0) return null;
      final j = await api.getJson('/album/${top.first.albumId}');
      final g = (j['genre_id'] as num?)?.toInt();
      return g != null && kGenres.any((x) => x.id == g && x.id != 0) ? g : null;
    } catch (_) {
      return null;
    }
  }

  void ensureFromPayload(CardPayload c) {
    if (!songs.containsKey(c.songId)) addSongs([Song.fromPayload(c)]);
  }

  // -------------------------------------------------------------- picking
  int get size => songs.length;
  List<int> poolFor(int genreId) => _genrePools[genreId] ?? const [];
  Iterable<int> get genresWithSongs =>
      _genrePools.entries.where((e) => e.value.isNotEmpty).map((e) => e.key);

  // --------------------------------------------------------------- rarity
  int _rarityVersion = -1;
  final Map<int, Rarity> _rarityCache = {};

  /// genre → rarity index → song ids (sorted, deterministic).
  final Map<int, List<List<int>>> _rarityPools = {};

  /// Popularity of a song for ranking: Last.fm plays when the artist has
  /// play data, otherwise Deezer rank.
  static double _pop(Song s, bool usePlays) => usePlays ? s.plays.toDouble() : s.rank.toDouble();

  void _ensureRarity() {
    if (_rarityVersion == version) return;
    final byArtist = <int, List<Song>>{};
    for (final s in songs.values) {
      byArtist.putIfAbsent(s.artistId, () => []).add(s);
    }
    _rarityCache.clear();
    for (final list in byArtist.values) {
      final usePlays = list.any((s) => s.plays > 0);
      list.sort((a, b) => _pop(a, usePlays).compareTo(_pop(b, usePlays)));
      final tier = artistTier(
        maxPlays: usePlays ? list.last.plays : 0,
        maxRank: list.fold<int>(0, (m, s) => s.rank > m ? s.rank : m),
        fans: artists[list.first.artistId]?.fans ?? 0,
      );
      final n = list.length;
      final top = _pop(list.last, usePlays);
      for (var i = 0; i < n; i++) {
        final s = list[i];
        // Position among the artist's songs (0 = least played, 1 = most),
        // blended with share of the top song so near-ties stay together.
        final position = n == 1 ? 0.5 : i / (n - 1);
        final share = top <= 0 ? position : math.sqrt((_pop(s, usePlays) / top).clamp(0.0, 1.0));
        _rarityCache[s.id] = rarityFor(tier, 0.65 * position + 0.35 * share);
      }
    }
    _rarityPools.clear();
    final ids = songs.keys.toList()..sort();
    for (final id in ids) {
      final s = songs[id]!;
      _rarityPools.putIfAbsent(s.genreId, () => List.generate(5, (_) => <int>[]))[_rarityCache[id]!.index].add(id);
    }
    _rarityVersion = version;
  }

  /// How big an artist is, 0 (tiny) … 1 (superstar).
  ///
  /// Uses Last.fm play counts of their biggest song when available
  /// (≈50k plays → 0, ≈30M plays → 1), otherwise Deezer fans and track
  /// popularity rank.
  static double artistTier({int maxPlays = 0, int maxRank = 0, int fans = 0}) {
    if (maxPlays > 0) return ((math.log(maxPlays) / math.ln10 - 4.7) / 2.8).clamp(0.0, 1.0);
    final byRank = ((maxRank - 350000) / 550000).clamp(0.0, 1.0);
    final byFans = fans > 0 ? ((math.log(fans) / math.ln10 - 4.0) / 2.7).clamp(0.0, 1.0) : 0.0;
    return math.max(byRank, byFans);
  }

  /// Rarity from artist tier and the song's standing within the artist's
  /// catalogue (0 = least played … 1 = most played).
  ///
  ///  * Tiny artists span Common → Rare (their best songs are Rare).
  ///  * Superstars are mostly Epic/Legendary; only their least-played songs
  ///    (deep cuts, remixes, edits) drop to Rare.
  static Rarity rarityFor(double tier, double standing) {
    final score = 0.5 * tier + 0.5 * standing.clamp(0.0, 1.0);
    if (score >= 0.75) return Rarity.legendary;
    if (score >= 0.56) return Rarity.epic;
    if (score >= 0.37) return Rarity.rare;
    if (score >= 0.2) return Rarity.uncommon;
    return Rarity.common;
  }

  Rarity rarityOf(Song s) {
    _ensureRarity();
    return _rarityCache[s.id] ?? rarityFor(artistTier(maxRank: s.rank), 0.5);
  }

  // ------------------------------------------------------ favourites
  /// Artist ids whose songs spawn 10× more often for this player.
  Set<int> favoriteArtists = {};
  static const favoriteBoost = 10.0;
  int _favVersion = -1;
  Set<int> _favKey = {};

  /// genre → rarity → favourite-artist song ids within that pool.
  final Map<int, List<List<int>>> _favPools = {};

  /// favourite artist → rarity → their song ids.
  final Map<int, List<List<int>>> _favByArtist = {};

  void _ensureFavorites() {
    _ensureRarity();
    if (_favVersion == version && _favKey.length == favoriteArtists.length && _favKey.containsAll(favoriteArtists)) return;
    _favPools.clear();
    _favByArtist.clear();
    for (final e in _rarityPools.entries) {
      _favPools[e.key] = [
        for (final pool in e.value) [for (final id in pool) if (favoriteArtists.contains(songs[id]!.artistId)) id]
      ];
      for (var k = 0; k < 5; k++) {
        for (final id in _favPools[e.key]![k]) {
          (_favByArtist[songs[id]!.artistId] ??= List.generate(5, (_) => <int>[]))[k].add(id);
        }
      }
    }
    _favVersion = version;
    _favKey = {...favoriteArtists};
  }

  /// Makes a spawn [favoriteBoost]× as likely as normal to be by *one of*
  /// the player's favourite artists (however many they have — the boost is
  /// for the list as a whole, not per artist). The normal chance is
  /// computed exactly from how a spawn picks a genre (weighted by [bias])
  /// and then a song of the rolled rarity. When the boost fires, one
  /// favourite artist is picked uniformly at random and one of their songs
  /// nearest the rolled rarity is returned; otherwise null (normal pick).
  Song? maybeFavorite(Rng rng, Rarity rarity, {Map<int, double> bias = const {}}) {
    if (favoriteArtists.isEmpty) return null;
    _ensureFavorites();
    if (_favByArtist.isEmpty) return null;
    final r = rarity.index;
    final available = [for (final g in kGenres) if (poolFor(g.id).isNotEmpty) g];
    final totalW = available.fold<double>(0, (a, g) => a + g.weight * (bias[g.id] ?? 1.0));
    if (totalW <= 0) return null;
    var f = 0.0; // normal probability that this spawn is a favourite's song
    for (final g in available) {
      // Same nearest-rarity fallback as [pickSong] when a pool is empty.
      final k = _nearestPool(g.id, r);
      if (k == null) continue;
      final favs = _favPools[g.id]?[k] ?? const [];
      if (favs.isEmpty) continue;
      f += g.weight * (bias[g.id] ?? 1.0) / totalW * favs.length / _rarityPools[g.id]![k].length;
    }
    // Even favourites with no song at this rarity get a (fallback) chance.
    f = math.max(f, 1e-4);
    if (f >= 1) return null;
    final target = favoriteBoost * f / (1 + (favoriteBoost - 1) * f);
    // The normal pick can still land on a favourite (probability f), so only
    // the difference needs to be forced here.
    final q = ((target - f) / (1 - f)).clamp(0.0, 1.0);
    if (rng.nextDouble() >= q) return null;
    final artists = _favByArtist.keys.toList();
    final pools = _favByArtist[artists[rng.nextInt(artists.length)]]!;
    for (var d = 0; d < 5; d++) {
      for (final k in d == 0 ? [r] : [r - d, r + d]) {
        if (k >= 0 && k < 5 && pools[k].isNotEmpty) return songs[pools[k][rng.nextInt(pools[k].length)]];
      }
    }
    return null;
  }

  /// Index of the pool [pickSong] would use for rarity [r] in a genre.
  int? _nearestPool(int genre, int r) {
    final pools = _rarityPools[genre];
    if (pools == null) return null;
    for (var d = 0; d < 5; d++) {
      for (final k in d == 0 ? [r] : [r - d, r + d]) {
        if (k >= 0 && k < 5 && pools[k].isNotEmpty) return k;
      }
    }
    return null;
  }

  /// Number of known songs per rarity in a genre (for UI/odds).
  int countAt(int genreId, Rarity r) {
    _ensureRarity();
    return _rarityPools[genreId]?[r.index].length ?? 0;
  }

  /// Deterministically picks a song for a spawn/pack. With [rarity], picks
  /// a song whose own rarity matches (or the closest available rarity).
  Song? pickSong(Rng rng, {int? genreId, Rarity? rarity}) {
    if (songs.isEmpty) return null;
    var g = genreId ?? _pickGenre(rng);
    if (rarity != null) {
      _ensureRarity();
      List<int>? pickFrom(int genre) {
        final pools = _rarityPools[genre];
        if (pools == null) return null;
        final r = rarity.index;
        for (var d = 0; d < 5; d++) {
          for (final k in d == 0 ? [r] : [r - d, r + d]) {
            if (k >= 0 && k < 5 && pools[k].isNotEmpty) return pools[k];
          }
        }
        return null;
      }

      var pool = pickFrom(g) ?? pickFrom(_pickGenre(rng));
      if (pool == null) {
        final any = genresWithSongs.toList()..sort();
        if (any.isEmpty) return null;
        pool = pickFrom(any[rng.nextInt(any.length)]);
      }
      if (pool == null || pool.isEmpty) return null;
      return songs[pool[rng.nextInt(pool.length)]];
    }
    var pool = poolFor(g);
    if (pool.isEmpty) {
      g = _pickGenre(rng);
      pool = poolFor(g);
    }
    if (pool.isEmpty) {
      final any = genresWithSongs.toList()..sort();
      if (any.isEmpty) return null;
      pool = poolFor(any[rng.nextInt(any.length)]);
    }
    return songs[pool[rng.nextInt(pool.length)]];
  }

  int _pickGenre(Rng rng) {
    final available = [for (final g in kGenres) if (poolFor(g.id).isNotEmpty) g];
    if (available.isEmpty) return 0;
    final total = available.fold<int>(0, (a, g) => a + g.weight);
    var roll = rng.nextInt(total);
    for (final g in available) {
      roll -= g.weight;
      if (roll < 0) return g.id;
    }
    return available.last.id;
  }

  /// Weighted genre roll exposed for spawns (time of day can bias it).
  int pickGenre(Rng rng, {Map<int, double> bias = const {}}) {
    final available = [for (final g in kGenres) if (poolFor(g.id).isNotEmpty) g];
    if (available.isEmpty) return 0;
    final weights = [for (final g in available) g.weight * (bias[g.id] ?? 1.0)];
    final total = weights.fold<double>(0, (a, b) => a + b);
    var roll = rng.nextDouble() * total;
    for (var i = 0; i < available.length; i++) {
      roll -= weights[i];
      if (roll < 0) return available[i].id;
    }
    return available.last.id;
  }

  // ------------------------------------------------------------- crawling
  /// Grows the catalog in the background. Safe to call repeatedly.
  Future<void> crawl({int targetSongs = 60000}) async {
    if (crawling) return;
    crawling = true;
    try {
      // Phase 1: genre charts (fast, gives an immediately playable pool).
      if (songs.length < 500) {
        for (final g in kGenres) {
          crawlStatus = 'Loading ${g.name} charts…';
          notifyListeners();
          try {
            addSongs(await api.chartTracks(g.id));
          } catch (e) {
            debugPrint('chart ${g.id} failed: $e');
          }
        }
      }
      // Phase 2: popular artists in each genre → their top tracks.
      for (final g in kGenres.where((g) => g.id != 0)) {
        if (songs.length >= targetSongs) break;
        List<ArtistInfo> list;
        try {
          list = await api.genreArtists(g.id);
        } catch (_) {
          continue;
        }
        for (final a in list) {
          if (songs.length >= targetSongs) break;
          if (_crawledArtists.contains(a.id)) continue;
          crawlStatus = 'Discovering ${a.name}…';
          notifyListeners();
          await _crawlArtist(a, g);
        }
      }
      // Phase 3: related artists of what we already know.
      final seeds = artists.values.toList()..sort((a, b) => b.fans.compareTo(a.fans));
      for (final seed in seeds.take(150)) {
        if (songs.length >= targetSongs) break;
        try {
          for (final r in await api.related(seed.id)) {
            if (_crawledArtists.contains(r.id)) continue;
            var genre = kGenres.firstWhere((g) => g.id == seed.genreId, orElse: () => kGenres.first);
            final minFans = genre.nonEnglish ? nonEnglishMinFans : relatedMinFans;
            if (r.fans < minFans) continue;
            // A related artist's own genre (their top album's), not the
            // genre of the artist they were found from.
            final own = await _topAlbumGenre(r.id);
            if (own != null) genre = kGenres.firstWhere((g) => g.id == own);
            r.genreId = genre.id;
            crawlStatus = 'Discovering ${r.name}…';
            notifyListeners();
            await _crawlArtist(r, genre, fansKnown: true);
          }
        } catch (_) {}
      }
      crawlStatus = '';
      unawaited(backfillPlays());
    } finally {
      crawling = false;
      await _sink?.flush();
      notifyListeners();
    }
  }

  Future<void> _crawlArtist(ArtistInfo a, GenreDef g, {bool fansKnown = false}) async {
    try {
      if (g.nonEnglish && !fansKnown) {
        final full = await api.artist(a.id);
        a.fans = full.fans;
        a.albumCount = full.albumCount;
        if (a.fans < nonEnglishMinFans) {
          _crawledArtists.add(a.id);
          _write({'c': a.id});
          return;
        }
      }
      a.genreId = g.id;
      addArtist(a);
      addSongs(await api.artistTop(a.id, limit: 30, genreId: g.id));
      _crawledArtists.add(a.id);
      _write({'c': a.id});
    } catch (e) {
      debugPrint('artist ${a.id} failed: $e');
    }
  }

  // ------------------------------------------------------ Last.fm plays
  /// Optional Last.fm API key. When set, songs get all-time play counts
  /// (a much better stream-count signal than Deezer rank) for rarity.
  String lastFmKey = '';
  final Set<int> _playsDone = {};
  final http.Client _lfClient = http.Client();
  bool _backfilling = false;

  static String normalizeTitle(String t) {
    var x = t.toLowerCase();
    x = x.replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), ' ');
    x = x.split(' - ').first;
    x = x.replaceAll(RegExp(r'\b(feat|ft|featuring)\b.*'), ' ');
    return x.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  /// Fetches Last.fm play counts for one artist's songs. Songs Last.fm
  /// doesn't know (often remixes/edits) keep 0 plays and rank lowest.
  Future<bool> fetchPlays(int artistId) async {
    if (lastFmKey.isEmpty || _playsDone.contains(artistId)) return false;
    final list = songs.values.where((s) => s.artistId == artistId).toList();
    if (list.isEmpty) return false;
    final uri = Uri.https('ws.audioscrobbler.com', '/2.0/', {
      'method': 'artist.gettoptracks',
      'artist': list.first.artistName,
      'api_key': lastFmKey,
      'format': 'json',
      'limit': '1000',
      'autocorrect': '1',
    });
    final res = await _lfClient.get(uri, headers: {'User-Agent': 'Tunetrail/0.3'}).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw StateError('Last.fm HTTP ${res.statusCode}');
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (j['error'] != null) throw StateError('Last.fm: ${j['message']}');
    final plays = <String, int>{};
    for (final t in ((j['toptracks'] as Map?)?['track'] as List? ?? const [])) {
      final m = t as Map<String, dynamic>;
      final k = normalizeTitle(m['name'] as String? ?? '');
      final pc = int.tryParse('${m['playcount']}') ?? 0;
      if (k.isNotEmpty && pc > (plays[k] ?? 0)) plays[k] = pc;
    }
    var changed = false;
    for (final s in list) {
      final pc = plays[normalizeTitle(s.title)] ?? 0;
      if (pc > 0 && pc != s.plays) {
        final u = s.withPlays(pc);
        songs[s.id] = u;
        _write({'s': u.toJson()});
        changed = true;
      }
    }
    _playsDone.add(artistId);
    _write({'lf': artistId});
    if (changed) {
      version++;
      notifyListeners();
    }
    return changed;
  }

  /// Fills in play counts for every artist in the catalogue (≈4 req/s).
  Future<void> backfillPlays() async {
    if (lastFmKey.isEmpty || _backfilling) return;
    _backfilling = true;
    try {
      final counts = <int, int>{};
      for (final s in songs.values) {
        counts[s.artistId] = (counts[s.artistId] ?? 0) + 1;
      }
      final order = counts.keys.where((a) => !_playsDone.contains(a)).toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
      for (final a in order) {
        if (lastFmKey.isEmpty) break;
        try {
          await fetchPlays(a);
        } catch (e) {
          debugPrint('last.fm $a: $e');
          if ('$e'.contains('Invalid API key')) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 260));
      }
    } finally {
      _backfilling = false;
    }
  }

  // ------------------------------------------------------- detail lookups
  Future<ArtistInfo> artistDetails(int id) async {
    final full = await api.artist(id);
    addArtist(full);
    return artists[id]!;
  }

  Future<List<AlbumInfo>> discography(int artistId, String name) async {
    final cached = _discographyCache[artistId];
    if (cached != null) return cached;
    final list = await api.artistAlbums(artistId, name);
    _discographyCache[artistId] = list;
    return list;
  }

  Future<AlbumInfo> albumDetails(int albumId) async {
    final cached = _albumCache[albumId];
    if (cached != null && cached.trackIds.isNotEmpty) return cached;
    final (info, tracks) = await api.album(albumId);
    final artistGenre = artists[info.artistId]?.genreId ?? 0;
    addSongs([
      for (final t in tracks)
        Song(
            id: t.id,
            title: t.title,
            artistId: t.artistId,
            artistName: t.artistName,
            albumId: t.albumId,
            albumTitle: t.albumTitle,
            coverMd5: t.coverMd5,
            artistPicMd5: t.artistPicMd5,
            genreId: artistGenre != 0 ? artistGenre : _mapGenre(info.genreId),
            rank: t.rank,
            duration: t.duration)
    ]);
    _albumCache[albumId] = info;
    return info;
  }

  Future<List<Song>> topTracks(int artistId) async {
    final g = artists[artistId]?.genreId ?? 0;
    final list = await api.artistTop(artistId, limit: 50, genreId: g);
    addSongs(list);
    return [for (final s in list) songs[s.id] ?? s];
  }

  int _mapGenre(int deezerGenre) =>
      kGenres.any((g) => g.id == deezerGenre) ? deezerGenre : 0;

  Future<void> flush() async => _sink?.flush();

  /// Flushes and closes the catalogue file (await before deleting its
  /// folder, e.g. in tests).
  Future<void> close() async {
    final s = _sink;
    _sink = null;
    await s?.flush();
    await s?.close();
  }

  @override
  void dispose() {
    _sink?.close();
    super.dispose();
  }

  // ---------------------------------------------------- sort-key indexes
  int _titleRankVersion = -1;
  Map<int, int> _titleRank = {};
  Map<int, int> _artistRank = {};

  /// Precomputed alphabetical ranks so the collection can sort 100k+ cards
  /// with integer comparisons instead of string comparisons.
  (Map<int, int>, Map<int, int>) sortRanks() {
    if (_titleRankVersion == version) return (_titleRank, _artistRank);
    final ids = songs.keys.toList();
    final lowerTitle = {for (final id in ids) id: songs[id]!.title.toLowerCase()};
    ids.sort((a, b) => lowerTitle[a]!.compareTo(lowerTitle[b]!));
    _titleRank = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final artistNames = <int, String>{};
    for (final s in songs.values) {
      artistNames[s.artistId] = s.artistName.toLowerCase();
    }
    final artistIds = artistNames.keys.toList()
      ..sort((a, b) => artistNames[a]!.compareTo(artistNames[b]!));
    _artistRank = {for (var i = 0; i < artistIds.length; i++) artistIds[i]: i};
    _titleRankVersion = version;
    return (_titleRank, _artistRank);
  }
}

class _ParsedCatalog {
  _ParsedCatalog(this.songs, this.artists, this.crawled, this.playsDone);
  final List<int> playsDone;
  final List<Song> songs;
  final List<ArtistInfo> artists;
  final List<int> crawled;
}

_ParsedCatalog _parseCatalog(String text) {
  final songs = <int, Song>{};
  final artists = <int, ArtistInfo>{};
  final crawled = <int>[];
  final playsDone = <int>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['s'] != null) {
        final s = Song.fromJson(j['s'] as Map<String, dynamic>);
        songs[s.id] = s;
      } else if (j['a'] != null) {
        final a = ArtistInfo.fromJson(j['a'] as Map<String, dynamic>);
        artists[a.id] = a;
      } else if (j['c'] != null) {
        crawled.add((j['c'] as num).toInt());
      } else if (j['lf'] != null) {
        playsDone.add((j['lf'] as num).toInt());
      }
    } catch (_) {
      // Ignore a torn final line from an interrupted write.
    }
  }
  return _ParsedCatalog(songs.values.toList(), artists.values.toList(), crawled, playsDone);
}
