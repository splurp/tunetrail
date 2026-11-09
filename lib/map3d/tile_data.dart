import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_earcut/dart_earcut.dart';

import 'buildings3d.dart';
import 'mvt.dart';

/// Zoom level of the vector tiles used for the world (≈1.8 km tiles at
/// mid latitudes; each contains every road, park, lot and POI we need).
const int kTileZoom = 14;

/// Ground layers, in draw order.
enum GroundLayer { field, forest, park, sand, campus, parking, plaza, water, roadMinor, roadMajor, roadHighway }

/// Land-feel flags stored per zone cell.
abstract final class ZoneFlag {
  static const water = 1 << 0;
  static const field = 1 << 1;
  static const park = 1 << 2;
  static const forest = 1 << 3;
  static const beach = 1 << 4;
  static const industrial = 1 << 5;
  static const commercial = 1 << 6;
  static const retail = 1 << 7;
  static const residential = 1 << 8;
  static const cemetery = 1 << 9;
  static const railway = 1 << 10;
  static const rock = 1 << 11; // quarry, scree, bare rock, cliffs
  static const parking = 1 << 12;
  static const campus = 1 << 13; // school, college, university
  static const sports = 1 << 14; // stadium, pitch, sports centre
  static const plaza = 1 << 15; // pedestrian squares
  static const megaBuilding = 1 << 16;
  static const themePark = 1 << 17;
}

/// Per-cell counters stored in the zone grid.
enum ZoneCount {
  roadMeters, // all drivable roads
  highwayMeters, // motorway / trunk
  railMeters,
  buildings,
  nightlife, // bar, pub, nightclub, lounge, hookah
  food, // restaurants, fast food
  cafe,
  shopping, // shops, malls, cinemas
  culture, // worship, museum, theatre, arts centre, concert hall
  music, // music venues, music schools, instrument shops
  kpop, // karaoke, arcades, korean food, k-beauty, theme parks
  latin, // latin-american cuisine, dance schools, markets
  industry, // works, factories, data centres, warehouses
  soccer,
}

/// Resolution of the zone grid within a tile.
const int kZoneGrid = 64;

