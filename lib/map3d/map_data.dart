import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'buildings3d.dart';
import 'tile_data.dart';

/// Streams the vector-tile world around the player.
///
/// Tiles come from free, key-less OpenStreetMap vector tile services
/// (Shortbread schema), are cached on disk, and are converted in a
/// background isolate into ground triangles + a genre-zone grid.
class MapData extends ChangeNotifier {
  MapData(this.cacheDir);
  final Directory cacheDir;

  static const sources = [
    'https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}',
  ];

  double originLat = double.nan, originLon = double.nan;
  final Map<String, WorldTile> tiles = {};

  // ---- Optional city buildings (OpenFreeMap, OpenMapTiles schema).
  bool _buildingsEnabled = false;
  bool get buildingsEnabled => _buildingsEnabled;
  final Map<String, CityBuildingTile> buildingTiles = {};
  final Set<String> _bLoading = {}, _bFailed = {};
  String? _ofmTemplate;

  set buildingsEnabled(bool on) {
    if (on == _buildingsEnabled) return;
    _buildingsEnabled = on;
    if (!on) buildingTiles.clear();
    version++;
    notifyListeners();
  }

  Future<String?> _ofm() async {
    if (_ofmTemplate != null) return _ofmTemplate;
    try {
      final res = await _client.get(Uri.parse('https://tiles.openfreemap.org/planet')).timeout(const Duration(seconds: 15));
      final m = RegExp(r'"tiles"\s*:\s*\[\s*"([^"]+)"').firstMatch(res.body);
      return _ofmTemplate = m?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadBuildings(int z, int x, int y) async {
    final key = '$z/$x/$y';
    _bLoading.add(key);
    try {
      final f = File('${cacheDir.path}/ofm-$z-$x-$y.pbf');
      Uint8List? bytes;
      if (await f.exists()) {
        bytes = await f.readAsBytes();
      } else {
        final t = await _ofm();
        if (t == null) throw StateError('no OpenFreeMap tilejson');
        final res = await _client
            .get(Uri.parse(t.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y')), headers: {'User-Agent': 'Tunetrail/0.2'})
            .timeout(const Duration(seconds: 25));
        if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
        bytes = res.bodyBytes;
        await f.writeAsBytes(bytes, flush: true);
      }
      final lat0 = originLat;
      final tile = await compute(processBuildingTile, TileJob(z, x, y, bytes, originLat, originLon));
      if (lat0 != originLat || !_buildingsEnabled) return;
      buildingTiles[key] = tile;
      version++;
      notifyListeners();
    } catch (e) {
      debugPrint('buildings $key: $e');
      _bFailed.add(key);
      Timer(const Duration(seconds: 30), () => _bFailed.remove(key));
    } finally {
      _bLoading.remove(key);
    }
  }
  final Set<String> _loading = {};
  final Set<String> _failed = {};
  final http.Client _client = http.Client();
  int version = 0;
  String? lastError;

  static const _mPerDegLat = 111132.95;
  double get _mPerDegLon => 111319.49 * math.cos(originLat * math.pi / 180);

  /// World metres (relative to origin) for a coordinate.
  (double, double) toWorld(double lat, double lon) {
    if (originLat.isNaN) return (0, 0);
    return ((lon - originLon) * _mPerDegLon, (lat - originLat) * _mPerDegLat);
  }

  (double, double) toLatLon(double x, double y) => (originLat + y / _mPerDegLat, originLon + x / _mPerDegLon);

  /// Ensures tiles within [radius] metres of the player are loaded. Resets
  /// the origin when the player has moved very far (teleport).
  void ensureAround(double lat, double lon, {double radius = 900}) {
    if (originLat.isNaN || (lat - originLat).abs() > 0.25 || (lon - originLon).abs() > 0.3) {
      originLat = lat;
      originLon = lon;
      tiles.clear();
      buildingTiles.clear();
      _loading.clear();
      _failed.clear();
      version++;
      notifyListeners();
    }
    final dLat = radius / _mPerDegLat, dLon = radius / _mPerDegLon;
    final (x0, y0) = tileFor(lat + dLat, lon - dLon, kTileZoom);
    final (x1, y1) = tileFor(lat - dLat, lon + dLon, kTileZoom);
    final wanted = <String>{};
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final key = '$kTileZoom/$x/$y';
        wanted.add(key);
        if (!tiles.containsKey(key) && !_loading.contains(key) && !_failed.contains(key)) {
          _load(kTileZoom, x, y);
        }
        if (_buildingsEnabled && !buildingTiles.containsKey(key) && !_bLoading.contains(key) && !_bFailed.contains(key)) {
          _loadBuildings(kTileZoom, x, y);
        }
      }
    }
    // Drop tiles that are far away (memory).
    if (tiles.length > 16) {
      tiles.removeWhere((k, _) => !wanted.contains(k));
      buildingTiles.removeWhere((k, _) => !wanted.contains(k));
    }
  }

  Future<void> _load(int z, int x, int y) async {
    final key = '$z/$x/$y';
    _loading.add(key);
    try {
      final f = File('${cacheDir.path}/$z-$x-$y.mvt');
      Uint8List? bytes;
      if (await f.exists()) {
        bytes = await f.readAsBytes();
      } else {
        for (final s in sources) {
          final url = s.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');
          try {
            final res = await _client.get(Uri.parse(url), headers: {'User-Agent': 'Tunetrail/0.2'}).timeout(const Duration(seconds: 25));
            if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
              bytes = res.bodyBytes;
              break;
            }
            if (res.statusCode == 204 || res.statusCode == 404) {
              bytes = Uint8List(0);
              break;
            }
          } catch (e) {
            lastError = '$e';
          }
        }
        if (bytes != null && bytes.isNotEmpty) await f.writeAsBytes(bytes, flush: true);
      }
      if (bytes == null) {
        _failed.add(key);
        Timer(const Duration(seconds: 20), () => _failed.remove(key));
        return;
      }
      final job = TileJob(z, x, y, bytes, originLat, originLon);
      final lat0 = originLat;
      final tile = await compute(processTile, job);
      if (lat0 != originLat) return; // origin changed while processing
      tiles[key] = tile;
      version++;
      notifyListeners();
    } catch (e) {
      lastError = '$e';
      debugPrint('tile $key failed: $e');
      _failed.add(key);
      Timer(const Duration(seconds: 30), () => _failed.remove(key));
    } finally {
      _loading.remove(key);
    }
  }

  bool get isLoading => _loading.isNotEmpty;

  static bool _inRing(Float32List ring, double x, double y) {
    var inside = false;
    final n = ring.length ~/ 2;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = ring[i * 2], yi = ring[i * 2 + 1], xj = ring[j * 2], yj = ring[j * 2 + 1];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  }

  static bool _tileHas(CityBuildingTile t, double x, double y, double margin) {
    if (t.cols == 0) return false;
    const cs = CityBuildingTile.cell;
    final c = ((x - t.minX) / cs).floor(), r = ((y - t.minY) / cs).floor();
    for (var rr = r - 1; rr <= r + 1; rr++) {
      if (rr < 0 || rr >= t.rows) continue;
      for (var cc = c - 1; cc <= c + 1; cc++) {
        if (cc < 0 || cc >= t.cols) continue;
        for (final b in t.grid[rr * t.cols + cc]) {
          final dx = x - b.cx, dy = y - b.cy;
          final reach = b.radius + margin;
          if (dx * dx + dy * dy > reach * reach) continue;
          if (_inRing(b.ring, x, y)) return true;
          if (margin > 0) {
            for (final (ox, oy) in const [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)]) {
              if (_inRing(b.ring, x + ox * margin, y + oy * margin)) return true;
            }
          }
        }
      }
    }
    return false;
  }

