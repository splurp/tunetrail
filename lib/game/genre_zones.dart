import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart' show Terrain;

import '../map3d/map_data.dart';
import '../map3d/tile_data.dart';

/// A genre "strength area": a kind of place where certain genres spawn
/// more often.
class ZoneDef {
  const ZoneDef(this.id, this.name, this.description, this.genres, this.icon);
  final String id;
  final String name;
  final String description;

  /// Deezer genre ids boosted in this zone.
  final List<int> genres;
  final IconData icon;
}

const kZones = <ZoneDef>[
  ZoneDef('country', 'Open Country', 'Farmland, meadows and wide-open fields with few roads or buildings.', [84], Icons.grass),
  ZoneDef('hiphop', 'Concrete Jungle', 'Dense city blocks: tightly packed buildings and busy street grids.', [116], Icons.apartment),
  ZoneDef('water', 'Waterfront', 'Rivers, lakes, harbours and coastlines.', [153, 129], Icons.water),
  ZoneDef('electronic', 'Industrial Grid', 'Factories, warehouses, data centres, corporate campuses and industrial estates.', [106, 113], Icons.factory),
  ZoneDef('rnb', 'After Hours', 'Nightlife and dining strips: bars, lounges, clubs and late-night restaurants.', [165], Icons.nightlife),
  ZoneDef('metal', 'Iron & Stone', 'Rail yards, tracks, quarries, cemeteries and heavy infrastructure.', [464], Icons.train),
  ZoneDef('rock', 'Arena & Open Road', 'Highways, stadiums, arenas, concert venues and rocky terrain.', [152], Icons.stadium),
  ZoneDef('pop', 'Shopping District', 'Malls, retail streets, shops and cinemas.', [132, 0], Icons.shopping_bag),
  ZoneDef('kpop', 'Neon Campus', 'Campuses, arcades, karaoke rooms, theme parks and Korean food spots.', [16], Icons.videogame_asset),
  ZoneDef('latin', 'Plaza & Shore', 'Public squares, markets, beaches, football pitches and Latin American eateries.', [197, 122, 75], Icons.beach_access),
  ZoneDef('folk', 'Woodland', 'Forests, woods and nature reserves.', [466], Icons.forest),
  ZoneDef('classical', 'Old Town', 'Churches, museums, theatres and concert halls.', [98, 173], Icons.account_balance),
  ZoneDef('soul', 'Café Row', 'Coffee shops, record stores and music venues.', [169, 85], Icons.local_cafe),
  ZoneDef('reggae', 'Island Time', 'Sandy beaches and dunes.', [144], Icons.wb_sunny),
];

/// Result of sampling the zones around a point.
class ZoneReading {
  const ZoneReading(this.scores, this.hasData);
  final Map<String, double> scores; // zone id → 0..1
  final bool hasData;

  static const strength = 6.0;

  /// Spawn-weight multipliers per genre.
  Map<int, double> get genreBias {
    final out = <int, double>{};
    for (final z in kZones) {
      final s = scores[z.id] ?? 0;
      if (s <= 0) continue;
      for (final g in z.genres) {
        out[g] = math.max(out[g] ?? 1, 1 + strength * s);
      }
    }
    return out;
  }

  /// Strongest zones, best first (score ≥ 0.25).
  List<(ZoneDef, double)> get active {
    final l = [
      for (final z in kZones)
        if ((scores[z.id] ?? 0) >= 0.25) (z, scores[z.id]!)
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return l;
  }
}

/// Samples the genre-zone grids of loaded map tiles.
class GenreZones {
  GenreZones(this.map);
  final MapData map;

