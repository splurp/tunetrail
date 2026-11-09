import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dart_earcut/dart_earcut.dart';
import 'package:flutter/material.dart';

import 'camera.dart';
import 'mvt.dart';
import 'palette.dart';
import 'tile_data.dart';

/// One extruded city building (world metres relative to the map origin).
class CityBuilding {
  CityBuilding(this.ring, this.roofIdx, this.height, this.cx, this.cy, this.radius, this.normals, this.shade);
  final Float32List ring; // outline x,y pairs (no repeated closing point)
  final Uint16List roofIdx; // roof triangles as indices into [ring]
  final double height;
  final double cx, cy, radius;

  /// Outward wall normal per edge (x,y; zero for degenerate edges) and its
  /// fixed light factor — precomputed so frames don't redo them.
  final Float32List normals, shade;
}

/// Ordinary OpenStreetMap buildings with real heights, from OpenFreeMap's
/// free OpenMapTiles-schema tiles (`building` layer: `render_height`, from
/// OSM `height` / `building:levels`, else a default).
///
/// Buildings are bucketed into a coarse grid so a frame only looks at the
/// cells around the camera instead of every building in the tile.
class CityBuildingTile {
  CityBuildingTile(this.buildings) {
    if (buildings.isEmpty) {
      minX = minY = 0;
      cols = rows = 0;
      grid = const [];
      return;
    }
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final b in buildings) {
      x0 = math.min(x0, b.cx);
      y0 = math.min(y0, b.cy);
      x1 = math.max(x1, b.cx);
      y1 = math.max(y1, b.cy);
    }
    minX = x0;
    minY = y0;
    cols = ((x1 - x0) / cell).floor() + 1;
    rows = ((y1 - y0) / cell).floor() + 1;
    grid = List.generate(cols * rows, (_) => <CityBuilding>[]);
    for (final b in buildings) {
      grid[((b.cy - y0) / cell).floor() * cols + ((b.cx - x0) / cell).floor()].add(b);
    }
  }
  final List<CityBuilding> buildings;
  static const double cell = 200;
  late final double minX, minY;
  late final int cols, rows;
  late final List<List<CityBuilding>> grid;
}

/// Real-world heights.
const double kBuildingHeightScale = 1.0;

CityBuildingTile processBuildingTile(TileJob j) {
  final layers = decodeMvt(j.bytes, wanted: const {'building'});
  final n = 1 << j.z;
  final cosLat0 = math.cos(j.originLat * math.pi / 180);
  const mPerDegLat = 111132.95;
  final mPerDegLon = 111319.49 * cosLat0;
  double wx(double px, int ext) => ((j.x + px / ext) / n * 360 - 180 - j.originLon) * mPerDegLon;
  double wy(double py, int ext) {
    final t = math.pi * (1 - 2 * (j.y + py / ext) / n);
    return (math.atan((math.exp(t) - math.exp(-t)) / 2) * 180 / math.pi - j.originLat) * mPerDegLat;
  }

  final out = <CityBuilding>[];
  for (final layer in layers) {
    final ext = layer.extent;
    for (final f in layer.features) {
      if (f.type != MvtGeomType.polygon) continue;
      if (f.tags['hide_3d'] == true) continue;
      final h = (f.number('render_height') ?? 8).clamp(3, 600).toDouble() * kBuildingHeightScale;
      for (final p in groupRings(f.geometry)) {
        final outer = p.first;
        var len = outer.length;
        if (len >= 4 && outer[0] == outer[len - 2] && outer[1] == outer[len - 1]) len -= 2;
        if (len < 6) continue;
        final verts = <double>[];
        var cx = 0.0, cy = 0.0;
        for (var i = 0; i < len; i += 2) {
          final x = wx(outer[i], ext), y = wy(outer[i + 1], ext);
          verts
            ..add(x)
            ..add(y);
          cx += x;
          cy += y;
        }
        final cnt = len ~/ 2;
        cx /= cnt;
        cy /= cnt;
        var rad = 0.0;
        for (var i = 0; i < cnt; i++) {
          rad = math.max(rad, math.sqrt(math.pow(verts[i * 2] - cx, 2) + math.pow(verts[i * 2 + 1] - cy, 2)));
        }
        if (rad < 2) continue;
        if (cnt > 65535) continue;
        out.add(_fromOutline(verts, h, cx, cy, rad));
      }
    }
  }
  return CityBuildingTile(out);
}

