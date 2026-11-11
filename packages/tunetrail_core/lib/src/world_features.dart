import 'dart:math' as math;

import 'rng.dart';
import 'song_catalog.dart';

// ===================================================================== terrain
/// What kind of ground a square of a spawn cell is, for the small features
/// that stand on it.
enum Terrain {
  unknown,
  water,
  grass,
  rock,
  wood,
  sand,

  /// Built-up ground away from the street (yards, lots, blocks).
  urban,

  /// A street in a built-up area (where sewer grates go).
  street,
}

/// The terrain of one spawn cell: the same 8×8 grid of ~25 m squares as
/// [CellGround], read by the game from its map data.
class CellTerrain {
  CellTerrain(this.squares) : assert(squares.length == n * n);
  static const n = CellGround.n;

  /// Row-major from the cell's south-west corner.
  final List<Terrain> squares;

  /// 64 digits, one per square.
  String encode() => squares.map((t) => t.index).join();

  static CellTerrain? parse(String code) {
    if (code.length != n * n) return null;
    final out = <Terrain>[];
    for (final ch in code.codeUnits) {
      final v = ch - 0x30;
      if (v < 0 || v >= Terrain.values.length) return null;
      out.add(Terrain.values[v]);
    }
    return CellTerrain(out);
  }
}

// ==================================================================== features
/// Small things standing around the map. A few of them glow: those do
/// something (see [FeatureKind.nest] and the rewards below).
enum FeatureKind {
  bush(Terrain.grass, 'Bush', 1),
  rocks(Terrain.rock, 'Rock pile', 0.25),
  lilypad(Terrain.water, 'Lily pad', 0.5),
  sapling(Terrain.wood, 'Sapling', 0.25),
  sandcastle(Terrain.sand, 'Sand castle', 0.1),
  grate(Terrain.street, 'Sewer grate', 0.1);

  const FeatureKind(this.terrain, this.label, this.density);
  final Terrain terrain;
  final String label;

  /// How often it turns up compared with a bush (the most common): of
  /// the spots spaced out for features, the share this kind keeps.
  final double density;

  /// A glowing bush or sapling is a nest: songs spawn three times as often
  /// around it.
  bool get nest => this == bush || this == sapling;

  static FeatureKind? on(Terrain t) {
    for (final k in values) {
      if (k.terrain == t) return k;
    }
    return null;
  }

  static FeatureKind? byName(String? n) {
    for (final k in values) {
      if (k.name == n) return k;
    }
    return null;
  }
}

/// One feature: at most one per square of a cell.
class WorldFeature {
  const WorldFeature(this.cx, this.cy, this.square, this.kind, this.lat, this.lng);
  final int cx, cy, square;
  final FeatureKind kind;
  final double lat, lng;

  String get id => '$cx:$cy:$square';

  /// A stable number for varying its look (size, turn).
  int get variant => hashInts([cx, cy, square, 5]) & 0x7fffffff;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name, 'lat': lat, 'lng': lng};
}

/// Where the map's features are. Which squares have one depends only on
/// the place and its terrain (so they never move); which of them glow
/// changes every day and is the server's secret.
abstract final class WorldFeatures {
  /// Features stand at least this far apart.
  static const double minSpacing = 100;

  /// Share of ~25 m squares that are a candidate spot (before spacing).
  static const double candidateDensity = 0.2;

  /// 1 in [glowOdds] features glows on a given day.
  static const int glowOdds = 20;

  /// How far a nest's effect reaches.
  static const double nestRadius = 100;

  static const int _salt = 0x7ea7;

  /// Where features could stand in a cell (before spacing them out).
  static List<WorldFeature> candidates(int cx, int cy, CellTerrain terrain) {
    final out = <WorldFeature>[];
    final lngDeg = WorldSpawner.lngDegForRow(cy);
    for (var sq = 0; sq < CellTerrain.n * CellTerrain.n; sq++) {
      final kind = FeatureKind.on(terrain.squares[sq]);
      if (kind == null) continue;
      final r = Rng(hashInts([_salt, cx, cy, sq]));
      if (r.nextDouble() >= candidateDensity) continue;
      final row = sq ~/ CellTerrain.n, col = sq % CellTerrain.n;
      // Near the middle of its square (what the map says the square is).
      final fy = (row + 0.5 + (r.nextDouble() - 0.5) * 0.7) / CellTerrain.n;
      final fx = (col + 0.5 + (r.nextDouble() - 0.5) * 0.7) / CellTerrain.n;
      out.add(WorldFeature(cx, cy, sq, kind, (cy + fy) * WorldSpawner.cellDeg, (cx + fx) * lngDeg));
    }
    return out;
  }

