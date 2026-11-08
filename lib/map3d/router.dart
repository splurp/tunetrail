import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'map_data.dart';

/// Shortest walking route along the road network (A* over road
/// centre-lines from the loaded vector tiles). Coordinates are world metres.
class RoadRouter {
  RoadRouter(this.map);
  final MapData map;

  /// Grid used to merge vertices that are the same OSM node (shared by
  /// connecting roads, or duplicated across tile edges).
  static const _snap = 2.0;

  /// Returns the route from (sx,sy) to (tx,ty) as a flat [x0,y0,x1,y1...]
  /// polyline, starting and ending exactly at those points. Falls back to a
  /// straight line when no road connection is known.
  Float32List route(double sx, double sy, double tx, double ty) {
    final margin = 250.0;
    final minX = math.min(sx, tx) - margin, maxX = math.max(sx, tx) + margin;
    final minY = math.min(sy, ty) - margin, maxY = math.max(sy, ty) + margin;

    final ids = <int, int>{};
    final xs = <double>[], ys = <double>[];
    final adj = <List<int>>[];
    int node(double x, double y) {
      final key = ((x / _snap).round() * 73856093) ^ ((y / _snap).round() * 19349663);
      return ids.putIfAbsent(key, () {
        xs.add(x);
        ys.add(y);
        adj.add(<int>[]);
        return xs.length - 1;
      });
    }

    // Collect road segments inside the search box.
    final seg = <double>[]; // ax, ay, bx, by
    for (final t in map.tiles.values) {
      if (t.maxX < minX || t.minX > maxX || t.maxY < minY || t.minY > maxY) continue;
      for (final line in t.roads) {
        for (var i = 0; i + 3 < line.length; i += 2) {
          final ax = line[i], ay = line[i + 1], bx = line[i + 2], by = line[i + 3];
          if (math.max(ax, bx) < minX || math.min(ax, bx) > maxX || math.max(ay, by) < minY || math.min(ay, by) > maxY) continue;
          if ((ax - bx).abs() + (ay - by).abs() < 0.01) continue;
          seg.addAll([ax, ay, bx, by]);
        }
      }
    }
    final n = seg.length ~/ 4;
    // Vector tiles simplify away shared vertices at many intersections, so
    // split segments wherever they cross (or where one ends on another).
    final splits = List.generate(n, (_) => <double>[0, 1]);
    const cell = 60.0;
    final grid = <int, List<int>>{};
    int key(int cx, int cy) => cx * 100003 + cy;
    for (var i = 0; i < n; i++) {
      final x0 = math.min(seg[i * 4], seg[i * 4 + 2]), x1 = math.max(seg[i * 4], seg[i * 4 + 2]);
      final y0 = math.min(seg[i * 4 + 1], seg[i * 4 + 3]), y1 = math.max(seg[i * 4 + 1], seg[i * 4 + 3]);
      for (var cx = (x0 / cell).floor(); cx <= (x1 / cell).floor(); cx++) {
        for (var cy = (y0 / cell).floor(); cy <= (y1 / cell).floor(); cy++) {
          grid.putIfAbsent(key(cx, cy), () => []).add(i);
        }
      }
    }
    final tested = <int>{};
    for (final bucket in grid.values) {
      for (var a = 0; a < bucket.length; a++) {
        for (var b = a + 1; b < bucket.length; b++) {
          final i = bucket[a], j = bucket[b];
          if (!tested.add(i < j ? i * n + j : j * n + i)) continue;
          _intersect(seg, i, j, splits);
        }
      }
    }
    for (var i = 0; i < n; i++) {
      final ax = seg[i * 4], ay = seg[i * 4 + 1], bx = seg[i * 4 + 2], by = seg[i * 4 + 3];
      final ts = splits[i]..sort();
      int? prev;
      for (final t in ts) {
        final id = node(ax + (bx - ax) * t, ay + (by - ay) * t);
        if (prev != null && prev != id) {
          adj[prev].add(id);
          adj[id].add(prev);
        }
        prev = id;
      }
    }
    if (xs.isEmpty) return Float32List.fromList([sx, sy, tx, ty]);

    int nearest(double x, double y) {
      var best = 0;
      var bd = double.infinity;
      for (var i = 0; i < xs.length; i++) {
        final d = (xs[i] - x) * (xs[i] - x) + (ys[i] - y) * (ys[i] - y);
        if (d < bd) {
          bd = d;
          best = i;
        }
      }
      return best;
    }

    final start = nearest(sx, sy), goal = nearest(tx, ty);
    final g = List<double>.filled(xs.length, double.infinity);
    final from = List<int>.filled(xs.length, -1);
    double h(int i) => math.sqrt((xs[i] - xs[goal]) * (xs[i] - xs[goal]) + (ys[i] - ys[goal]) * (ys[i] - ys[goal]));
    final open = SplayTreeSet<(double, int)>((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    g[start] = 0;
    open.add((h(start), start));
    var found = false;
    while (open.isNotEmpty) {
      final (_, cur) = open.first;
      open.remove(open.first);
      if (cur == goal) {
        found = true;
        break;
      }
      for (final nb in adj[cur]) {
        final d = g[cur] + math.sqrt((xs[nb] - xs[cur]) * (xs[nb] - xs[cur]) + (ys[nb] - ys[cur]) * (ys[nb] - ys[cur]));
        if (d < g[nb]) {
          if (g[nb] != double.infinity) open.remove((g[nb] + h(nb), nb));
          g[nb] = d;
          from[nb] = cur;
          open.add((d + h(nb), nb));
        }
      }
    }
    if (!found) return Float32List.fromList([sx, sy, tx, ty]);
    final path = <int>[];
    for (var c = goal; c != -1; c = from[c]) {
      path.add(c);
    }
    final out = <double>[sx, sy];
    for (final i in path.reversed) {
      out
        ..add(xs[i])
        ..add(ys[i]);
    }
    out
      ..add(tx)
      ..add(ty);
    return Float32List.fromList(out);
  }
}

/// Records where segments i and j cross (or nearly touch at an end, for
/// T-junctions) as split parameters.
void _intersect(List<double> s, int i, int j, List<List<double>> splits) {
  final ax = s[i * 4], ay = s[i * 4 + 1], bx = s[i * 4 + 2], by = s[i * 4 + 3];
  final cx = s[j * 4], cy = s[j * 4 + 1], dx = s[j * 4 + 2], dy = s[j * 4 + 3];
  final rx = bx - ax, ry = by - ay, qx = dx - cx, qy = dy - cy;
  final den = rx * qy - ry * qx;
  if (den.abs() > 1e-9) {
    final t = ((cx - ax) * qy - (cy - ay) * qx) / den;
    final u = ((cx - ax) * ry - (cy - ay) * rx) / den;
    if (t >= -0.001 && t <= 1.001 && u >= -0.001 && u <= 1.001) {
      splits[i].add(t.clamp(0.0, 1.0));
      splits[j].add(u.clamp(0.0, 1.0));
      return;
    }
  }
  // T-junction: an endpoint of one segment lying within 4 m of the other.
  void endOn(double px, double py, int seg, double sx0, double sy0, double sx1, double sy1, int other, bool otherStart) {
    final vx = sx1 - sx0, vy = sy1 - sy0;
    final l2 = vx * vx + vy * vy;
    if (l2 < 1e-6) return;
    final t = (((px - sx0) * vx + (py - sy0) * vy) / l2).clamp(0.0, 1.0);
    final ex = sx0 + vx * t - px, ey = sy0 + vy * t - py;
    if (ex * ex + ey * ey < 16) {
      splits[seg].add(t);
      splits[other].add(otherStart ? 0 : 1);
    }
  }

  endOn(cx, cy, i, ax, ay, bx, by, j, true);
  endOn(dx, dy, i, ax, ay, bx, by, j, false);
  endOn(ax, ay, j, cx, cy, dx, dy, i, true);
  endOn(bx, by, j, cx, cy, dx, dy, i, false);
}

/// Footprints placed along a polyline: (x, y, angle radians, isLeft).
List<(double, double, double, bool)> footprintsAlong(Float32List path, {double spacing = 9, double side = 2.0}) {
  final out = <(double, double, double, bool)>[];
  var carry = spacing * 0.5;
  var left = true;
  for (var i = 0; i + 3 < path.length; i += 2) {
    final ax = path[i], ay = path[i + 1], bx = path[i + 2], by = path[i + 3];
    final dx = bx - ax, dy = by - ay;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.01) continue;
    final ux = dx / len, uy = dy / len;
    var d = carry;
    while (d < len) {
      final px = ax + ux * d, py = ay + uy * d;
      final s = left ? side : -side;
      // Left of travel direction = (-uy, ux).
      out.add((px - uy * s, py + ux * s, math.atan2(ux, uy), left));
      left = !left;
      d += spacing;
    }
    carry = d - len;
  }
  return out;
}
