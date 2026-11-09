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
  CityBuilding(this.ring, this.roof, this.height, this.cx, this.cy, this.radius);
  final Float32List ring; // outline x,y pairs (no repeated closing point)
  final Float32List roof; // roof triangles x,y
  final double height;
  final double cx, cy, radius;
}

/// Ordinary OpenStreetMap buildings with real heights, from OpenFreeMap's
/// free OpenMapTiles-schema tiles (`building` layer: `render_height`, from
/// OSM `height` / `building:levels`, else a default).
class CityBuildingTile {
  CityBuildingTile(this.buildings);
  final List<CityBuilding> buildings;
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
        final idx = Earcut.triangulateRaw(verts);
        final roof = Float32List(idx.length * 2);
        for (var i = 0; i < idx.length; i++) {
          roof[i * 2] = verts[idx[i] * 2];
          roof[i * 2 + 1] = verts[idx[i] * 2 + 1];
        }
        out.add(CityBuilding(Float32List.fromList(verts), roof, h, cx, cy, rad));
      }
    }
  }
  return CityBuildingTile(out);
}

/// Draws city buildings as flat-shaded low-poly blocks: far-to-near per
/// building, back faces culled, everything batched into one vertex list
/// (so thousands of buildings stay cheap).
class CityBuildingRenderer {
  static final _pos = <double>[];
  static final _col = <int>[];

  static void paint(Canvas canvas, Camera3D cam, Iterable<CityBuildingTile> tiles, MapPalette palette, {double maxDistance = 700}) {
    final visible = <(double, CityBuilding, double)>[];
    final halfFov = cam.size.width / 2;
    for (final t in tiles) {
      for (final b in t.buildings) {
        final ya = cam.alignY(b.cx, b.cy);
        if (ya + b.radius < cam.yNear || ya - b.radius > maxDistance) continue;
        // Horizontal frustum test on the centre (with the footprint radius).
        final zc = cam.depth(math.max(ya, cam.yNear + 1), 0);
        if (zc <= 1) continue;
        final sx = cam.sx(cam.alignX(b.cx, b.cy), zc);
        final rpx = b.radius * cam.focal / zc;
        if (sx + rpx < -40 || sx - rpx > halfFov * 2 + 40) continue;
        // Skip any building that would cross the near plane.
        if (ya - b.radius < cam.yNear) continue;
        // Keep the player and the view around them clear: nothing between
        // the camera and the player, nothing right around the player.
        final dx = b.cx - cam.px, dy = b.cy - cam.py;
        final dist = math.sqrt(dx * dx + dy * dy) - b.radius;
        // ...fading out as you walk up instead of popping out of existence.
        double fade(double v, double from, double to) {
          final t = ((v - from) / (to - from)).clamp(0.0, 1.0);
          return t * t * (3 - 2 * t);
        }

        final alpha = math.min(fade(dist, 40, 150), fade(ya - b.radius, 20, 110));
        if (alpha <= 0.02) continue;
        visible.add((cam.depth(ya, b.height / 2), b, alpha));
      }
    }
    if (visible.isEmpty) return;
    visible.sort((a, b) => b.$1.compareTo(a.$1));
    _pos.clear();
    _col.clear();
    final br = cam.bearing * math.pi / 180;
    // Camera position on the ground (for back-face culling of walls).
    final back = cam.distance * math.cos(cam.pitch * math.pi / 180);
    final camX = cam.px - math.sin(br) * back, camY = cam.py - math.cos(br) * back;
    const lx = 0.55, ly = 0.83;
    final wall = palette.buildingWall, roofC = palette.buildingRoof;
    final fog = palette.skyBottom;
    int argb(Color c, double k, double fogT, double alpha) {
      double ch(double v, double f) => ((v * k) + (f - v * k) * fogT).clamp(0.0, 1.0) * 255;
      return ((alpha * 255).round() << 24) | (ch(c.r, fog.r).round() << 16) | (ch(c.g, fog.g).round() << 8) | ch(c.b, fog.b).round();
    }

    void vert(double x, double y, double z) {
      final xa = cam.alignX(x, y), ya = cam.alignY(x, y);
      final zc = cam.depth(ya, z);
      _pos
        ..add(cam.sx(xa, zc))
        ..add(cam.sy(ya, z, zc));
    }

    for (final (d, b, alpha) in visible) {
      final r = b.ring, cnt = r.length ~/ 2, h = b.height;
      final fogT = ((d - 300) / (maxDistance * 1.2)).clamp(0.0, 0.75);
      var area = 0.0;
      for (var i = 0, k = cnt - 1; i < cnt; k = i++) {
        area += (r[k * 2] - r[i * 2]) * (r[k * 2 + 1] + r[i * 2 + 1]);
      }
      final sign = area > 0 ? 1.0 : -1.0;
      for (var i = 0; i < cnt; i++) {
        final k = (i + 1) % cnt;
        final ax = r[i * 2], ay = r[i * 2 + 1], bx = r[k * 2], by = r[k * 2 + 1];
        var nx = (by - ay) * sign, ny = -(bx - ax) * sign;
        final nl = math.sqrt(nx * nx + ny * ny);
        if (nl < 0.01) continue;
        nx /= nl;
        ny /= nl;
        // Back-face cull: the wall faces away from the camera.
        if (nx * (camX - (ax + bx) / 2) + ny * (camY - (ay + by) / 2) <= 0) continue;
        final c = argb(wall, 0.55 + 0.45 * ((nx * lx + ny * ly) * 0.5 + 0.5), fogT, alpha);
        vert(ax, ay, 0);
        vert(bx, by, 0);
        vert(bx, by, h);
        vert(ax, ay, 0);
        vert(bx, by, h);
        vert(ax, ay, h);
        for (var q = 0; q < 6; q++) {
          _col.add(c);
        }
      }
      final roof = b.roof;
      final rc = argb(roofC, 1, fogT, alpha);
      for (var i = 0; i + 1 < roof.length; i += 2) {
        vert(roof[i], roof[i + 1], h);
        _col.add(rc);
      }
    }
    final v = ui.Vertices.raw(VertexMode.triangles, Float32List.fromList(_pos), colors: Int32List.fromList(_col));
    canvas.drawVertices(v, BlendMode.dst, Paint());
    v.dispose();
  }
}
