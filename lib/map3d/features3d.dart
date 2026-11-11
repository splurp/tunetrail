import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:tunetrail_core/tunetrail_core.dart' show FeatureKind;

import '../game/game.dart' show MapFeature;
import 'camera.dart';
import 'palette.dart';
import 'props3d.dart';

/// A feature mesh ready to draw: triangles in local metres, each with its
/// outward normal and colour.
class FeatureMesh {
  FeatureMesh(LowPolyMesh m)
      : n = m.triangles,
        v = Float32List.fromList(m.v),
        normal = Float32List(m.triangles * 3),
        color = [for (final c in m.color) c] {
    for (var t = 0; t < n; t++) {
      final o = t * 9;
      final ux = v[o + 3] - v[o], uy = v[o + 4] - v[o + 1], uz = v[o + 5] - v[o + 2];
      final wx = v[o + 6] - v[o], wy = v[o + 7] - v[o + 1], wz = v[o + 8] - v[o + 2];
      var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l < 1e-9) continue;
      nx /= l;
      ny /= l;
      nz /= l;
      // Outward: away from the centre of the part the face belongs to.
      final fx = (v[o] + v[o + 3] + v[o + 6]) / 3 - m.c[t * 3], fy = (v[o + 1] + v[o + 4] + v[o + 7]) / 3 - m.c[t * 3 + 1], fz = (v[o + 2] + v[o + 5] + v[o + 8]) / 3 - m.c[t * 3 + 2];
      if (nx * fx + ny * fy + nz * fz < 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
      }
      normal[t * 3] = nx;
      normal[t * 3 + 1] = ny;
      normal[t * 3 + 2] = nz;
    }
  }
  final int n;
  final Float32List v, normal;
  final List<Color> color;
}

/// The small things standing around the map — bushes, rock piles, lily
/// pads, saplings, sand castles and sewer grates — as low-poly meshes,
/// lightly shaded, in a colour taken from the theme: half-way to black
/// from the ground they stand on in light themes, half-way to white in
/// dark ones.
abstract final class FeatureMeshes {
  static final Map<int, FeatureMesh> _cache = {};

  static const variants = 3;

  /// The colour of a feature for a theme.
  static Color colorFor(FeatureKind k, MapPalette p) {
    final base = switch (k) {
      FeatureKind.bush => p.field,
      FeatureKind.rocks => p.ground,
      FeatureKind.lilypad => p.water,
      FeatureKind.sapling => p.forest,
      FeatureKind.sandcastle => p.sand,
      FeatureKind.grate => p.roadMinor,
    };
    final light = HSLColor.fromColor(p.ground).lightness > 0.5;
    var hsl = HSLColor.fromColor(base);
    // The theme's own colour: the ground's hue where it has one, else the
    // theme's accent (dark themes' grounds are near-black greys, which
    // would make every feature plain grey).
    if (hsl.saturation < 0.18) {
      final a = HSLColor.fromColor(p.accent);
      hsl = hsl.withHue(a.hue).withSaturation((a.saturation * 0.55).clamp(0.25, 0.6));
    } else {
      hsl = hsl.withSaturation(hsl.saturation.clamp(0.3, 0.85));
    }
    // Half-way to black on light themes, half-way to white on dark ones.
    final l = light ? hsl.lightness * 0.5 : hsl.lightness + (1 - hsl.lightness) * 0.5;
    return hsl.withLightness(l.clamp(0.0, 1.0)).toColor();
  }

  static FeatureMesh of(FeatureKind k, int variant, Color c) {
    final v = variant % variants;
    final key = Object.hash(k, v, c.toARGB32());
    return _cache[key] ??= FeatureMesh(_build(k, v, c));
  }

  static Color _tone(Color c, double amount) => Color.lerp(c, amount < 0 ? const Color(0xFF000000) : const Color(0xFFFFFFFF), amount.abs())!;