/// A [CityBuilding] from an outline in metres (x,y pairs, no closing
/// point) and a height — used for the map's own landmark buildings too.
CityBuilding? cityBuildingFromOutline(List<double> verts, double h) {
  final cnt = verts.length ~/ 2;
  if (cnt < 3 || cnt > 65535) return null;
  var cx = 0.0, cy = 0.0;
  for (var i = 0; i < cnt; i++) {
    cx += verts[i * 2];
    cy += verts[i * 2 + 1];
  }
  cx /= cnt;
  cy /= cnt;
  var rad = 0.0;
  for (var i = 0; i < cnt; i++) {
    rad = math.max(rad, math.sqrt(math.pow(verts[i * 2] - cx, 2) + math.pow(verts[i * 2 + 1] - cy, 2)));
  }
  if (rad < 2) return null;
  return _fromOutline(verts, h, cx, cy, rad);
}

/// Builds a [CityBuilding] from an outline (x,y pairs, no closing point):
/// roof triangulation, outward wall normals and their light factors.
CityBuilding _fromOutline(List<double> verts, double h, double cx, double cy, double rad) {
  final cnt = verts.length ~/ 2;
  final idx = Earcut.triangulateRaw(verts);
  var area = 0.0;
  for (var i = 0, k = cnt - 1; i < cnt; k = i++) {
    area += (verts[k * 2] - verts[i * 2]) * (verts[k * 2 + 1] + verts[i * 2 + 1]);
  }
  final sign = area > 0 ? 1.0 : -1.0;
  final normals = Float32List(cnt * 2), shade = Float32List(cnt);
  for (var i = 0; i < cnt; i++) {
    final k = (i + 1) % cnt;
    var nx = (verts[k * 2 + 1] - verts[i * 2 + 1]) * sign, ny = -(verts[k * 2] - verts[i * 2]) * sign;
    final nl = math.sqrt(nx * nx + ny * ny);
    if (nl < 0.01) continue;
    nx /= nl;
    ny /= nl;
    normals[i * 2] = nx;
    normals[i * 2 + 1] = ny;
    shade[i] = 0.55 + 0.45 * ((nx * 0.55 + ny * 0.83) * 0.5 + 0.5);
  }
  return CityBuilding(Float32List.fromList(verts), Uint16List.fromList(idx), h, cx, cy, rad, normals, shade);
}

/// Draws city buildings as flat-shaded low-poly blocks: far-to-near per
/// building, back faces culled, everything batched into one vertex list
/// (so thousands of buildings stay cheap).
///
/// Per frame it only visits grid cells near the camera, projects each
/// outline corner once (at the ground and at the roof) and reuses those
/// for the walls and the roof, writing straight into reused typed buffers.
class CityBuildingRenderer {
  /// Buildings drawn in the last frame (benchmarks).
  static int lastDrawn = 0;
  static Float32List _pos = Float32List(1 << 16);
  static Int32List _col = Int32List(1 << 15);
  static Float32List _gx = Float32List(256), _gy = Float32List(256), _tx = Float32List(256), _ty = Float32List(256);
  static final _visible = <(double, CityBuilding, double)>[];

