import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import 'deezer_api.dart';
import 'models.dart';

/// The local song catalog: every song the game knows about.
///
/// Built progressively from the Deezer API (genre charts, then each genre's
/// most popular artists' top tracks, then related artists) and persisted as
/// an append-only JSON-lines file so it loads in milliseconds next launch.
class Catalog extends ChangeNotifier {
  Catalog(this.api, this.dir);

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

  void ensureFromPayload(CardPayload c) {
    if (!songs.containsKey(c.songId)) addSongs([Song.fromPayload(c)]);
  }

  // -------------------------------------------------------------- picking
  int get size => songs.length;
  List<int> poolFor(int genreId) => _genrePools[genreId] ?? const [];
  Iterable<int> get genresWithSongs =>
      _genrePools.entries.where((e) => e.value.isNotEmpty).map((e) => e.key);

  /// Deterministically picks a song for a spawn/pack.
  Song? pickSong(Rng rng, {int? genreId}) {
    if (songs.isEmpty) return null;
    var g = genreId ?? _pickGenre(rng);
    var pool = poolFor(g);
    if (pool.isEmpty) {
      g = _pickGenre(rng);
      pool = poolFor(g);
    }
    if (pool.isEmpty) {
      // Fallback: any genre with songs.
      final any = genresWithSongs.toList()..sort();
      if (any.isEmpty) return null;
      pool = poolFor(any[rng.nextInt(any.length)]);
    }
    // Favour popular songs a little: best of two rolls by rank.
    final a = songs[pool[rng.nextInt(pool.length)]]!;
    final b = songs[pool[rng.nextInt(pool.length)]]!;
    return rng.nextInt(3) == 0 ? (a.rank >= b.rank ? b : a) : (a.rank >= b.rank ? a : b);
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
            final genre = kGenres.firstWhere((g) => g.id == seed.genreId,
                orElse: () => kGenres.first);
            final minFans = genre.nonEnglish ? nonEnglishMinFans : relatedMinFans;
            if (r.fans < minFans) continue;
            r.genreId = seed.genreId;
            crawlStatus = 'Discovering ${r.name}…';
            notifyListeners();
            await _crawlArtist(r, genre, fansKnown: true);
          }
        } catch (_) {}
      }
      crawlStatus = '';
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
  _ParsedCatalog(this.songs, this.artists, this.crawled);
  final List<Song> songs;
  final List<ArtistInfo> artists;
  final List<int> crawled;
}

_ParsedCatalog _parseCatalog(String text) {
  final songs = <int, Song>{};
  final artists = <int, ArtistInfo>{};
  final crawled = <int>[];
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
      }
    } catch (_) {
      // Ignore a torn final line from an interrupted write.
    }
  }
  return _ParsedCatalog(songs.values.toList(), artists.values.toList(), crawled);
}