  /// Whether a world point (or anything within [margin] metres of it) is
  /// inside a building that's drawn on the map.
  bool insideBuilding(double x, double y, {double margin = 0}) {
    for (final t in buildingTiles.values) {
      if (_tileHas(t, x, y, margin)) return true;
    }
    for (final t in tiles.values) {
      if (x < t.minX - 60 || x > t.maxX + 60 || y < t.minY - 60 || y > t.maxY + 60) continue;
      if (_tileHas(t.buildingTile, x, y, margin)) return true;
    }
    return false;
  }

  /// Whether a world point lies on water (a river, lake or sea), by the
  /// map's actual water shapes.
  bool inWater(double x, double y) {
    final t = tileAtWorld(x, y);
    if (t == null) return false;
    final tris = t.layers[GroundLayer.water], buckets = t.buckets[GroundLayer.water];
    if (tris == null || buckets == null) return false;
    for (var bi = 0; bi + 5 < buckets.length; bi += 6) {
      if (x < buckets[bi + 2] || y < buckets[bi + 3] || x > buckets[bi + 4] || y > buckets[bi + 5]) continue;
      final end = buckets[bi + 1].toInt();
      for (var i = buckets[bi].toInt(); i + 6 <= end && i + 6 <= tris.length; i += 6) {
        final ax = tris[i], ay = tris[i + 1], bx = tris[i + 2], by = tris[i + 3], cx = tris[i + 4], cy = tris[i + 5];
        final d1 = (x - bx) * (ay - by) - (ax - bx) * (y - by);
        final d2 = (x - cx) * (by - cy) - (bx - cx) * (y - cy);
        final d3 = (x - ax) * (cy - ay) - (cx - ax) * (y - ay);
        final neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0;
        if (!(neg && pos)) return true;
      }
    }
    return false;
  }

  /// The nearest point on a road to a world point, with the road's
  /// direction there (unit vector), within [within] metres.
  (double, double, double, double)? nearestRoad(double x, double y, {double within = 45}) {
    final t = tileAtWorld(x, y);
    if (t == null) return null;
    var best = within * within;
    (double, double, double, double)? out;
    for (final line in t.roads) {
      for (var i = 0; i + 3 < line.length; i += 2) {
        final ax = line[i], ay = line[i + 1], bx = line[i + 2], by = line[i + 3];
        if ((ax < x - within && bx < x - within) || (ax > x + within && bx > x + within) || (ay < y - within && by < y - within) || (ay > y + within && by > y + within)) {
          continue;
        }
        final dx = bx - ax, dy = by - ay;
        final l2 = dx * dx + dy * dy;
        if (l2 < 1e-6) continue;
        final u = (((x - ax) * dx + (y - ay) * dy) / l2).clamp(0.0, 1.0);
        final qx = ax + dx * u, qy = ay + dy * u;
        final d2 = (qx - x) * (qx - x) + (qy - y) * (qy - y);
        if (d2 < best) {
          best = d2;
          final l = math.sqrt(l2);
          out = (qx, qy, dx / l, dy / l);
        }
      }
    }
    return out;
  }

  /// Tile containing a world point, if loaded.
  WorldTile? tileAtWorld(double wx, double wy) {
    for (final t in tiles.values) {
      if (wx >= t.minX && wx < t.maxX && wy >= t.minY && wy < t.maxY) return t;
    }
    return null;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