  static LowPolyMesh _build(FeatureKind k, int v, Color c) {
    final m = LowPolyMesh();
    final dark = _tone(c, -0.22), lightC = _tone(c, 0.2);
    switch (k) {
      case FeatureKind.bush:
        m.ellipsoid(0, 0, 2.7, 4.4, 4.0, 3.1, c, lat: 3, lon: 6, jitter: 0.28, seed: 11 + v);
        m.ellipsoid(3.1, 1.0, 1.9, 2.7, 2.5, 2.2, lightC, lat: 3, lon: 5, jitter: 0.3, seed: 21 + v);
        m.ellipsoid(-2.7, -1.5, 1.7, 2.5, 2.6, 2.0, dark, lat: 3, lon: 5, jitter: 0.3, seed: 31 + v);
        if (v != 0) m.ellipsoid(0.4, -3.0, 1.4, 2.0, 1.8, 1.6, c, lat: 3, lon: 5, jitter: 0.3, seed: 41 + v);
      case FeatureKind.rocks:
        m.ellipsoid(0, 0, 1.9, 3.5, 2.9, 2.8, c, lat: 3, lon: 5, jitter: 0.5, seed: 12 + v);
        m.ellipsoid(3.3, 1.2, 1.1, 2.3, 2.0, 1.7, dark, lat: 3, lon: 5, jitter: 0.5, seed: 22 + v);
        m.ellipsoid(-2.9, 1.4, 1.0, 2.1, 2.3, 1.5, lightC, lat: 3, lon: 5, jitter: 0.5, seed: 32 + v);
        m.ellipsoid(0.6, -2.9, 0.8, 1.8, 1.6, 1.2, c, lat: 3, lon: 5, jitter: 0.5, seed: 42 + v);
        if (v == 2) m.ellipsoid(-0.4, 0.3, 4.2, 1.6, 1.5, 1.4, dark, lat: 3, lon: 5, jitter: 0.5, seed: 52);
      case FeatureKind.lilypad:
        // One big round pad with a notch, a small one floating beside it,
        // and a flower bud.
        _pad(m, 0, 0, 5.2, 0.35 + v * 0.7, c, dark);
        _pad(m, 7.6, -2.2 + v, 2.3, 2.4 + v, c, dark);
        m.prism(-1.4, 0.8, 0.4, 2.3, 1.2, 0, 5, lightC);
      case FeatureKind.sapling:
        final lean = (v - 1) * 0.5;
        m.tube([0, 0, 0], [lean, 0, 7.4], 0.5, 0.28, 5, dark);
        m.tube([lean * 0.6, 0, 4.4], [lean + 2.0, 0.6, 6.4], 0.22, 0.12, 4, dark, caps: false);
        m.ellipsoid(lean, 0, 8.6, 2.0, 1.9, 1.7, c, lat: 3, lon: 5, jitter: 0.3, seed: 13 + v);
        m.ellipsoid(lean + 2.3, 0.7, 6.9, 1.5, 1.4, 1.1, lightC, lat: 3, lon: 5, jitter: 0.3, seed: 23 + v);
        if (v != 2) m.ellipsoid(lean - 1.6, -0.5, 6.6, 1.4, 1.3, 1.0, c, lat: 3, lon: 5, jitter: 0.3, seed: 33 + v);
      case FeatureKind.sandcastle:
        m.box(0, 0, 0, 8.2, 8.2, 2.3, c);
        for (final (x, y) in const [(-3.6, -3.6), (3.6, -3.6), (3.6, 3.6), (-3.6, 3.6)]) {
          m.prism(x, y, 0, 4.3, 1.55, 1.4, 6, lightC);
          m.prism(x, y, 4.3, 6.3, 1.9, 0, 6, dark);
        }
        m.box(0, 0, 2.3, 3.8, 3.8, 3.2 + v * 0.5, c);
        m.prism(0, 0, 5.5 + v * 0.5, 8.0 + v * 0.5, 2.6, 0, 4, dark, rot: math.pi / 4);
        // A little flag.
        m.tube([0, 0, 7.8 + v * 0.5], [0, 0, 10.6 + v * 0.5], 0.14, 0.14, 3, dark);
        m.tri([0, 0, 10.5 + v * 0.5], [1.9, 0, 9.9 + v * 0.5], [0, 0, 9.3 + v * 0.5], lightC, [0.6, -0.4, 9.9 + v * 0.5]);
        m.tri([0, 0, 10.5 + v * 0.5], [1.9, 0, 9.9 + v * 0.5], [0, 0, 9.3 + v * 0.5], lightC, [0.6, 0.4, 9.9 + v * 0.5]);
      case FeatureKind.grate:
        // A round cover set in the street: rim, a darker inside, bars.
        m.prism(0, 0, 0.02, 0.4, 4.8, 4.8, 10, c, capColor: c);
        m.prism(0, 0, 0.4, 0.46, 4.0, 4.0, 10, dark, capColor: _tone(c, -0.45));
        for (var i = -2; i <= 2; i++) {
          final half = math.sqrt(math.max(0.0, 3.8 * 3.8 - (i * 1.4) * (i * 1.4)));
          m.box(i * 1.4, 0, 0.46, 0.5, half * 2, 0.14, lightC);
        }
        if (v == 1) m.box(0, 0, 0.6, 7.4, 0.5, 0.1, lightC);
    }
    return m;
  }

