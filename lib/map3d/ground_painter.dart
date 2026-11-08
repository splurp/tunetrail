import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'camera.dart';
import 'map_data.dart';
import 'palette.dart';
import 'tile_data.dart';

/// Reusable growable float buffer (avoids per-frame allocation).
class _Buf {
  Float32List data = Float32List(1 << 14);
  int length = 0;
  void reset() => length = 0;
  @pragma('vm:prefer-inline')
  void ensure(int extra) {
    if (length + extra <= data.length) return;
    var cap = data.length * 2;
    while (cap < length + extra) {
      cap *= 2;
    }
    final n = Float32List(cap)..setRange(0, length, data);
    data = n;
  }
}

/// Paints the stylised 3D ground: sky, land layers, roads, water, mega
/// buildings, catch radius and distance fog.
class GroundPainter extends CustomPainter {
  GroundPainter({required this.camera, required this.map, required this.palette, required this.catchRadius, required Listenable repaint})
      : super(repaint: repaint);

  final Camera3D camera;
  final MapData map;
  final MapPalette palette;
  final double catchRadius;

  static final Map<GroundLayer, _Buf> _bufs = {for (final l in GroundLayer.values) l: _Buf()};
  static final Float32List _clipIn = Float32List(8), _clipOut = Float32List(16);

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final horizon = cam.horizonY;

