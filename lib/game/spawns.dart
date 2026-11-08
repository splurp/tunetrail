import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../data/samples.dart';
import '../data/catalog.dart';
import '../data/models.dart';

/// A song floating in the wild.
class Spawn {
  Spawn({
    required this.id,
    required this.point,
    required this.song,
    required this.rarity,
    required this.shiny,
    required this.expiresAt,
    this.edition = Edition.standard,
  });
  final String id;
  final LatLng point;
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final DateTime expiresAt;
  final Edition edition;

  Spawn withEdition(Edition e) =>
      Spawn(id: id, point: point, song: song, rarity: rarity, shiny: shiny, expiresAt: expires, edition: e);
  DateTime get expires => expiresAt;
}

/// Chance a wild spawn is a Movie edition (kept only if a video exists).
const double kMovieSpawnChance = 0.035;

/// Chance a spawn of a song with known sample data is a Sample edition.
const double kSampleSpawnChance = 0.3;

/// Deterministic world spawns.
///
/// The world is divided into ~200 m grid cells and 15-minute time windows.
/// Every cell/window pair is hashed into a seed, so every player standing in
/// the same place at the same time sees the same songs (given the same song
/// catalog) — no server round-trip required.
class SpawnEngine {
  SpawnEngine(this.catalog, {this.zoneBias});
  final Catalog catalog;

  /// Genre multipliers for a location (genre "strength areas"), from the
  /// map data around the spawn point.
  final Map<int, double> Function(double lat, double lng)? zoneBias;

  static const cellDeg = 0.0018; // ≈200 m of latitude
  static const window = Duration(minutes: 15);
  static const worldSeed = 0x7475_6E65_7472_6169; // "tunetrai"

  int _windowIndex(DateTime t) => t.millisecondsSinceEpoch ~/ window.inMilliseconds;

  /// Spawns within [radiusCells] cells of [center].
  List<Spawn> around(LatLng center, {int radiusCells = 2, DateTime? now, Set<String> exclude = const {}}) {
    now ??= DateTime.now();
    final w = _windowIndex(now);
    final cy = (center.latitude / cellDeg).floor();
    final out = <Spawn>[];
    for (var dy = -radiusCells; dy <= radiusCells; dy++) {
      // The cell width in longitude depends only on the cell row (never on
      // where the player is standing), so a spawn's position is fixed for
      // everyone no matter how they move.
      final lngDeg = lngDegForRow(cy + dy);
      final cx = (center.longitude / lngDeg).floor();
      for (var dx = -radiusCells; dx <= radiusCells; dx++) {
        out.addAll(_cell(cx + dx, cy + dy, lngDeg, w, exclude));
      }
    }
    return out;
  }

  /// Longitude size of cells in a row, quantised to the row's 1° latitude
  /// band so it's identical for every player and every position.
  static double lngDegForRow(int cy) {
    final bandLat = ((cy + 0.5) * cellDeg).floorToDouble() + 0.5;
    return cellDeg / math.max(0.2, math.cos(bandLat * math.pi / 180));
  }

  List<Spawn> _cell(int cx, int cy, double lngDeg, int w, Set<String> exclude) {
    // Spawn windows are staggered per cell so the map refreshes gradually.
    final out = <Spawn>[];
    final rng = Rng(hashInts([worldSeed, cx, cy, w]));
    // 0–3 spawns per cell; denser on average than a straight 0..2.
    final roll = rng.nextInt(100);
    final count = roll < 20 ? 0 : roll < 55 ? 1 : roll < 85 ? 2 : 3;
    final hour = DateTime.now().hour;
    final bias = _timeBias(hour);
    final expires = DateTime.fromMillisecondsSinceEpoch((w + 1) * window.inMilliseconds);
    for (var i = 0; i < count; i++) {
      final id = '$cx:$cy:$w:$i';
      final lat = (cy + rng.nextDouble()) * cellDeg;
      final lng = (cx + rng.nextDouble()) * lngDeg;
      final rolled = rng.rollRarity();
      final shiny = rng.chance(kShinyOdds);
      final zb = zoneBias?.call(lat, lng);
      final weights = zb == null || zb.isEmpty ? bias : _combine(bias, zb);
      final genre = catalog.pickGenre(rng, bias: weights);
      final song = catalog.maybeFavorite(rng, rolled, bias: weights) ?? catalog.pickSong(rng, genreId: genre, rarity: rolled);
      if (song == null || exclude.contains(id)) continue;
      final rarity = catalog.rarityOf(song);
      final er = rng.nextDouble();
      final edition = SampleLibrary.has(song.id) && er < kSampleSpawnChance
          ? Edition.sample
          : er > 1 - kMovieSpawnChance
          ? Edition.movie
          : Edition.standard;
      out.add(Spawn(
        id: id,
        point: LatLng(lat, lng),
        song: song,
        rarity: rarity,
        shiny: shiny,
        expiresAt: expires,
        edition: edition,
      ));
    }
    return out;
  }

  Map<int, double> _combine(Map<int, double> a, Map<int, double> b) {
    final out = Map<int, double>.of(a);
    b.forEach((k, v) => out[k] = (out[k] ?? 1) * v);
    return out;
  }

  /// Time of day nudges which genres appear (night = electronic & R&B,
  /// morning = pop & folk, evening = rock & hip hop).
  Map<int, double> _timeBias(int hour) {
    if (hour >= 22 || hour < 5) {
      return {106: 2.0, 113: 2.0, 165: 1.6, 129: 1.5};
    } else if (hour < 11) {
      return {132: 1.4, 466: 1.8, 84: 1.4, 98: 1.5};
    } else if (hour >= 17) {
      return {152: 1.5, 116: 1.4, 464: 1.6, 85: 1.3};
    }
    return const {};
  }
}

/// Great-circle distance in metres.
double metersBetween(LatLng a, LatLng b) => const Distance().as(LengthUnit.Meter, a, b);