  static int _priority(WorldFeature f) => hashInts([_salt, f.cx, f.cy, f.square, 0x5ace]) & 0x7fffffff;

  static double _metres(double lat1, double lng1, double lat2, double lng2) {
    final dy = (lat2 - lat1) * 111132.95, dx = (lng2 - lng1) * 111319.49 * math.cos(lat1 * math.pi / 180);
    return math.sqrt(dx * dx + dy * dy);
  }

  /// The features of a cell, at least [minSpacing] apart from each other
  /// and from those of the cells around it. A candidate stands if no
  /// candidate within [minSpacing] outranks it (a fixed random rank), so
  /// the answer is the same whoever works it out. [terrainOf] gives the
  /// terrain of a cell (null where it isn't known: no candidates there).
  static List<WorldFeature> inCell(int cx, int cy, CellTerrain? Function(int cx, int cy) terrainOf) {
    final own = terrainOf(cx, cy);
    if (own == null) return const [];
    final mine = candidates(cx, cy, own);
    if (mine.isEmpty) return const [];
    final near = <WorldFeature>[...mine];
    final (_, lng0) = WorldSpawner.cellCenter(cx, cy);
    for (var dy = -1; dy <= 1; dy++) {
      // Rows have different cell widths: find each row's neighbours by
      // position, not by index.
      final row = cy + dy;
      final rcx = (lng0 / WorldSpawner.lngDegForRow(row)).floor();
      for (var dx = -1; dx <= 1; dx++) {
        final ox = rcx + dx;
        if (ox == cx && row == cy) continue;
        final t = terrainOf(ox, row);
        if (t != null) near.addAll(candidates(ox, row, t));
      }
    }
    return [
      for (final f in mine)
        // Spaced out first (over every kind), then thinned by kind — so
        // spacing holds and rarer kinds stay rarer.
        if (!near.any((o) => o.id != f.id && _outranks(o, f) && _metres(f.lat, f.lng, o.lat, o.lng) < minSpacing) &&
            Rng(hashInts([_salt, f.cx, f.cy, f.square, 0x7417])).nextDouble() < f.kind.density)
          f,
    ];
  }

  static bool _outranks(WorldFeature a, WorldFeature b) {
    final pa = _priority(a), pb = _priority(b);
    return pa != pb ? pa > pb : a.id.compareTo(b.id) > 0;
  }

  /// Whether the feature in [square] of a cell glows on [day].
  static bool glows(int seed, int cx, int cy, int square, int day) => Rng(hashInts([seed, cx, cy, square, day, 91])).nextInt(glowOdds) == 0;

  /// Extra spawn spots around a glowing nest: (slot, lat, lng). Songs
  /// spawn three times as often within [nestRadius] of it, so it adds
  /// twice what the area has by itself (a cell has ~0.5–3 spots).
  static List<(int, double, double)> nestSpots(int seed, WorldFeature nest, int day, {double expectedInCell = 1.5}) {
    final r = Rng(hashInts([seed, nest.cx, nest.cy, nest.square, day, 37]));
    const cellArea = 200.0 * 200.0;
    final expected = 2 * expectedInCell * math.pi * nestRadius * nestRadius / cellArea;
    final count = (expected.floor() + (r.nextDouble() < expected - expected.floor() ? 1 : 0)).clamp(1, 6);
    final mPerLat = 111132.95, mPerLng = 111319.49 * math.max(0.2, math.cos(nest.lat * math.pi / 180));
    return [
      for (var k = 0; k < count; k++)
        () {
          final a = r.nextDouble() * 2 * math.pi, d = nestRadius * (0.25 + 0.7 * math.sqrt(r.nextDouble()));
          // Slots from 100 up never collide with a cell's own spots.
          return (100 + nest.square * 8 + k, nest.lat + math.sin(a) * d / mPerLat, nest.lng + math.cos(a) * d / mPerLng);
        }(),
    ];
  }
}