/// A processed world tile: ready-to-draw ground triangles in world metres
/// (relative to the map origin), mega-buildings, and the genre-zone grid.
class WorldTile {
  WorldTile({
    required this.z,
    required this.x,
    required this.y,
    required this.layers,
    required this.buckets,
    required this.buildings,
    required this.roads,
    required this.flags,
    required this.counts,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final int z, x, y;

  /// Triangles per layer: [x0,y0,x1,y1,x2,y2, ...] in metres.
  final Map<GroundLayer, Float32List> layers;

  /// Spatial buckets for culling: per layer, a list of (start,end,bbox)
  /// ranges into the triangle array, as [start, end, minX, minY, maxX, maxY].
  final Map<GroundLayer, Float32List> buckets;

  /// Big landmark buildings from the base map (drawn when the full city
  /// buildings layer is off), in the same form as city buildings.
  final List<CityBuilding> buildings;

  late final CityBuildingTile buildingTile = CityBuildingTile(buildings);

  /// Walkable road centre-lines [x0,y0,x1,y1,...] in metres (for routing).
  final List<Float32List> roads;

  /// Zone grid (kZoneGrid²): flags and counters, row-major from the tile's
  /// north-west corner.
  final Uint32List flags;
  final Map<ZoneCount, Uint16List> counts;

  /// World-metre bounds of the tile.
  final double minX, minY, maxX, maxY;

  String get key => '$z/$x/$y';
}


/// Input for [processTile] (sent to a background isolate).
class TileJob {
  TileJob(this.z, this.x, this.y, this.bytes, this.originLat, this.originLon);
  final int z, x, y;
  final Uint8List bytes;
  final double originLat, originLon;
}

const _wantedLayers = {
  'streets', 'street_polygons', 'land', 'water_polygons', 'ocean', 'water_lines',
  'sites', 'buildings', 'pois', 'bridges',
};

/// Minimum footprint for a building to be drawn ("mega" buildings only:
/// stadiums, terminals, factories, malls...).
const double kMegaBuildingArea = 9000;

WorldTile processTile(TileJob j) {
  final layers = decodeMvt(j.bytes, wanted: _wantedLayers);
  final n = 1 << j.z;
  final cosLat0 = math.cos(j.originLat * math.pi / 180);
  const mPerDegLat = 111132.95;
  final mPerDegLon = 111319.49 * cosLat0;

  // Tile → world metres. Latitude is non-linear in y; precompute per-unit.
  double lonOf(double px, int ext) => (j.x + px / ext) / n * 360 - 180;
  double latOf(double py, int ext) {
    final t = math.pi * (1 - 2 * (j.y + py / ext) / n);
    return math.atan((math.exp(t) - math.exp(-t)) / 2) * 180 / math.pi;
  }

  double wx(double px, int ext) => (lonOf(px, ext) - j.originLon) * mPerDegLon;
  double wy(double py, int ext) => (latOf(py, ext) - j.originLat) * mPerDegLat;

  final out = <GroundLayer, List<double>>{for (final l in GroundLayer.values) l: <double>[]};
  final buildings = <CityBuilding>[];
  final roads = <Float32List>[];
  final flags = Uint32List(kZoneGrid * kZoneGrid);
  final counts = {for (final c in ZoneCount.values) c: Uint16List(kZoneGrid * kZoneGrid)};

  var ext = 4096;
  // Cached y conversion for speed (tile units → metres) at 1-unit steps.
  final yCache = <int, Float64List>{};
  Float64List yTable(int e) => yCache.putIfAbsent(e, () {
        final t = Float64List(e + 129 + 128);
        for (var i = 0; i < t.length; i++) {
          t[i] = wy((i - 128).toDouble(), e);
        }
        return t;
      });
  final x0 = wx(0, ext);
  late double mPerUnitX;
  late Float64List yt;

  void setExtent(int e) {
    ext = e;
    mPerUnitX = (wx(e.toDouble(), e) - wx(0, e)) / e;
    yt = yTable(e);
  }

  setExtent(4096);
  double mx(double px) => x0 + px * mPerUnitX;
  double my(double py) {
    final i = py.floor();
    final idx = (i + 128).clamp(0, yt.length - 2);
    final f = py - i;
    return yt[idx] + (yt[idx + 1] - yt[idx]) * f;
  }

  Float32List toMeters(Float32List ring) {
    final r = Float32List(ring.length);
    for (var i = 0; i < ring.length; i += 2) {
      r[i] = mx(ring[i]);
      r[i + 1] = my(ring[i + 1]);
    }
    return r;
  }

  void addPolygon(GroundLayer layer, List<Float32List> rings) {
    final verts = <double>[];
    final holes = <int>[];
    for (var k = 0; k < rings.length; k++) {
      if (k > 0) holes.add(verts.length ~/ 2);
      final m = toMeters(rings[k]);
      // Drop the closing duplicate point if present.
      var len = m.length;
      if (len >= 4 && m[0] == m[len - 2] && m[1] == m[len - 1]) len -= 2;
      for (var i = 0; i < len; i++) {
        verts.add(m[i]);
      }
    }
    if (verts.length < 6) return;
    final idx = Earcut.triangulateRaw(verts, holeIndices: holes.isEmpty ? null : holes);
    final o = out[layer]!;
    for (final i in idx) {
      o.add(verts[i * 2]);
      o.add(verts[i * 2 + 1]);
    }
  }

  // ------------------------------------------------------------ zone grid
  double cell() => ext / kZoneGrid;

  void rasterPolygon(List<Float32List> rings, int flag) {
    final cs = cell();
    final xs = <double>[];
    for (var row = 0; row < kZoneGrid; row++) {
      final yc = (row + 0.5) * cs;
      xs.clear();
      for (final r in rings) {
        final cnt = r.length ~/ 2;
        for (var i = 0, k = cnt - 1; i < cnt; k = i++) {
          final yi = r[i * 2 + 1], yk = r[k * 2 + 1];
          if ((yi > yc) != (yk > yc)) {
            xs.add(r[i * 2] + (yc - yi) / (yk - yi) * (r[k * 2] - r[i * 2]));
          }
        }
      }
      if (xs.length < 2) continue;
      xs.sort();
      for (var p = 0; p + 1 < xs.length; p += 2) {
        final c0 = math.max(0, ((xs[p] / cs) - 0.5).ceil());
        final c1 = math.min(kZoneGrid - 1, ((xs[p + 1] / cs) - 0.5).floor());
        for (var c = c0; c <= c1; c++) {
          flags[row * kZoneGrid + c] |= flag;
        }
      }
    }
  }

  int? cellAt(double px, double py) {
    final cs = cell();
    final c = (px / cs).floor(), r = (py / cs).floor();
    if (c < 0 || r < 0 || c >= kZoneGrid || r >= kZoneGrid) return null;
    return r * kZoneGrid + c;
  }

  void bump(ZoneCount k, double px, double py, [int amount = 1]) {
    final i = cellAt(px, py);
    if (i == null) return;
    final a = counts[k]!;
    a[i] = math.min(65535, a[i] + amount);
  }

  void rasterLine(Float32List line, ZoneCount k, {int flag = 0}) {
    final step = cell() / 2;
    final mPerUnit = mPerUnitX.abs();
    for (var i = 0; i + 3 < line.length; i += 2) {
      final ax = line[i], ay = line[i + 1], bx = line[i + 2], by = line[i + 3];
      final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
      final steps = math.max(1, (len / step).ceil());
      for (var s = 0; s < steps; s++) {
        final t = (s + 0.5) / steps;
        final px = ax + (bx - ax) * t, py = ay + (by - ay) * t;
        bump(k, px, py, math.max(1, (len / steps * mPerUnit).round()));
        if (flag != 0) {
          final ci = cellAt(px, py);
          if (ci != null) flags[ci] |= flag;
        }
      }
    }
  }

  // --------------------------------------------------------------- roads
  void addRoad(GroundLayer layer, Float32List line, double width) {
    final m = toMeters(line);
    if (layer != GroundLayer.water) roads.add(m);
    final o = out[layer]!;
    final hw = width / 2;
    var px = m[0], py = m[1];
    _cap(o, px, py, hw);
    for (var i = 2; i + 1 < m.length; i += 2) {
      final qx = m[i], qy = m[i + 1];
      final dx = qx - px, dy = qy - py;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 0.5) continue;
      final nx = -dy / len * hw, ny = dx / len * hw;
      o.addAll([px + nx, py + ny, qx + nx, qy + ny, qx - nx, qy - ny]);
      o.addAll([px + nx, py + ny, qx - nx, qy - ny, px - nx, py - ny]);
      _cap(o, qx, qy, hw);
      px = qx;
      py = qy;
    }
  }

  // --------------------------------------------------------------- decode
  for (final layer in layers) {
    setExtent(layer.extent);
    switch (layer.name) {
      case 'ocean':
      case 'water_polygons':
        for (final f in layer.features) {
          if (f.type != MvtGeomType.polygon) continue;
          for (final p in groupRings(f.geometry)) {
            addPolygon(GroundLayer.water, p);
            rasterPolygon(p, ZoneFlag.water);
          }
        }
      case 'water_lines':
        for (final f in layer.features) {
          final kind = f.str('kind');
          final w = switch (kind) { 'river' => 18.0, 'canal' => 12.0, 'stream' => 4.0, _ => 0.0 };
          if (w == 0 || f.tags['tunnel'] == true) continue;
          for (final part in f.geometry) {
            if (part.length < 4) continue;
            addRoad(GroundLayer.water, part, w);
            rasterLine(part, ZoneCount.roadMeters, flag: ZoneFlag.water);
          }
        }
      case 'land':
        for (final f in layer.features) {
          if (f.type != MvtGeomType.polygon) continue;
          final kind = f.str('kind') ?? '';
          final (GroundLayer? gl, int flag) = switch (kind) {
            'farmland' || 'meadow' || 'grassland' || 'orchard' || 'vineyard' || 'greenfield' || 'farmyard' || 'heath' || 'scrub' || 'plant_nursery' =>
              (GroundLayer.field, ZoneFlag.field),
            'forest' || 'wood' => (GroundLayer.forest, ZoneFlag.forest),
            'park' || 'garden' || 'grass' || 'recreation_ground' || 'village_green' || 'playground' || 'allotments' || 'golf_course' || 'dog_park' =>
              (GroundLayer.park, ZoneFlag.park),
            'beach' || 'sand' => (GroundLayer.sand, ZoneFlag.beach),
            'cemetery' || 'grave_yard' => (GroundLayer.park, ZoneFlag.cemetery),
            'industrial' || 'brownfield' => (null, ZoneFlag.industrial),
            'commercial' => (null, ZoneFlag.commercial),
            'retail' => (null, ZoneFlag.retail),
            'residential' => (null, ZoneFlag.residential),
            'railway' => (null, ZoneFlag.railway),
            'quarry' || 'scree' || 'bare_rock' || 'shingle' => (GroundLayer.sand, ZoneFlag.rock),
            'stadium' || 'pitch' || 'track' || 'sports_centre' => (GroundLayer.park, ZoneFlag.sports),
            'theme_park' || 'zoo' => (GroundLayer.park, ZoneFlag.themePark),
            'swamp' || 'bog' || 'marsh' || 'wet_meadow' => (GroundLayer.field, ZoneFlag.water),
            _ => (null, 0),
          };
          for (final p in groupRings(f.geometry)) {
            if (gl != null) addPolygon(gl, p);
            if (flag != 0) rasterPolygon(p, flag);
          }
        }
      case 'sites':
        for (final f in layer.features) {
          if (f.type != MvtGeomType.polygon) continue;
          final kind = f.str('kind') ?? '';
          final (GroundLayer? gl, int flag) = switch (kind) {
            'parking' => (GroundLayer.parking, ZoneFlag.parking),
            'school' || 'university' || 'college' || 'kindergarten' => (GroundLayer.campus, ZoneFlag.campus),
            'sports_centre' || 'stadium' => (GroundLayer.park, ZoneFlag.sports),
            _ => (null, 0),
          };
          for (final p in groupRings(f.geometry)) {
            if (gl != null) addPolygon(gl, p);
            if (flag != 0) rasterPolygon(p, flag);
          }
        }
      case 'street_polygons':
        for (final f in layer.features) {
          if (f.type != MvtGeomType.polygon || f.str('kind') != 'pedestrian') continue;
          for (final p in groupRings(f.geometry)) {
            addPolygon(GroundLayer.plaza, p);
            rasterPolygon(p, ZoneFlag.plaza);
          }
        }
      case 'streets':
        for (final f in layer.features) {
          if (f.type != MvtGeomType.line || f.tags['tunnel'] == true) continue;
          final kind = f.str('kind') ?? '';
          if (kind == 'rail' || kind == 'light_rail' || kind == 'narrow_gauge') {
            for (final part in f.geometry) {
              rasterLine(part, ZoneCount.railMeters, flag: ZoneFlag.railway);
            }
            continue;
          }
          final service = f.str('service');
          final (GroundLayer? gl, double w) = switch (kind) {
            'motorway' || 'trunk' => (GroundLayer.roadHighway, 16.0),
            'motorway_link' || 'trunk_link' => (GroundLayer.roadHighway, 8.0),
            'primary' => (GroundLayer.roadMajor, 13.0),
            'secondary' => (GroundLayer.roadMajor, 11.0),
            'tertiary' => (GroundLayer.roadMajor, 9.5),
            'primary_link' || 'secondary_link' || 'tertiary_link' => (GroundLayer.roadMajor, 7.0),
            'unclassified' || 'residential' || 'living_street' => (GroundLayer.roadMinor, 7.0),
            'pedestrian' => (GroundLayer.roadMinor, 5.0),
            'track' => (GroundLayer.roadMinor, 3.5),
            // Generic service roads only — no driveways, parking aisles…
            'service' when service == null || service == 'alley' => (GroundLayer.roadMinor, 4.5),
            _ => (null, 0.0),
          };
          if (gl == null) continue;
          for (final part in f.geometry) {
            if (part.length < 4) continue;
            addRoad(gl, part, w);
            rasterLine(part, gl == GroundLayer.roadHighway ? ZoneCount.highwayMeters : ZoneCount.roadMeters);
          }
        }
      case 'buildings':
        for (final f in layer.features) {
          if (f.type != MvtGeomType.polygon) continue;
          for (final p in groupRings(f.geometry)) {
            final outer = p.first;
            // Building centroid for density.
            var cx = 0.0, cy = 0.0;
            final cnt = outer.length ~/ 2;
            for (var i = 0; i < cnt; i++) {
              cx += outer[i * 2];
              cy += outer[i * 2 + 1];
            }
            bump(ZoneCount.buildings, cx / cnt, cy / cnt);
            final m = toMeters(outer);
            final area = ringArea(m).abs();
            if (area < kMegaBuildingArea) continue;
            rasterPolygon([outer], ZoneFlag.megaBuilding);
            // Real heights where the map has them (no more 30 m cap).
            final h = (f.number('render_height') ?? f.number('height') ?? 15).clamp(6, 600).toDouble();
            final verts = <double>[];
            var len = m.length;
            if (m[0] == m[len - 2] && m[1] == m[len - 1]) len -= 2;
            for (var i = 0; i < len; i++) {
              verts.add(m[i]);
            }
            final b = cityBuildingFromOutline(verts, h);
            if (b != null) buildings.add(b);
            if (area > 20000) {
              final ci = cellAt(cx / cnt, cy / cnt);
              if (ci != null) counts[ZoneCount.industry]![ci] += 1;
            }
          }
        }
      case 'pois':
        for (final f in layer.features) {
          if (f.geometry.isEmpty) continue;
          final px = f.geometry.first[0], py = f.geometry.first[1];
          final amenity = f.str('amenity') ?? '';
          final shop = f.str('shop') ?? '';
          final tourism = f.str('tourism') ?? '';
          final leisure = f.str('leisure') ?? '';
          final cuisine = f.str('cuisine') ?? '';
          final manMade = f.str('man_made') ?? '';
          final sport = f.str('sport') ?? '';
          switch (amenity) {
            case 'bar' || 'pub' || 'nightclub' || 'biergarten' || 'hookah_lounge' || 'stripclub':
              bump(ZoneCount.nightlife, px, py);
            case 'restaurant' || 'fast_food' || 'food_court':
              bump(ZoneCount.food, px, py);
            case 'cafe' || 'ice_cream':
              bump(ZoneCount.cafe, px, py);
            case 'place_of_worship' || 'theatre' || 'arts_centre' || 'library' || 'concert_hall' || 'planetarium':
              bump(ZoneCount.culture, px, py);
            case 'music_venue' || 'music_school' || 'studio':
              bump(ZoneCount.music, px, py);
            case 'karaoke_box':
              bump(ZoneCount.kpop, px, py, 3);
            case 'cinema':
              bump(ZoneCount.shopping, px, py, 2);
            case 'marketplace':
              bump(ZoneCount.latin, px, py, 2);
            case 'school' || 'university' || 'college':
              bump(ZoneCount.kpop, px, py);
          }
          if (shop.isNotEmpty) {
            bump(ZoneCount.shopping, px, py, shop == 'mall' || shop == 'department_store' ? 6 : 1);
            if (shop == 'musical_instrument' || shop == 'music') bump(ZoneCount.music, px, py, 2);
            if (shop == 'cosmetics' || shop == 'anime' || shop == 'games' || shop == 'video_games') bump(ZoneCount.kpop, px, py);
          }
          if (tourism == 'museum' || tourism == 'gallery') bump(ZoneCount.culture, px, py);
          if (tourism == 'theme_park') bump(ZoneCount.kpop, px, py, 6);
          if (leisure == 'amusement_arcade') bump(ZoneCount.kpop, px, py, 3);
          if (leisure == 'dance') bump(ZoneCount.latin, px, py, 3);
          if (leisure == 'stadium') bump(ZoneCount.music, px, py, 2);
          if (sport.contains('soccer')) bump(ZoneCount.soccer, px, py, 2);
          if (cuisine.contains('korean')) bump(ZoneCount.kpop, px, py, 2);
          if (cuisine.contains('mexican') || cuisine.contains('latin') || cuisine.contains('brazilian') || cuisine.contains('peruvian') ||
              cuisine.contains('cuban') || cuisine.contains('colombian') || cuisine.contains('spanish') || cuisine.contains('argentin') ||
              cuisine.contains('puerto') || cuisine.contains('dominican') || cuisine.contains('tacos')) {
            bump(ZoneCount.latin, px, py, 2);
          }
          if (manMade == 'works' || manMade == 'chimney' || manMade == 'storage_tank' || manMade == 'gasometer' ||
              f.str('telecom') == 'data_center' || f.str('power') == 'plant' || f.str('industrial') != null) {
            bump(ZoneCount.industry, px, py, 3);
          }
        }
    }
  }

  // ------------------------------------------------------------- buckets
  setExtent(4096);
  final minX = mx(0), maxX = mx(4096);
  final maxY = my(0), minY = my(4096);
  final layerArrays = <GroundLayer, Float32List>{};
  final bucketArrays = <GroundLayer, Float32List>{};
  for (final e in out.entries) {
    if (e.value.isEmpty) continue;
    final (tris, buckets) = _bucketize(e.value, minX, minY, maxX, maxY);
    layerArrays[e.key] = tris;
    bucketArrays[e.key] = buckets;
  }
  return WorldTile(
    z: j.z,
    x: j.x,
    y: j.y,
    layers: layerArrays,
    buckets: bucketArrays,
    buildings: buildings,
    roads: roads,
    flags: flags,
    counts: counts,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
  );
}

void _cap(List<double> o, double x, double y, double r) {
  const n = 8;
  for (var i = 0; i < n; i++) {
    final a0 = i * 2 * math.pi / n, a1 = (i + 1) * 2 * math.pi / n;
    o.addAll([x, y, x + math.cos(a0) * r, y + math.sin(a0) * r, x + math.cos(a1) * r, y + math.sin(a1) * r]);
  }
}

/// Sorts triangles into an 8×8 grid of buckets so the renderer can skip
/// whole regions that are off-screen.
(Float32List, Float32List) _bucketize(List<double> tris, double minX, double minY, double maxX, double maxY) {
  const g = 8;
  final w = (maxX - minX) / g, h = (maxY - minY) / g;
  final lists = List.generate(g * g, (_) => <double>[]);
  for (var i = 0; i + 5 < tris.length; i += 6) {
    final cx = (tris[i] + tris[i + 2] + tris[i + 4]) / 3;
    final cy = (tris[i + 1] + tris[i + 3] + tris[i + 5]) / 3;
    final bx = ((cx - minX) / w).floor().clamp(0, g - 1);
    final by = ((cy - minY) / h).floor().clamp(0, g - 1);
    lists[by * g + bx].addAll(tris.sublist(i, i + 6));
  }
  final total = tris.length - tris.length % 6;
  final outTris = Float32List(total);
  final buckets = <double>[];
  var pos = 0;
  for (final l in lists) {
    if (l.isEmpty) continue;
    var bx0 = double.infinity, by0 = double.infinity, bx1 = -double.infinity, by1 = -double.infinity;
    for (var i = 0; i + 1 < l.length; i += 2) {
      bx0 = math.min(bx0, l[i]);
      bx1 = math.max(bx1, l[i]);
      by0 = math.min(by0, l[i + 1]);
      by1 = math.max(by1, l[i + 1]);
    }
    outTris.setRange(pos, pos + l.length, l);
    buckets.addAll([pos.toDouble(), (pos + l.length).toDouble(), bx0, by0, bx1, by1]);
    pos += l.length;
  }
  return (outTris, Float32List.fromList(buckets));
}

/// Web-mercator tile containing a coordinate.
(int, int) tileFor(double lat, double lon, int z) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor();
  final latR = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(latR) + 1 / math.cos(latR)) / math.pi) / 2 * n).floor();
  return (x.clamp(0, n - 1), y.clamp(0, n - 1));
}
