import 'dart:math' as math;

import 'card_payload.dart';
import 'rarity.dart';
import 'rng.dart';

/// A genre the world draws songs from (Deezer genre ids).
class GenreInfo {
  const GenreInfo(this.id, this.name, this.weight, {this.nonEnglish = false});
  final int id;
  final String name;

  /// Relative spawn weight.
  final int weight;
  final bool nonEnglish;
}

/// Genres, with spawn weights. Genre 0 is Deezer's all-genre chart (a
/// source of popular songs, not a real genre).
const List<GenreInfo> kWorldGenres = [
  GenreInfo(0, 'Top Hits', 14),
  GenreInfo(132, 'Pop', 20),
  GenreInfo(116, 'Hip Hop', 18),
  GenreInfo(152, 'Rock', 14),
  GenreInfo(165, 'R&B', 10),
  GenreInfo(85, 'Alternative', 10),
  GenreInfo(113, 'Dance', 8),
  GenreInfo(106, 'Electronic', 8),
  GenreInfo(84, 'Country', 6),
  GenreInfo(464, 'Metal', 4),
  GenreInfo(169, 'Soul & Funk', 4),
  GenreInfo(466, 'Folk', 3),
  GenreInfo(144, 'Reggae', 2),
  GenreInfo(129, 'Jazz', 2),
  GenreInfo(153, 'Blues', 1),
  GenreInfo(173, 'Film & Games', 2),
  GenreInfo(98, 'Classical', 1),
  GenreInfo(197, 'Latin', 5, nonEnglish: true),
  GenreInfo(122, 'Reggaeton', 4, nonEnglish: true),
  GenreInfo(16, 'K-Pop & Asian', 3, nonEnglish: true),
  GenreInfo(75, 'Brazilian', 1, nonEnglish: true),
  GenreInfo(2, 'African', 1, nonEnglish: true),
  GenreInfo(81, 'Indian', 1, nonEnglish: true),
];

/// Song metadata shared by the game and the server.
class SongInfo {
  const SongInfo({
    required this.id,
    required this.title,
    required this.artistId,
    required this.artistName,
    this.albumId = 0,
    this.albumTitle = '',
    this.coverMd5 = '',
    this.artistPicMd5 = '',
    this.genreId = 0,
    this.rank = 0,
    this.duration = 0,
    this.plays = 0,
  });
  final int id;
  final String title;
  final int artistId;
  final String artistName;
  final int albumId;
  final String albumTitle;
  final String coverMd5;
  final String artistPicMd5;
  final int genreId;
  final int rank;
  final int duration;
  final int plays;

  CardPayload toPayload({required int uid, required Rarity rarity, bool shiny = false, Edition edition = Edition.standard, int serial = 0, int acquiredAt = 0}) =>
      CardPayload(
        uid: uid,
        songId: id,
        title: title,
        artistId: artistId,
        artistName: artistName,
        albumId: albumId,
        albumTitle: albumTitle,
        coverMd5: coverMd5,
        artistPicMd5: artistPicMd5,
        rarity: rarity,
        shiny: shiny,
        genreId: genreId,
        rank: rank,
        duration: duration,
        acquiredAt: acquiredAt,
        edition: edition,
        serial: serial,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        't': title,
        'a': artistId,
        'an': artistName,
        if (albumId != 0) 'al': albumId,
        if (albumTitle.isNotEmpty) 'at': albumTitle,
        if (coverMd5.isNotEmpty) 'c': coverMd5,
        if (artistPicMd5.isNotEmpty) 'ap': artistPicMd5,
        if (genreId != 0) 'g': genreId,
        if (rank != 0) 'r': rank,
        if (duration != 0) 'd': duration,
        if (plays != 0) 'p': plays,
      };