// ===================================================================== rewards
/// Coins in a glowing sewer grate, and how often each turns up.
const List<(int, int)> kGrateCoins = [(250, 40), (500, 30), (1000, 18), (2500, 9), (5000, 3)];

/// Bits in a treasure chest, and how often each turns up.
const List<(int, int)> kTreasureBits = [(20, 60), (50, 30), (100, 10)];

/// Chance (in 100) that a song fished up or mined is Legendary (else Epic).
const int kFoundLegendaryPercent = 15;

/// A treasure is buried between these distances from its sand castle; the
/// map is lost when its holder strays further than the far one from where
/// they picked it up.
const double kTreasureMinMeters = 120, kTreasureMaxMeters = 500;

/// How close to the X the player must be to dig.
const double kTreasureDigMeters = 40;

T rollWeighted<T>(List<(T, int)> table, double roll01) {
  final total = table.fold<int>(0, (a, e) => a + e.$2);
  var roll = (roll01 * total).floor();
  for (final (v, w) in table) {
    roll -= w;
    if (roll < 0) return v;
  }
  return table.last.$1;
}

// ========================================================================= DJs
/// How long a DJ battle lasts (a song preview).
const int kBattleSeconds = 30;

/// Players within this distance of a battle can join it.
const double kBattleJoinMeters = 150;

/// The DJ's average accuracy for a song: 90% for a somewhat popular song up
/// to 100% for the biggest hits (Deezer rank 500,000 → 1,000,000).
double djAccuracy(int rank) => 90 + 10 * ((rank - kDjMinRank) / (1000000 - kDjMinRank)).clamp(0.0, 1.0);

/// The least popular song a DJ plays.
const int kDjMinRank = 500000;

/// A team's accuracy: the players' average, raised by half for a second
/// player, a quarter more for a third, an eighth for a fourth… (never over
/// 100). Four players at 50% make 93.75%.
double teamAccuracy(List<double> accuracies) {
  if (accuracies.isEmpty) return 0;
  final mean = accuracies.fold<double>(0, (a, b) => a + b) / accuracies.length;
  final boost = 2 - math.pow(0.5, accuracies.length - 1);
  return math.min(100.0, mean * boost);
}

/// A DJ standing by a road, waiting to be challenged.
class DjNpc {
  const DjNpc({required this.id, required this.name, required this.lat, required this.lng, required this.look, required this.song, required this.accuracy, this.expiresAt = 0});
  final String id;
  final String name;
  final double lat, lng;

  /// {color, hat, shirt, backpack, pet} like a player's look.
  final Map<String, dynamic> look;
  final SongInfo song;
  final double accuracy;
  final int expiresAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'look': look,
        'song': song.toJson(),
        'acc': accuracy,
        if (expiresAt > 0) 'exp': expiresAt,
      };

  factory DjNpc.fromJson(Map<String, dynamic> j) => DjNpc(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'DJ',
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        look: (j['look'] as Map<String, dynamic>?) ?? const {},
        song: SongInfo.fromJson(j['song'] as Map<String, dynamic>),
        accuracy: (j['acc'] as num?)?.toDouble() ?? 90,
        expiresAt: (j['exp'] as num?)?.toInt() ?? 0,
      );
}

/// Where the day's DJs stand: beside a road, never within [minSpacing] of
/// each other.
abstract final class WorldDjs {
  static const int cellOdds = 14;

  /// DJs stand at least this far apart.
  static const double minSpacing = 1000;

  /// A DJ's spot is within ~130 m of its cell's middle, so cells whose
  /// middles are this close could put two DJs too close together.
  static const double _clearance = minSpacing + 260;

  static bool _candidate(int seed, int cx, int cy, int day) => Rng(hashInts([seed, cx, cy, day, 0xd1])).nextInt(cellOdds) == 0;
  static int _rank(int seed, int cx, int cy, int day) => hashInts([seed, cx, cy, day, 0xd3]) & 0x7fffffff;