  /// What the ground is like at a point, for spawning: null while the map
  /// there hasn't loaded, else water, open land, or built-up land (roads,
  /// buildings, or residential/commercial/industrial ground).
  int? groundAt(double lat, double lon) {
    if (map.originLat.isNaN) return null;
    final (wx, wy) = map.toWorld(lat, lon);
    final t = map.tileAtWorld(wx, wy);
    if (t == null) return null;
    final col = ((wx - t.minX) / (t.maxX - t.minX) * kZoneGrid).floor().clamp(0, kZoneGrid - 1);
    final row = ((t.maxY - wy) / (t.maxY - t.minY) * kZoneGrid).floor().clamp(0, kZoneGrid - 1);
    final i = row * kZoneGrid + col;
    final f = t.flags[i];
    if (f & ZoneFlag.water != 0) return 1;
    const builtFlags = ZoneFlag.residential | ZoneFlag.commercial | ZoneFlag.retail | ZoneFlag.industrial | ZoneFlag.plaza |
        ZoneFlag.parking | ZoneFlag.campus | ZoneFlag.megaBuilding | ZoneFlag.sports;
    final built = f & builtFlags != 0 ||
        t.counts[ZoneCount.buildings]![i] > 0 ||
        t.counts[ZoneCount.roadMeters]![i] > 0 ||
        t.counts[ZoneCount.highwayMeters]![i] > 0;
    return built ? 3 : 2;
  }

  /// What kind of ground a point is, for the small features standing on
  /// it (null while the map there hasn't loaded).
  Terrain? terrainAt(double lat, double lon) {
    if (map.originLat.isNaN) return null;
    final (wx, wy) = map.toWorld(lat, lon);
    final t = map.tileAtWorld(wx, wy);
    if (t == null) return null;
    final col = ((wx - t.minX) / (t.maxX - t.minX) * kZoneGrid).floor().clamp(0, kZoneGrid - 1);
    final row = ((t.maxY - wy) / (t.maxY - t.minY) * kZoneGrid).floor().clamp(0, kZoneGrid - 1);
    final i = row * kZoneGrid + col;
    final f = t.flags[i];
    if (f & ZoneFlag.water != 0) return Terrain.water;
    if (f & ZoneFlag.beach != 0) return Terrain.sand;
    if (f & ZoneFlag.rock != 0) return Terrain.rock;
    if (f & ZoneFlag.forest != 0) return Terrain.wood;
    const builtFlags = ZoneFlag.residential | ZoneFlag.commercial | ZoneFlag.retail | ZoneFlag.industrial | ZoneFlag.plaza |
        ZoneFlag.parking | ZoneFlag.campus | ZoneFlag.megaBuilding;
    final roads = t.counts[ZoneCount.roadMeters]![i];
    final built = f & builtFlags != 0 || t.counts[ZoneCount.buildings]![i] > 0 || roads > 20;
    if (!built) return Terrain.grass;
    // A street runs through this bit of town (where sewer grates go).
    return roads > 15 ? Terrain.street : Terrain.urban;
  }

  static const radius = 160.0;
  static const step = 32.0;