    // Ground base colour everywhere below the horizon, sky above.
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.ground);
    final skyRect = Rect.fromLTWH(0, 0, size.width, math.max(0, horizon + 2));
    canvas.drawRect(
        skyRect,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [palette.skyTop, palette.skyBottom])
              .createShader(skyRect));

    for (final b in _bufs.values) {
      b.reset();
    }
    for (final t in map.tiles.values) {
      for (final e in t.layers.entries) {
        _projectLayer(cam, e.value, t.buckets[e.key]!, _bufs[e.key]!);
      }
    }
    final paint = Paint()..isAntiAlias = true;
    for (final l in GroundLayer.values) {
      final b = _bufs[l]!;
      if (b.length == 0) continue;
      final v = ui.Vertices.raw(VertexMode.triangles, Float32List.sublistView(b.data, 0, b.length));
      canvas.drawVertices(v, BlendMode.srcOver, paint..color = palette.layer(l));
      v.dispose();
    }

    _catchRing(canvas, cam);
    _buildings(canvas, cam);

    // Distance fog towards the horizon.
    final fogNear = cam.groundY(math.max(360, cam.distance * 1.6));
    final fogFar = cam.groundY(cam.yFar * 0.92);
    final fogRect = Rect.fromLTRB(0, fogFar - 1, size.width, fogNear);
    if (fogRect.height > 0) {
      canvas.drawRect(
          fogRect,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [palette.skyBottom, palette.skyBottom.withValues(alpha: 0)])
                .createShader(fogRect));
    }
    canvas.drawRect(Rect.fromLTRB(0, horizon - 1, size.width, fogFar), Paint()..color = palette.skyBottom);
  }

  void _projectLayer(Camera3D cam, Float32List tris, Float32List buckets, _Buf out) {
    final yNear = cam.yNear, yFar = cam.yFar;
    for (var bi = 0; bi + 5 < buckets.length; bi += 6) {
      // Bucket culling: test its bbox corners in camera space.
      final bx0 = buckets[bi + 2], by0 = buckets[bi + 3], bx1 = buckets[bi + 4], by1 = buckets[bi + 5];
      var minYa = double.infinity, maxYa = -double.infinity;
      var allRight = true, allLeft = true;
      for (var c = 0; c < 4; c++) {
        final x = c & 1 == 0 ? bx0 : bx1;
        final y = c < 2 ? by0 : by1;
        final xa = cam.alignX(x, y), ya = cam.alignY(x, y);
        minYa = math.min(minYa, ya);
        maxYa = math.max(maxYa, ya);
        final hw = cam.halfWidthAt(math.max(ya, yNear)) + 30;
        if (xa < hw) allRight = false;
        if (xa > -hw) allLeft = false;
      }
      if (maxYa < yNear || minYa > yFar || allRight || allLeft) continue;
      final start = buckets[bi].toInt(), end = buckets[bi + 1].toInt();
      out.ensure((end - start) * 2);
      final d = out.data;
      for (var i = start; i + 5 < end; i += 6) {
        final xa0 = cam.alignX(tris[i], tris[i + 1]), ya0 = cam.alignY(tris[i], tris[i + 1]);
        final xa1 = cam.alignX(tris[i + 2], tris[i + 3]), ya1 = cam.alignY(tris[i + 2], tris[i + 3]);
        final xa2 = cam.alignX(tris[i + 4], tris[i + 5]), ya2 = cam.alignY(tris[i + 4], tris[i + 5]);
        if (ya0 > yFar && ya1 > yFar && ya2 > yFar) continue;
        final in0 = ya0 >= yNear, in1 = ya1 >= yNear, in2 = ya2 >= yNear;
        if (in0 && in1 && in2) {
          var o = out.length;
          var zc = cam.depth(ya0, 0);
          d[o++] = cam.sx(xa0, zc);
          d[o++] = cam.sy(ya0, 0, zc);
          zc = cam.depth(ya1, 0);
          d[o++] = cam.sx(xa1, zc);
          d[o++] = cam.sy(ya1, 0, zc);
          zc = cam.depth(ya2, 0);
          d[o++] = cam.sx(xa2, zc);
          d[o++] = cam.sy(ya2, 0, zc);
          out.length = o;
        } else if (in0 || in1 || in2) {
          _clipTriangle(cam, out, xa0, ya0, xa1, ya1, xa2, ya2);
        }
      }
    }
  }

  /// Sutherland–Hodgman clip of one triangle against ya ≥ yNear.
  void _clipTriangle(Camera3D cam, _Buf out, double xa0, double ya0, double xa1, double ya1, double xa2, double ya2) {
    final yn = cam.yNear;
    final inp = _clipIn
      ..[0] = xa0
      ..[1] = ya0
      ..[2] = xa1
      ..[3] = ya1
      ..[4] = xa2
      ..[5] = ya2;
    var n = 0;
    for (var i = 0; i < 3; i++) {
      final ax = inp[i * 2], ay = inp[i * 2 + 1];
      final j = (i + 1) % 3;
      final bx = inp[j * 2], by = inp[j * 2 + 1];
      final aIn = ay >= yn, bIn = by >= yn;
      if (aIn) {
        _clipOut[n++] = ax;
        _clipOut[n++] = ay;
      }
      if (aIn != bIn) {
        final t = (yn - ay) / (by - ay);
        _clipOut[n++] = ax + (bx - ax) * t;
        _clipOut[n++] = yn;
      }
    }
    final pts = n ~/ 2;
    if (pts < 3) return;
    out.ensure((pts - 2) * 6);
    final d = out.data;
    double px(int k) => cam.sx(_clipOut[k * 2], cam.depth(_clipOut[k * 2 + 1], 0));
    double py(int k) => cam.sy(_clipOut[k * 2 + 1], 0, cam.depth(_clipOut[k * 2 + 1], 0));
    for (var k = 1; k + 1 < pts; k++) {
      var o = out.length;
      d[o++] = px(0);
      d[o++] = py(0);
      d[o++] = px(k);
      d[o++] = py(k);
      d[o++] = px(k + 1);
      d[o++] = py(k + 1);
      out.length = o;
    }
  }

  void _catchRing(Canvas canvas, Camera3D cam) {
    final path = Path();
    const n = 72;
    for (var i = 0; i <= n; i++) {
      final a = i * 2 * math.pi / n;
      final p = cam.project(cam.px + math.cos(a) * catchRadius, cam.py + math.sin(a) * catchRadius);
      if (p == null) continue;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()..color = palette.accent.withValues(alpha: 0.05));
    canvas.drawPath(
        path,
        Paint()
          ..color = palette.accent.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
  }

  void _buildings(Canvas canvas, Camera3D cam) {
    final faces = <(double, Path, Color)>[];
    const light = (0.55, 0.83); // light direction (east, north), normalised-ish
    for (final t in map.tiles.values) {
      for (final b in t.buildings) {
        final r = b.ring;
        final cnt = r.length ~/ 2;
        if (cnt < 3) continue;
        // Skip if any vertex is behind the near plane or the building is far.
        var ok = true;
        var minYa = double.infinity;
        for (var i = 0; i < cnt; i++) {
          final ya = cam.alignY(r[i * 2], r[i * 2 + 1]);
          minYa = math.min(minYa, ya);
          if (ya < cam.yNear) ok = false;
        }
        if (!ok || minYa > cam.yFar) continue;
        Offset p(double x, double y, double z) {
          final xa = cam.alignX(x, y), ya = cam.alignY(x, y);
          final zc = cam.depth(ya, z);
          return Offset(cam.sx(xa, zc), cam.sy(ya, z, zc));
        }

        final h = b.height;
        // Orientation of the ring (for outward normals).
        var area = 0.0;
        for (var i = 0, j = cnt - 1; i < cnt; j = i++) {
          area += (r[j * 2] - r[i * 2]) * (r[j * 2 + 1] + r[i * 2 + 1]);
        }
        final sign = area > 0 ? 1.0 : -1.0;
        for (var i = 0; i < cnt; i++) {
          final j = (i + 1) % cnt;
          final ax = r[i * 2], ay = r[i * 2 + 1], bx = r[j * 2], by = r[j * 2 + 1];
          var nx = (by - ay) * sign, ny = -(bx - ax) * sign;
          final nl = math.sqrt(nx * nx + ny * ny);
          if (nl < 0.01) continue;
          nx /= nl;
          ny /= nl;
          final shade = 0.55 + 0.45 * ((nx * light.$1 + ny * light.$2) * 0.5 + 0.5);
          final mx = (ax + bx) / 2, my = (ay + by) / 2;
          final depth = cam.depth(cam.alignY(mx, my), h / 2);
          final path = Path()
            ..moveTo(p(ax, ay, 0).dx, p(ax, ay, 0).dy)
            ..lineTo(p(bx, by, 0).dx, p(bx, by, 0).dy)
            ..lineTo(p(bx, by, h).dx, p(bx, by, h).dy)
            ..lineTo(p(ax, ay, h).dx, p(ax, ay, h).dy)
            ..close();
          faces.add((depth, path, Color.lerp(Colors.black, palette.buildingWall, shade)!));
        }
        final roof = Path();
        final rt = b.roof;
        for (var i = 0; i + 5 < rt.length; i += 6) {
          final a = p(rt[i], rt[i + 1], h), bb = p(rt[i + 2], rt[i + 3], h), c = p(rt[i + 4], rt[i + 5], h);
          roof
            ..moveTo(a.dx, a.dy)
            ..lineTo(bb.dx, bb.dy)
            ..lineTo(c.dx, c.dy)
            ..close();
        }
        var cxm = 0.0, cym = 0.0;
        for (var i = 0; i < cnt; i++) {
          cxm += r[i * 2];
          cym += r[i * 2 + 1];
        }
        faces.add((cam.depth(cam.alignY(cxm / cnt, cym / cnt), h) - 0.01, roof, palette.buildingRoof));
      }
    }
    faces.sort((a, b) => b.$1.compareTo(a.$1));
    final paint = Paint()..isAntiAlias = true;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = palette.buildingEdge;
    for (final f in faces) {
      canvas.drawPath(f.$2, paint..color = f.$3);
      canvas.drawPath(f.$2, edge);
    }
  }

  @override
  bool shouldRepaint(GroundPainter old) => true;
}
