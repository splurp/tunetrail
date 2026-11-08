import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
      }
    }
    // Drop tiles that are far away (memory).
    if (tiles.length > 16) {
      tiles.removeWhere((k, _) => !wanted.contains(k));
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