  factory SongInfo.fromJson(Map<String, dynamic> j) => SongInfo(
        id: (j['id'] as num).toInt(),
        title: j['t'] as String? ?? '',
        artistId: (j['a'] as num?)?.toInt() ?? 0,
        artistName: j['an'] as String? ?? '',
        albumId: (j['al'] as num?)?.toInt() ?? 0,
        albumTitle: j['at'] as String? ?? '',
        coverMd5: j['c'] as String? ?? '',
        artistPicMd5: j['ap'] as String? ?? '',
        genreId: (j['g'] as num?)?.toInt() ?? 0,
        rank: (j['r'] as num?)?.toInt() ?? 0,
        duration: (j['d'] as num?)?.toInt() ?? 0,
        plays: (j['p'] as num?)?.toInt() ?? 0,
      );
}

/// How big an artist is, 0 (tiny) … 1 (superstar): Last.fm plays of their
/// biggest song when known, otherwise Deezer fans and track rank.
double artistTier({int maxPlays = 0, int maxRank = 0, int fans = 0}) {
  if (maxPlays > 0) return ((math.log(maxPlays) / math.ln10 - 4.7) / 2.8).clamp(0.0, 1.0);
  final byRank = ((maxRank - 350000) / 550000).clamp(0.0, 1.0);
  final byFans = fans > 0 ? ((math.log(fans) / math.ln10 - 4.0) / 2.7).clamp(0.0, 1.0) : 0.0;
  return math.max(byRank, byFans);
}

/// Rarity from artist tier and the song's standing among the artist's
/// songs (0 = least played … 1 = most played).
Rarity rarityFor(double tier, double standing) {
  final score = 0.5 * tier + 0.5 * standing.clamp(0.0, 1.0);
  if (score >= 0.75) return Rarity.legendary;
  if (score >= 0.56) return Rarity.epic;
  if (score >= 0.37) return Rarity.rare;
  if (score >= 0.2) return Rarity.uncommon;
  return Rarity.common;
}

/// Rarities for a set of songs: each artist's songs are ranked against each
/// other and combined with how big the artist is.
Map<int, Rarity> computeRarities(Iterable<SongInfo> songs, {int Function(int artistId)? fansOf}) {
  double pop(SongInfo s, bool plays) => plays ? s.plays.toDouble() : s.rank.toDouble();
  final byArtist = <int, List<SongInfo>>{};
  for (final s in songs) {
    byArtist.putIfAbsent(s.artistId, () => []).add(s);
  }
  final out = <int, Rarity>{};
  for (final list in byArtist.values) {
    final usePlays = list.any((s) => s.plays > 0);
    list.sort((a, b) => pop(a, usePlays).compareTo(pop(b, usePlays)));
    final tier = artistTier(
      maxPlays: usePlays ? list.last.plays : 0,
      maxRank: list.fold<int>(0, (m, s) => s.rank > m ? s.rank : m),
      fans: fansOf?.call(list.first.artistId) ?? 0,
    );
    final n = list.length;
    final top = pop(list.last, usePlays);
    for (var i = 0; i < n; i++) {
      final s = list[i];
      final position = n == 1 ? 0.5 : i / (n - 1);
      final share = top <= 0 ? position : math.sqrt((pop(s, usePlays) / top).clamp(0.0, 1.0));
      out[s.id] = rarityFor(tier, 0.65 * position + 0.35 * share);
    }
  }
  return out;
}

/// An indexed pool of songs: per genre and rarity, for spawns and packs.
class SongPool {
  SongPool(Iterable<SongInfo> songs, {int Function(int artistId)? fansOf}) {
    for (final s in songs) {
      this.songs[s.id] = s;
    }
    for (final s in this.songs.values) {
      _byArtist.putIfAbsent(s.artistId, () => []).add(s);
    }
    rarities = computeRarities(this.songs.values, fansOf: fansOf);
    final ids = this.songs.keys.toList()..sort();
    for (final id in ids) {
      final s = this.songs[id]!;
      _pools.putIfAbsent(s.genreId, () => List.generate(5, (_) => <int>[]))[rarities[id]!.index].add(id);
    }
  }