  /// A flat lily pad: a disc with a wedge cut out of it.
  static void _pad(LowPolyMesh m, double x, double y, double r, double rot, Color top, Color side) {
    const segs = 11;
    const span = 2 * math.pi * 0.9;
    const z0 = 0.08, z1 = 0.4;
    final centre = [x, y, (z0 + z1) / 2];
    List<double> p(int i, double z) => [x + math.cos(rot + i * span / segs) * r, y + math.sin(rot + i * span / segs) * r, z];
    for (var i = 0; i < segs; i++) {
      m.tri([x, y, z1], p(i, z1), p(i + 1, z1), top, [x, y, z0 - 1]);
      m.tri(p(i, z0), p(i + 1, z0), p(i + 1, z1), side, centre);
      m.tri(p(i, z0), p(i + 1, z1), p(i, z1), side, centre);
    }
  }
}

/// Draws the map's features with the map camera. [front] picks the ones
/// nearer the camera than the player (drawn over the player) or the ones
/// behind.
class FeaturesPainter extends CustomPainter {
  FeaturesPainter({required this.camera, required this.features, required this.palette, required this.front, super.repaint});
  final Camera3D camera;
  final List<MapFeature> features;
  final MapPalette palette;
  final bool front;

  /// How far away features are still drawn (they fade out over the last
  /// stretch).
  static const maxDistance = 400.0;
  static const _lx = -0.38, _ly = 0.48, _lz = 0.79;

  static Float32List _pos = Float32List(1 << 15);
  static Int32List _col = Int32List(1 << 14);
  static Float64List _depth = Float64List(1 << 12);

