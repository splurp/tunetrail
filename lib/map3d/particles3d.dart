import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'camera.dart';

/// Kinds of weather / ambience particles living in 3D around the player.
enum Particle3DKind { snow, dust, embers, petals }

/// Theme particles (snow, record-shop dust, embers, sakura petals) as real
/// 3D points in a box of air around the player, seen through the map
/// camera: near ones are bigger and sweep faster across the screen, and
/// they move correctly as the camera turns, tilts or the player walks.
///
/// Everything is batched: particles are sorted into a few size / colour
/// buckets and each bucket is one `drawRawPoints` call (petals: one
/// `drawVertices`), with no blur filters — a few draw calls per frame
/// instead of one or two per particle.
class Particles3DPainter extends CustomPainter {
  Particles3DPainter({required this.camera, required this.time, required this.kind, this.vignette});
  final Camera3D camera;
  final double time;
  final Particle3DKind kind;

  /// Optional screen-edge darkening (the themes' vignette).
  final Color? vignette;

  static const _box = 520.0; // metres, horizontal extent around the view

  static double _r(int i, int salt) {
    final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  static const _sizeBuckets = 6;
  static final List<Float32List> _buf = List.generate(_sizeBuckets * 4, (_) => Float32List(4096));
  static final List<int> _n = List.filled(_sizeBuckets * 4, 0);
  static Float32List _tri = Float32List(1 << 14);
  static Int32List _triCol = Int32List(1 << 13);

  int get _count => switch (kind) {
        Particle3DKind.snow => 900,
        Particle3DKind.dust => 320,
        Particle3DKind.embers => 360,
        Particle3DKind.petals => 260,
      };

  double get _height => switch (kind) {
        Particle3DKind.snow => 170,
        Particle3DKind.dust => 60,
        Particle3DKind.embers => 140,
        Particle3DKind.petals => 120,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final w = size.width, h = size.height;
    final cosB = cam.cosB, sinB = cam.sinB, eb = cam.eyeBack, eu = cam.eyeUp, ed = cam.eyeDist, f = cam.focal, ccx = cam.cx, ccy = cam.cy;
    final dd = ed * ed, yNear = cam.yNear;
    final px = cam.px, py = cam.py;
    // Centre the box a little ahead of the player so it fills the view.
    final br = cam.bearing * math.pi / 180;
    final bx = px + math.sin(br) * 120, by = py + math.cos(br) * 120;
    final height = _height;
    for (var i = 0; i < _n.length; i++) {
      _n[i] = 0;
    }
    var nt = 0, ntc = 0;
    final t = time;
    final count = _count;
    for (var i = 0; i < count; i++) {
      // World-anchored columns of air, wrapped into the box around the view.
      final wx0 = _r(i, 2) * _box * 8, wy0 = _r(i, 3) * _box * 8;
      double x, y, z;
      switch (kind) {
        case Particle3DKind.snow:
          final speed = 6 + 6 * _r(i, 1);
          x = wx0 + math.sin(t * (0.6 + _r(i, 4)) + i) * 3;
          y = wy0 + t * 2.5;
          z = height - ((_r(i, 5) * height + t * speed) % height);
        case Particle3DKind.dust:
          // Motes hanging in the air, slowly swirling.
          x = wx0 + math.sin(t * 0.25 + i) * 6 + t * 0.8;
          y = wy0 + math.cos(t * 0.2 + i * 1.3) * 6;
          z = 2 + (_r(i, 5) * height + math.sin(t * 0.4 + i) * 4) % height;
        case Particle3DKind.embers:
          // Rising from the molten ground, flickering sideways.
          final speed = 5 + 9 * _r(i, 1);
          x = wx0 + math.sin(t * (1.1 + _r(i, 4)) + i) * 4;
          y = wy0 + math.cos(t * 0.9 + i) * 4;
          z = (_r(i, 5) * height + t * speed) % height;
        case Particle3DKind.petals:
          // Drifting down and along with the breeze.
          final speed = 3 + 4 * _r(i, 1);
          x = wx0 + t * 4 + math.sin(t * (0.5 + _r(i, 4)) + i) * 7;
          y = wy0 + t * 1.5 + math.cos(t * 0.7 + i) * 5;
          z = height - ((_r(i, 5) * height + t * speed) % height);
      }
      x = (x - (bx - _box / 2)) % _box + (bx - _box / 2);
      y = (y - (by - _box / 2)) % _box + (by - _box / 2);
      final dx = x - px, dy = y - py;
      final xa = dx * cosB - dy * sinB, ya = dx * sinB + dy * cosB;
      if (ya < yNear) continue;
      final zc = (ya * eb + dd - z * eu) / ed;
      if (zc <= 1) continue;
      final sx = ccx + f * xa / zc, sy = ccy - f * ((ya * eu + z * eb) / ed) / zc;
      if (sx < -12 || sx > w + 12 || sy < -12 || sy > h + 12) continue;
      final k = f / zc; // pixels per metre at this depth
      if (kind == Particle3DKind.petals) {
        // A small kite-shaped petal, tumbling.
        final len = (2.2 * k).clamp(4.0, 16.0) * (0.75 + 0.5 * _r(i, 6));
        final wid = len * 0.5 * (0.35 + 0.65 * math.sin(t * (1.5 + _r(i, 7)) + i).abs());
        final a = t * (0.6 + _r(i, 8)) + i;
        final ca = math.cos(a), sa = math.sin(a);
        if (nt + 12 > _tri.length) {
          _tri = Float32List(_tri.length * 2)..setRange(0, nt, _tri);
          _triCol = Int32List(_triCol.length * 2)..setRange(0, ntc, _triCol);
        }
        final tipX = sx + ca * len, tipY = sy + sa * len;
        final backX = sx - ca * len * 0.55, backY = sy - sa * len * 0.55;
        final s1X = sx - sa * wid, s1Y = sy + ca * wid, s2X = sx + sa * wid, s2Y = sy - ca * wid;
        _tri
          ..[nt++] = tipX
          ..[nt++] = tipY
          ..[nt++] = s1X
          ..[nt++] = s1Y
          ..[nt++] = backX
          ..[nt++] = backY
          ..[nt++] = tipX
          ..[nt++] = tipY
          ..[nt++] = backX
          ..[nt++] = backY
          ..[nt++] = s2X
          ..[nt++] = s2Y;
        final shade = _r(i, 9);
        final c = shade < 0.33 ? 0xE6F48FB1 : (shade < 0.66 ? 0xE6EC7FAA : 0xE6F06292);
        for (var q = 0; q < 6; q++) {
          _triCol[ntc++] = c;
        }
        continue;
      }
      final radius = switch (kind) {
        Particle3DKind.snow => (0.55 * k).clamp(0.7, 4.5) * (0.7 + 0.6 * _r(i, 6)),
        Particle3DKind.dust => (0.45 * k).clamp(1.0, 3.2) * (0.6 + 0.8 * _r(i, 6)),
        Particle3DKind.embers => (0.35 * k).clamp(0.8, 3.6) * (0.6 + 0.8 * _r(i, 6)),
        Particle3DKind.petals => 0.0,
      };
      final sb = (radius / 4.5 * _sizeBuckets).floor().clamp(0, _sizeBuckets - 1);
      // Embers: colour band by how high they've risen (yellow → deep red).
      final cb = kind == Particle3DKind.embers ? (z / height * 4).floor().clamp(0, 3) : 0;
      final b = cb * _sizeBuckets + sb;
      var buf = _buf[b];
      if (_n[b] + 2 > buf.length) buf = _buf[b] = Float32List(buf.length * 2)..setRange(0, _n[b], buf);
      buf[_n[b]++] = sx;
      buf[_n[b]++] = sy;
    }

    if (kind == Particle3DKind.petals) {
      if (nt > 0) {
        final v = ui.Vertices.raw(VertexMode.triangles, Float32List.sublistView(_tri, 0, nt), colors: Int32List.sublistView(_triCol, 0, ntc));
        canvas.drawVertices(v, BlendMode.dst, Paint());
        v.dispose();
      }
    } else {
      final dot = Paint()..strokeCap = StrokeCap.round;
      for (var cb = 0; cb < 4; cb++) {
        for (var sb = 0; sb < _sizeBuckets; sb++) {
          final b = cb * _sizeBuckets + sb;
          if (_n[b] == 0) continue;
          final pts = Float32List.sublistView(_buf[b], 0, _n[b]);
          final r = (sb + 0.5) / _sizeBuckets * 4.5;
          switch (kind) {
            case Particle3DKind.snow:
              // A soft dark rim keeps white flakes readable on pale ground.
              canvas.drawRawPoints(ui.PointMode.points, pts, dot
                ..color = const Color(0x30203848)
                ..strokeWidth = r * 2 + 2.2);
              canvas.drawRawPoints(ui.PointMode.points, pts, dot
                ..color = Colors.white
                ..strokeWidth = r * 2);
            case Particle3DKind.dust:
              canvas.drawRawPoints(ui.PointMode.points, pts, dot
                ..color = const Color(0x30FFE0B2)
                ..strokeWidth = r * 2 + 3);
              canvas.drawRawPoints(ui.PointMode.points, pts, dot
                ..color = const Color(0xB3FFF3E0)
                ..strokeWidth = r * 2);
            case Particle3DKind.embers:
              const cols = [Color(0xFFFFEB3B), Color(0xFFFFB300), Color(0xFFFF6D00), Color(0xFFDD2C00)];
              final c = cols[cb];
              canvas.drawRawPoints(ui.PointMode.points, pts, dot
                ..color = c.withValues(alpha: 0.22)
                ..strokeWidth = r * 2 + 4);
              canvas.drawRawPoints(ui.PointMode.points, pts, dot
                ..color = c.withValues(alpha: 0.85 - cb * 0.12)
                ..strokeWidth = r * 2);
            case Particle3DKind.petals:
              break;
          }
        }
      }
    }

    final vg = vignette;
    if (vg != null) {
      final rect = Offset.zero & size;
      canvas.drawRect(rect, Paint()..shader = RadialGradient(colors: [Colors.transparent, vg], stops: const [0.6, 1.0], radius: 0.95).createShader(rect));
    }
  }

  @override
  bool shouldRepaint(Particles3DPainter old) => true;
}