  static void paint(Canvas canvas, Camera3D cam, Iterable<CityBuildingTile> tiles, MapPalette palette, {double maxDistance = 700}) {
    final visible = _visible..clear();
    final width = cam.size.width;
    final px = cam.px, py = cam.py, cosB = cam.cosB, sinB = cam.sinB;
    final yNear = cam.yNear;
    // Everything that can be on screen lies within this radius of the player.
    final reach = math.sqrt(maxDistance * maxDistance + math.pow(cam.halfWidthAt(maxDistance), 2)) + 300;
    double fade(double v, double from, double to) {
      final t = ((v - from) / (to - from)).clamp(0.0, 1.0);
      return t * t * (3 - 2 * t);
    }

    for (final t in tiles) {
      if (t.cols == 0) continue;
      const cs = CityBuildingTile.cell;
      final c0 = ((px - reach - t.minX) / cs).floor().clamp(0, t.cols - 1), c1 = ((px + reach - t.minX) / cs).floor();
      final r0 = ((py - reach - t.minY) / cs).floor().clamp(0, t.rows - 1), r1 = ((py + reach - t.minY) / cs).floor();
      if (c1 < 0 || r1 < 0) continue;
      for (var r = r0; r <= math.min(r1, t.rows - 1); r++) {
        for (var c = c0; c <= math.min(c1, t.cols - 1); c++) {
          // Cull whole cells that are entirely behind the near plane or
          // beyond the draw distance.
          final ccx = t.minX + (c + 0.5) * cs, ccy = t.minY + (r + 0.5) * cs;
          final cya = (ccx - px) * sinB + (ccy - py) * cosB;
          if (cya + cs < yNear || cya - cs - 150 > maxDistance) continue;
          for (final b in t.grid[r * t.cols + c]) {
            final dx = b.cx - px, dy = b.cy - py;
            final ya = dx * sinB + dy * cosB;
            // Skip anything crossing the near plane or past the draw distance.
            if (ya - b.radius < yNear || ya - b.radius > maxDistance) continue;
            final zc = cam.depth(ya, 0);
            if (zc <= 1) continue;
            final sx = cam.sx(dx * cosB - dy * sinB, zc);
            final rpx = b.radius * cam.focal / zc;
            if (sx + rpx < -40 || sx - rpx > width + 40) continue;
            // Keep the player and the view around them clear, fading out as
            // you walk up instead of popping out of existence.
            final dist = math.sqrt(dx * dx + dy * dy) - b.radius;
            final alpha = math.min(fade(dist, 40, 150), fade(ya - b.radius, 20, 110));
            if (alpha <= 0.02) continue;
            visible.add((cam.depth(ya, b.height / 2), b, alpha));
          }
        }
      }
    }
    lastDrawn = visible.length;
    if (visible.isEmpty) return;
    visible.sort((a, b) => b.$1.compareTo(a.$1));
    final br = cam.bearing * math.pi / 180;
    // Camera position on the ground (for back-face culling of walls).
    final back = cam.distance * math.cos(cam.pitch * math.pi / 180);
    final camX = px - math.sin(br) * back, camY = py - math.cos(br) * back;
    final wall = palette.buildingWall, roofC = palette.buildingRoof;
    final fog = palette.skyBottom;
    int argb(Color c, double k, double fogT, double alpha) {
      double ch(double v, double f) => ((v * k) + (f - v * k) * fogT).clamp(0.0, 1.0) * 255;
      return ((alpha * 255).round() << 24) | (ch(c.r, fog.r).round() << 16) | (ch(c.g, fog.g).round() << 8) | ch(c.b, fog.b).round();
    }

    final eb = cam.eyeBack, eu = cam.eyeUp, ed = cam.eyeDist, f = cam.focal, ccx = cam.cx, ccy = cam.cy;
    final dd = ed * ed;
    var np = 0, nc = 0; // floats / colours written
    var bx0 = double.infinity, by0 = double.infinity, bx1 = -double.infinity, by1 = -double.infinity;
    void ensure(int verts) {
      if ((nc + verts) > _col.length) {
        final grow = math.max(_col.length * 2, nc + verts);
        _col = Int32List(grow)..setRange(0, nc, _col);
        _pos = Float32List(grow * 2)..setRange(0, np, _pos);
      }
    }

    void emit(double d, CityBuilding b) {
      final r = b.ring, cnt = r.length ~/ 2, h = b.height;
      if (_gx.length < cnt) {
        _gx = Float32List(cnt * 2);
        _gy = Float32List(cnt * 2);
        _tx = Float32List(cnt * 2);
        _ty = Float32List(cnt * 2);
      }
      // Project every corner once, at the ground and at the roof. A wall
      // taller than the camera can pass behind the eye plane; it is cut
      // just in front of it rather than flipping across the screen.
      for (var i = 0; i < cnt; i++) {
        final dx = r[i * 2] - px, dy = r[i * 2 + 1] - py;
        final xa = dx * cosB - dy * sinB, ya = dx * sinB + dy * cosB;
        final z0 = (ya * eb + dd) / ed;
        final hc = eu > 0 ? math.min(h, (z0 - 2) * ed / eu) : h;
        final zh = z0 - hc * eu / ed;
        final gx = ccx + f * xa / z0, gy = ccy - f * (ya * eu / ed) / z0;
        final tx = ccx + f * xa / zh, ty = ccy - f * ((ya * eu + hc * eb) / ed) / zh;
        _gx[i] = gx;
        _gy[i] = gy;
        _tx[i] = tx;
        _ty[i] = ty;
        bx0 = math.min(bx0, math.min(gx, tx));
        bx1 = math.max(bx1, math.max(gx, tx));
        by0 = math.min(by0, math.min(gy, ty));
        by1 = math.max(by1, math.max(gy, ty));
      }
      final fogT = ((d - 300) / (maxDistance * 1.2)).clamp(0.0, 0.75);
      final nrm = b.normals, shade = b.shade;
      ensure(cnt * 6 + b.roofIdx.length);
      for (var i = 0; i < cnt; i++) {
        final nx = nrm[i * 2], ny = nrm[i * 2 + 1];
        if (nx == 0 && ny == 0) continue;
        final k = i + 1 == cnt ? 0 : i + 1;
        // Back-face cull: the wall faces away from the camera.
        if (nx * (camX - (r[i * 2] + r[k * 2]) / 2) + ny * (camY - (r[i * 2 + 1] + r[k * 2 + 1]) / 2) <= 0) continue;
        final c = argb(wall, shade[i], fogT, 1);
        _pos[np++] = _gx[i];
        _pos[np++] = _gy[i];
        _pos[np++] = _gx[k];
        _pos[np++] = _gy[k];
        _pos[np++] = _tx[k];
        _pos[np++] = _ty[k];
        _pos[np++] = _gx[i];
        _pos[np++] = _gy[i];
        _pos[np++] = _tx[k];
        _pos[np++] = _ty[k];
        _pos[np++] = _tx[i];
        _pos[np++] = _ty[i];
        for (var q = 0; q < 6; q++) {
          _col[nc++] = c;
        }
      }
      final rc = argb(roofC, 1, fogT, 1);
      final idx = b.roofIdx;
      for (var i = 0; i < idx.length; i++) {
        final v = idx[i];
        _pos[np++] = _tx[v];
        _pos[np++] = _ty[v];
        _col[nc++] = rc;
      }
    }

    void flush() {
      if (nc == 0) return;
      final v = ui.Vertices.raw(VertexMode.triangles, Float32List.sublistView(_pos, 0, np), colors: Int32List.sublistView(_col, 0, nc));
      canvas.drawVertices(v, BlendMode.dst, Paint());
      v.dispose();
      np = nc = 0;
    }

    // Vertex colours are always opaque (per-vertex alpha renders
    // differently across platforms — on Windows it made every building
    // see-through). Fully visible buildings go in one batch; the few
    // fading out near the player are drawn per fade step through a layer.
    for (final (d, b, alpha) in visible) {
      if (alpha >= 0.97) emit(d, b);
    }
    flush();
    for (var step = 1; step <= 3; step++) {
      bx0 = by0 = double.infinity;
      bx1 = by1 = -double.infinity;
      for (final (d, b, alpha) in visible) {
        if (alpha < 0.97 && (alpha * 3).ceil().clamp(1, 3) == step) emit(d, b);
      }
      if (nc == 0) continue;
      canvas.saveLayer(Rect.fromLTRB(bx0 - 2, by0 - 2, bx1 + 2, by1 + 2), Paint()..color = Color.fromRGBO(0, 0, 0, step / 3.5));
      flush();
      canvas.restore();
    }
  }
}