  static void _grow(int tris) {
    if (_depth.length >= tris) return;
    var n = _depth.length;
    while (n < tris) {
      n *= 2;
    }
    _pos = Float32List(n * 6)..setAll(0, _pos);
    _col = Int32List(n * 3)..setAll(0, _col);
    _depth = Float64List(n)..setAll(0, _depth);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (features.isEmpty) return;
    final cam = camera
      ..size = size
      ..update();
    final br = cam.bearing * math.pi / 180, pr = cam.pitch * math.pi / 180;
    final back = cam.distance * math.cos(pr);
    final camX = cam.px - math.sin(br) * back, camY = cam.py - math.cos(br) * back, camZ = cam.distance * math.sin(pr);
    var tris = 0;
    final colors = <FeatureKind, Color>{};
    for (final f in features) {
      final dx = f.x - cam.px, dy = f.y - cam.py;
      final d2 = dx * dx + dy * dy;
      if (d2 > maxDistance * maxDistance) continue;
      final ya = cam.alignY(f.x, f.y);
      if ((ya < 0) != front) continue;
      if (ya < cam.yNear + 6) continue;
      final zc0 = cam.depth(ya, 0);
      if (zc0 <= 2) continue;
      final sx0 = cam.sx(cam.alignX(f.x, f.y), zc0);
      if (sx0 < -60 || sx0 > size.width + 60) continue;
      final d = math.sqrt(d2);
      final alpha = ((maxDistance - d) / 90).clamp(0.0, 1.0);
      if (alpha <= 0.02) continue;
      var c = colors[f.kind] ??= FeatureMeshes.colorFor(f.kind, palette);
      // The glowing ones are a touch brighter.
      if (f.glow) c = Color.lerp(c, palette.accent, 0.35)!;
      final variant = f.feature.variant;
      final mesh = FeatureMeshes.of(f.kind, variant, c);
      final yaw = (variant % 628) / 100.0;
      final scale = 0.85 + ((variant >> 8) % 100) / 100 * 0.4;
      final cy = math.cos(yaw), sy = math.sin(yaw);
      _grow(tris + mesh.n);
      final v = mesh.v, nm = mesh.normal;
      for (var t = 0; t < mesh.n; t++) {
        final nx0 = nm[t * 3], ny0 = nm[t * 3 + 1], nz = nm[t * 3 + 2];
        if (nx0 == 0 && ny0 == 0 && nz == 0) continue;
        final nx = nx0 * cy - ny0 * sy, ny = nx0 * sy + ny0 * cy;
        final o = t * 9;
        var ok = true;
        var zsum = 0.0, fx = 0.0, fy = 0.0, fz = 0.0;
        final q = tris * 6;
        for (var k = 0; k < 3; k++) {
          final lx = v[o + k * 3] * scale, ly = v[o + k * 3 + 1] * scale, lz = v[o + k * 3 + 2] * scale;
          final wx = f.x + lx * cy - ly * sy, wy = f.y + lx * sy + ly * cy;
          fx += wx;
          fy += wy;
          fz += lz;
          final xa = cam.alignX(wx, wy), yb = cam.alignY(wx, wy);
          final zc = cam.depth(yb, lz);
          if (zc <= 2 || yb < cam.yNear) {
            ok = false;
            break;
          }
          zsum += zc;
          _pos[q + k * 2] = cam.sx(xa, zc);
          _pos[q + k * 2 + 1] = cam.sy(yb, lz, zc);
        }
        if (!ok) continue;
        // Back faces aren't drawn.
        if (nx * (camX - fx / 3) + ny * (camY - fy / 3) + nz * (camZ - fz / 3) <= 0) continue;
        // Slightly shaded: mostly its own colour, a little darker away
        // from the light.
        final shade = 0.74 + 0.26 * math.max(0.0, nx * _lx + ny * _ly + nz * _lz);
        final base = mesh.color[t];
        final argb = ((alpha * 255).round() << 24) |
            ((base.r * shade * 255).round().clamp(0, 255) << 16) |
            ((base.g * shade * 255).round().clamp(0, 255) << 8) |
            (base.b * shade * 255).round().clamp(0, 255);
        _col[tris * 3] = argb;
        _col[tris * 3 + 1] = argb;
        _col[tris * 3 + 2] = argb;
        _depth[tris] = zsum / 3;
        tris++;
      }
    }
    if (tris == 0) return;
    // Far to near.
    final order = List<int>.generate(tris, (i) => i)..sort((a, b) => _depth[b].compareTo(_depth[a]));
    final op = Float32List(tris * 6);
    final oc = Int32List(tris * 3);
    for (var i = 0; i < tris; i++) {
      final s = order[i];
      op.setRange(i * 6, i * 6 + 6, _pos, s * 6);
      oc.setRange(i * 3, i * 3 + 3, _col, s * 3);
    }
    canvas.drawVertices(Vertices.raw(VertexMode.triangles, op, colors: oc), BlendMode.dst, Paint());
  }

  @override
  bool shouldRepaint(FeaturesPainter old) => true;
}

/// The very faint glow under the features that have something to give.
class FeatureGlowPainter extends CustomPainter {
  FeatureGlowPainter({required this.camera, required this.features, required this.color, required this.time});
  final Camera3D camera;
  final List<MapFeature> features;
  final Color color;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final squash = math.sin(cam.pitch * math.pi / 180).clamp(0.35, 1.0);
    for (final f in features) {
      if (!f.glow) continue;
      final dx = f.x - cam.px, dy = f.y - cam.py;
      if (dx * dx + dy * dy > FeaturesPainter.maxDistance * FeaturesPainter.maxDistance) continue;
      final p = cam.project(f.x, f.y);
      if (p == null || p.dx < -80 || p.dx > size.width + 80 || p.dy < -80 || p.dy > size.height + 80) continue;
      final r = 17.0 * cam.scaleAt(f.x, f.y);
      if (r < 2) continue;
      final pulse = 0.5 + 0.5 * math.sin(time * 1.7 + (f.feature.variant % 100) * 0.3);
      final rect = Rect.fromCenter(center: p.translate(0, -r * 0.18), width: r * 2, height: r * 2 * squash);
      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.34 + 0.12 * pulse), color.withValues(alpha: 0.13), color.withValues(alpha: 0)], stops: const [0, 0.55, 1])
              .createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(FeatureGlowPainter old) => true;
}