  final Map<int, SongInfo> songs = {};
  late final Map<int, Rarity> rarities;
  final Map<int, List<List<int>>> _pools = {};
  final Map<int, List<SongInfo>> _byArtist = {};

  int get size => songs.length;
  Rarity rarityOf(int songId) => rarities[songId] ?? Rarity.common;

  List<int>? _nearest(int genre, int r) {
    final pools = _pools[genre];
    if (pools == null) return null;
    for (var d = 0; d < 5; d++) {
      for (final k in d == 0 ? [r] : [r - d, r + d]) {
        if (k >= 0 && k < 5 && pools[k].isNotEmpty) return pools[k];
      }
    }
    return null;
  }

  bool _hasGenre(int g) => _pools[g]?.any((p) => p.isNotEmpty) ?? false;

  int pickGenre(Rng rng, {Map<int, double> bias = const {}}) {
    final available = [for (final g in kWorldGenres) if (_hasGenre(g.id)) g];
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

  /// A song of [rarity] (or the closest available) in [genreId].
  SongInfo? pickSong(Rng rng, {int? genreId, Rarity? rarity}) {
    if (songs.isEmpty) return null;
    final r = (rarity ?? rng.rollRarity()).index;
    var pool = _nearest(genreId ?? pickGenre(rng), r) ?? _nearest(pickGenre(rng), r);
    if (pool == null) {
      final any = _pools.keys.where(_hasGenre).toList()..sort();
      if (any.isEmpty) return null;
      pool = _nearest(any[rng.nextInt(any.length)], r);
    }
    if (pool == null || pool.isEmpty) return null;
    return songs[pool[rng.nextInt(pool.length)]];
  }

  /// Favourite artists' songs turn up [boost]× as often: returns a forced
  /// favourite pick with the right probability, else null.
  SongInfo? maybeFavorite(Rng rng, Rarity rarity, Set<int> favorites, {double boost = 10, Map<int, double> bias = const {}}) {
    if (favorites.isEmpty) return null;
    final favSongs = [for (final a in favorites) ...?_byArtist[a]];
    if (favSongs.isEmpty) return null;
    final share = (favSongs.length / songs.length).clamp(1e-4, 0.999);
    final target = boost * share / (1 + (boost - 1) * share);
    final q = ((target - share) / (1 - share)).clamp(0.0, 1.0);
    if (rng.nextDouble() >= q) return null;
    final atRarity = [for (final s in favSongs) if (rarityOf(s.id) == rarity) s];
    final pick = atRarity.isNotEmpty ? atRarity : favSongs;
    return pick[rng.nextInt(pick.length)];
  }
}

/// A song placed in the world.
class WorldSpawn {
  const WorldSpawn({
    required this.id,
    required this.lat,
    required this.lng,
    required this.song,
    required this.rarity,
    required this.shiny,
    required this.edition,
    required this.expiresAt,
  });
  final String id;
  final double lat;
  final double lng;
  final SongInfo song;
  final Rarity rarity;
  final bool shiny;
  final Edition edition;
  final int expiresAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': lat,
        'lng': lng,
        'song': song.toJson(),
        'rarity': rarity.index,
        'shiny': shiny,
        if (edition != Edition.standard) 'ed': edition.index,
        'exp': expiresAt,
      };

  factory WorldSpawn.fromJson(Map<String, dynamic> j) => WorldSpawn(
        id: j['id'] as String,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        song: SongInfo.fromJson(j['song'] as Map<String, dynamic>),
        rarity: Rarity.fromIndex((j['rarity'] as num).toInt()),
        shiny: j['shiny'] as bool? ?? false,
        edition: Edition.fromIndex((j['ed'] as num?)?.toInt() ?? 0),
        expiresAt: (j['exp'] as num).toInt(),
      );
}