  /// Whether a cell may have a DJ today: it's a candidate, and no candidate
  /// cell nearby outranks it.
  static bool _stands(int seed, int cx, int cy, int day) {
    if (!_candidate(seed, cx, cy, day)) return false;
    final (lat, lng) = WorldSpawner.cellCenter(cx, cy);
    final mine = _rank(seed, cx, cy, day);
    final reach = (_clearance / 200).ceil() + 1;
    for (var dy = -reach; dy <= reach; dy++) {
      final row = cy + dy;
      final rcx = (lng / WorldSpawner.lngDegForRow(row)).floor();
      for (var dx = -reach; dx <= reach; dx++) {
        final ox = rcx + dx;
        if (ox == cx && row == cy) continue;
        if (!_candidate(seed, ox, row, day)) continue;
        final (olat, olng) = WorldSpawner.cellCenter(ox, row);
        if (WorldFeatures._metres(lat, lng, olat, olng) >= _clearance) continue;
        final r = _rank(seed, ox, row, day);
        if (r > mine || (r == mine && (ox, row).hashCode > (cx, cy).hashCode)) return false;
      }
    }
    return true;
  }

  static const _names = [
    'Spinz', 'Echo', 'Crate', 'Wobble', 'Fader', 'Vinyl', 'Loop', 'Sub', 'Treble', 'Scratch', 'Nova', 'Pulse', 'Reverb', 'Static', 'Groove',
    'Mono', 'Stereo', 'Phase', 'Riddim', 'Tempo', 'Synth', 'Bassline', 'Hi-Hat', 'Breaks', 'Needle', 'Dub', 'Flux', 'Mixdown', 'Rewind', 'Drop',
  ];
  static const _colors = [0xFFE9E6FF, 0xFFFF6B6B, 0xFF48DBFB, 0xFFFECA57, 0xFF1DD1A1, 0xFFFF9FF3, 0xFFFF9F43, 0xFF54A0FF, 0xFFC8D6E5, 0xFFA29BFE];
  static const _hats = ['hat_headphones', 'hat_headphones', 'hat_cap', 'hat_beanie', 'hat_tophat', 'hat_cowboy', 'hat_party', 'hat_wizard', 'hat_crown', 'hat_halo'];
  static const _shirts = ['shirt_tee_red', 'shirt_tee_black', 'shirt_striped', 'shirt_hoodie', 'shirt_hawaiian', 'shirt_tux', 'shirt_lightning', 'shirt_rainbow'];
  static const _bags = [null, null, 'bag_classic', 'bag_boombox', 'bag_guitar', 'bag_crate', 'bag_jetpack', 'bag_wings'];
  static const _pets = [null, null, null, 'pet_cat', 'pet_dog', 'pet_bird', 'pet_slime', 'pet_robot', 'pet_ghost', 'pet_hamster'];

  /// A DJ's name and cosmetics from a hash.
  static (String, Map<String, dynamic>) persona(int hash) {
    final r = Rng(hash);
    final name = 'DJ ${r.pick(_names)}';
    final bag = r.pick(_bags), pet = r.pick(_pets);
    return (
      name,
      {
        'color': r.pick(_colors),
        'hat': r.pick(_hats),
        'shirt': r.pick(_shirts),
        if (bag != null) 'backpack': bag,
        if (pet != null) 'pet': pet,
      }
    );
  }

  /// The songs DJs play (somewhat to massively popular), most popular last.
  static List<SongInfo> playable(Iterable<SongInfo> songs) =>
      [for (final s in songs) if (s.rank >= kDjMinRank) s]..sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.id.compareTo(b.id));

  /// The DJ in a cell on [day], if it has one: next to a road (a built-up
  /// square of [ground]).
  static DjNpc? inCell(int seed, int cx, int cy, int day, CellGround ground, List<SongInfo> playable, {int expiresAt = 0}) {
    if (playable.isEmpty) return null;
    if (!_stands(seed, cx, cy, day)) return null;
    final r = Rng(hashInts([seed, cx, cy, day, 0xd1]))..nextInt(cellOdds);
    final built = [for (var i = 0; i < ground.squares.length; i++) if (ground.squares[i] == CellGround.built) i];
    if (built.isEmpty) return null;
    final sq = built[r.nextInt(built.length)];
    final (lat, lng) = WorldSpawner.squareCenter(cx, cy, sq ~/ CellGround.n, sq % CellGround.n);
    final song = playable[r.nextInt(playable.length)];
    final (name, look) = persona(hashInts([seed, cx, cy, day, 0xd2]));
    return DjNpc(id: 'dj:$cx:$cy:$day', name: name, lat: lat, lng: lng, look: look, song: song, accuracy: djAccuracy(song.rank), expiresAt: expiresAt);
  }
}