  ZoneReading sample(double lat, double lon) {
    if (map.originLat.isNaN || map.tiles.isEmpty) return const ZoneReading({}, false);
    final (cx, cy) = map.toWorld(lat, lon);
    final flagHits = <int, int>{};
    final sums = {for (final c in ZoneCount.values) c: 0};
    var n = 0;
    var empty = 0;
    final seen = <int>{};
    const bits = [
      ZoneFlag.water, ZoneFlag.field, ZoneFlag.park, ZoneFlag.forest, ZoneFlag.beach, ZoneFlag.industrial,
      ZoneFlag.commercial, ZoneFlag.retail, ZoneFlag.residential, ZoneFlag.cemetery, ZoneFlag.railway, ZoneFlag.rock,
      ZoneFlag.parking, ZoneFlag.campus, ZoneFlag.sports, ZoneFlag.plaza, ZoneFlag.megaBuilding, ZoneFlag.themePark,
    ];
    for (var dy = -radius; dy <= radius; dy += step) {
      for (var dx = -radius; dx <= radius; dx += step) {
        if (dx * dx + dy * dy > radius * radius) continue;
        final wx = cx + dx, wy = cy + dy;
        final t = map.tileAtWorld(wx, wy);
        if (t == null) continue;
        final col = ((wx - t.minX) / (t.maxX - t.minX) * kZoneGrid).floor().clamp(0, kZoneGrid - 1);
        final row = ((t.maxY - wy) / (t.maxY - t.minY) * kZoneGrid).floor().clamp(0, kZoneGrid - 1);
        final idx = row * kZoneGrid + col;
        n++;
        final f = t.flags[idx];
        if (f == 0) empty++;
        for (final b in bits) {
          if (f & b != 0) flagHits[b] = (flagHits[b] ?? 0) + 1;
        }
        // Count each cell once.
        final uid = (t.x * 7919 + t.y) * 4096 + idx;
        if (seen.add(uid)) {
          for (final c in ZoneCount.values) {
            sums[c] = sums[c]! + t.counts[c]![idx];
          }
        }
      }
    }
    if (n == 0) return const ZoneReading({}, false);
    double frac(int flag) => (flagHits[flag] ?? 0) / n;
    double c(ZoneCount k) => sums[k]!.toDouble();
    double clamp(double v) => v.clamp(0.0, 1.0);
    final areaHa = n * step * step / 10000;
    final buildingsPerHa = c(ZoneCount.buildings) / areaHa;
    final roadPerHa = c(ZoneCount.roadMeters) / areaHa; // metres of road per hectare

    // Densities per hectare so partial samples (tile edges) stay comparable.
    double d(ZoneCount k) => c(k) / areaHa;
    final urban = clamp(0.45 * clamp((buildingsPerHa - 4) / 12) + 0.35 * clamp((roadPerHa - 80) / 120) +
        0.2 * clamp((frac(ZoneFlag.residential) + frac(ZoneFlag.commercial)) * 1.2));
    final openness = (1 - clamp(buildingsPerHa / 6)) * (1 - clamp(roadPerHa / 140));
    final water = frac(ZoneFlag.water);

    final s = <String, double>{
      // Untagged open land (common for rural farmland in OSM) counts too.
      'country': clamp((frac(ZoneFlag.field) * 1.6 + frac(ZoneFlag.park) * 0.25 + empty / n * 0.75) * openness),
      'hiphop': urban,
      'water': water > 0 ? clamp(0.35 + water * 3) : 0,
      'electronic': clamp(frac(ZoneFlag.industrial) * 2 + d(ZoneCount.industry) / 1.5 + frac(ZoneFlag.megaBuilding) * 1.5 * (1 - frac(ZoneFlag.sports))),
      'rnb': clamp(d(ZoneCount.nightlife) / 1.2 + d(ZoneCount.food) / 12),
      'metal': clamp(frac(ZoneFlag.railway) * 2 + c(ZoneCount.railMeters) / 1500 + frac(ZoneFlag.cemetery) * 2.5 + frac(ZoneFlag.rock) * 2),
      'rock': clamp(c(ZoneCount.highwayMeters) / 900 + frac(ZoneFlag.sports) * 1.6 + frac(ZoneFlag.rock) + d(ZoneCount.music) / 1.2),
      'pop': clamp(frac(ZoneFlag.retail) * 2 + d(ZoneCount.shopping) / 5 + frac(ZoneFlag.commercial) * 0.3),
      'kpop': clamp(d(ZoneCount.kpop) / 3 + frac(ZoneFlag.campus) * 1.6 + frac(ZoneFlag.themePark) * 2.5),
      'latin': clamp(d(ZoneCount.latin) / 1.5 + frac(ZoneFlag.plaza) * 1.5 + frac(ZoneFlag.beach) * 1.5 + d(ZoneCount.soccer)),
      'folk': clamp(frac(ZoneFlag.forest) * 2.2),
      'classical': clamp(d(ZoneCount.culture) / 1.6),
      'soul': clamp(d(ZoneCount.cafe) / 3 + d(ZoneCount.music) / 1.5),
      'reggae': clamp(frac(ZoneFlag.beach) * 3),
    };
    return ZoneReading(s, true);
  }
}