/// The world's spawns: ~200 m cells and 15-minute windows, each hashed with
/// a secret seed into its songs. Everyone at the same place and time gets
/// the same spawns (favourite artists aside).
class WorldSpawner {
  WorldSpawner(this.pool, {required this.seed, this.sampleSongs = const []});
  final SongPool pool;
  final int seed;

  /// Songs that can appear as Sample editions.
  final List<SongInfo> sampleSongs;

  static const cellDeg = 0.0018;
  static const window = Duration(minutes: 15);

  static int windowAt(int ms) => ms ~/ window.inMilliseconds;

  static double lngDegForRow(int cy) {
    final bandLat = ((cy + 0.5) * cellDeg).floorToDouble() + 0.5;
    return cellDeg / math.max(0.2, math.cos(bandLat * math.pi / 180));
  }

  /// Spawns within [radiusCells] cells of a position.
  List<WorldSpawn> around(double lat, double lng, {int radiusCells = 2, required int nowMs, Set<int> favorites = const {}}) {
    final w = windowAt(nowMs);
    final cy = (lat / cellDeg).floor();
    final out = <WorldSpawn>[];
    for (var dy = -radiusCells; dy <= radiusCells; dy++) {
      final lngDeg = lngDegForRow(cy + dy);
      final cx = (lng / lngDeg).floor();
      for (var dx = -radiusCells; dx <= radiusCells; dx++) {
        out.addAll(cell(cx + dx, cy + dy, w, favorites: favorites));
      }
    }
    return out;
  }

  /// A spawn by id ("cx:cy:window:i"), or null if there's no such spawn.
  WorldSpawn? byId(String id, {Set<int> favorites = const {}}) {
    final p = id.split(':');
    if (p.length != 4) return null;
    final cx = int.tryParse(p[0]), cy = int.tryParse(p[1]), w = int.tryParse(p[2]);
    if (cx == null || cy == null || w == null) return null;
    for (final s in cell(cx, cy, w, favorites: favorites)) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The spawns of one cell in one window.
  List<WorldSpawn> cell(int cx, int cy, int w, {Set<int> favorites = const {}}) {
    final out = <WorldSpawn>[];
    final rng = Rng(hashInts([seed, cx, cy, w]));
    final roll = rng.nextInt(100);
    final count = roll < 20 ? 0 : roll < 55 ? 1 : roll < 85 ? 2 : 3;
    final lngDeg = lngDegForRow(cy);
    final expires = (w + 1) * window.inMilliseconds;
    for (var i = 0; i < count; i++) {
      // Each spawn gets its own generator so favourites (per player) never
      // shift the other spawns.
      final r = Rng(hashInts([seed, cx, cy, w, i]));
      final lat = (cy + r.nextDouble()) * cellDeg;
      final lng = (cx + r.nextDouble()) * lngDeg;
      final rolled = r.rollRarity();
      final shiny = r.chance(kShinyOdds);
      final er = r.nextInt(kSampleOdds * kCanvasOdds);
      final genre = pool.pickGenre(r);
      final base = pool.pickSong(r, genreId: genre, rarity: rolled);
      final fav = pool.maybeFavorite(Rng(hashInts([seed, cx, cy, w, i, 77])), rolled, favorites);
      var song = fav ?? base;
      if (song == null) continue;
      var edition = Edition.standard;
      if (er % kSampleOdds == 0 && sampleSongs.isNotEmpty) {
        song = sampleSongs[(er ~/ kSampleOdds) % sampleSongs.length];
        edition = Edition.sample;
      } else if (er % kCanvasOdds == 1) {
        edition = Edition.canvas;
      } else if (er % kLiveOdds == 2) {
        edition = Edition.live;
      }
      out.add(WorldSpawn(
        id: '$cx:$cy:$w:$i',
        lat: lat,
        lng: lng,
        song: song,
        rarity: pool.rarities[song.id] ?? rolled,
        shiny: shiny && edition == Edition.standard,
        edition: edition,
        expiresAt: expires,
      ));
    }
    return out;
  }
}

/// Great-circle distance in metres.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180, dl = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
