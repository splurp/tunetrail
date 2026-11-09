import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Low-poly 3D clothing and backpacks for the stick figure, built per frame
/// around the posed skeleton in the figure's local frame
/// (forward, right, up metres).
class OutfitTri {
  OutfitTri(this.a, this.b, this.c, this.color, this.center);
  final (double, double, double) a, b, c;
  final Color color;

  /// Centre of the convex part this face belongs to (for outward normals).
  final (double, double, double) center;
}

typedef V3 = (double, double, double);

V3 _add(V3 a, V3 b) => (a.$1 + b.$1, a.$2 + b.$2, a.$3 + b.$3);
V3 _sub(V3 a, V3 b) => (a.$1 - b.$1, a.$2 - b.$2, a.$3 - b.$3);
V3 _mul(V3 a, double k) => (a.$1 * k, a.$2 * k, a.$3 * k);
V3 _lerp(V3 a, V3 b, double t) => _add(a, _mul(_sub(b, a), t));
V3 _norm(V3 a) {
  final l = math.sqrt(a.$1 * a.$1 + a.$2 * a.$2 + a.$3 * a.$3);
  return l < 1e-9 ? (0, 0, 1) : _mul(a, 1 / l);
}

V3 _cross(V3 a, V3 b) => (a.$2 * b.$3 - a.$3 * b.$2, a.$3 * b.$1 - a.$1 * b.$3, a.$1 * b.$2 - a.$2 * b.$1);

class OutfitBuilder {
  final List<OutfitTri> tris = [];

  /// Elliptical tube between ring centres [p0] → [p1] with semi-axes along
  /// local forward (fa) and right (ra); [colorAt] picks each face's colour
  /// from its ring segment and angle.
  void torso(List<(V3, double, double)> rings, int sides, Color Function(int ring, int side) colorAt, {bool capTop = true, bool capBottom = true}) {
    final centre = _mul(rings.fold<V3>((0, 0, 0), (s, r) => _add(s, r.$1)), 1 / rings.length);
    List<V3> ring(int i) {
      final (c, fa, ra) = rings[i];
      return [for (var k = 0; k < sides; k++) _add(c, (math.cos(k * 2 * math.pi / sides) * fa, math.sin(k * 2 * math.pi / sides) * ra, 0))];
    }

    final rs = [for (var i = 0; i < rings.length; i++) ring(i)];
    for (var i = 0; i + 1 < rs.length; i++) {
      for (var k = 0; k < sides; k++) {
        final a = rs[i][k], b = rs[i][(k + 1) % sides], c = rs[i + 1][(k + 1) % sides], d = rs[i + 1][k];
        final col = colorAt(i, k);
        tris
          ..add(OutfitTri(a, b, c, col, centre))
          ..add(OutfitTri(a, c, d, col, centre));
      }
    }
    void cap(List<V3> r, V3 c, Color col) {
      for (var k = 0; k < sides; k++) {
        tris.add(OutfitTri(c, r[k], r[(k + 1) % sides], col, centre));
      }
    }

    if (capTop) cap(rs.last, rings.last.$1, colorAt(rings.length - 2, 0));
    if (capBottom) cap(rs.first, rings.first.$1, colorAt(0, 0));
  }

  /// Round tube along an arbitrary axis (sleeves, straps, cylinders).
  void tube(V3 p0, V3 p1, double r0, double r1, int sides, Color color, {bool caps = true}) {
    final axis = _norm(_sub(p1, p0));
    final ref = axis.$3.abs() > 0.9 ? (1.0, 0.0, 0.0) : (0.0, 0.0, 1.0);
    final u = _norm(_cross(axis, ref)), v = _cross(axis, u);
    final centre = _lerp(p0, p1, 0.5);
    V3 at(V3 c, double r, int k) {
      final a = k * 2 * math.pi / sides;
      return _add(c, _add(_mul(u, math.cos(a) * r), _mul(v, math.sin(a) * r)));
    }

    for (var k = 0; k < sides; k++) {
      final a = at(p0, r0, k), b = at(p0, r0, k + 1), c = at(p1, r1, k + 1), d = at(p1, r1, k);
      tris
        ..add(OutfitTri(a, b, c, color, centre))
        ..add(OutfitTri(a, c, d, color, centre));
      if (caps) {
        tris
          ..add(OutfitTri(p0, b, a, color, centre))
          ..add(OutfitTri(p1, d, c, color, centre));
      }
    }
  }

  /// Box centred at [c] with half-sizes along forward / right / up.
  void box(V3 c, double hf, double hr, double hz, Color color, {Color? front, Color? top}) {
    final p = [
      for (final sf in [-1, 1])
        for (final sr in [-1, 1])
          for (final sz in [-1, 1]) _add(c, (sf * hf, sr * hr, sz * hz))
    ];
    // index = (sf>0)*4 + (sr>0)*2 + (sz>0)
    void quad(int a, int b, int d, int e, Color col) {
      tris
        ..add(OutfitTri(p[a], p[b], p[d], col, c))
        ..add(OutfitTri(p[a], p[d], p[e], col, c));
    }

    quad(0, 1, 3, 2, color); // back (−forward)
    quad(4, 6, 7, 5, front ?? color); // front
    quad(0, 4, 5, 1, color); // left
    quad(2, 3, 7, 6, color); // right
    quad(1, 5, 7, 3, top ?? color); // top
    quad(0, 2, 6, 4, color); // bottom
  }

  /// Small low-poly sphere (pom-poms, gems).
  void blob(V3 c, double radius, Color color) {
    const lat = 4, lon = 6;
    torso([
      for (var i = 0; i <= lat; i++)
        (_add(c, (0, 0, -radius * math.cos(i * math.pi / lat))), radius * math.sin(i * math.pi / lat) + 1e-4, radius * math.sin(i * math.pi / lat) + 1e-4)
    ], lon, (a, b) => color, capTop: false, capBottom: false);
  }

  /// Flat (double-sided) quad, e.g. wings.
  void panel(V3 a, V3 b, V3 c, V3 d, Color color) {
    final centre = _mul(_add(_add(a, b), _add(c, d)), 0.25);
    final n = _norm(_cross(_sub(b, a), _sub(d, a)));
    final off = _mul(n, 0.02);
    tris
      ..add(OutfitTri(a, b, c, color, _sub(centre, off)))
      ..add(OutfitTri(a, c, d, color, _sub(centre, off)))
      ..add(OutfitTri(a, c, b, color, _add(centre, off)))
      ..add(OutfitTri(a, d, c, color, _add(centre, off)));
  }
}

Color _shade(Color c, double k) => Color.fromARGB(255, (c.r * 255 * k).round().clamp(0, 255), (c.g * 255 * k).round().clamp(0, 255), (c.b * 255 * k).round().clamp(0, 255));

/// Shirt: a tapered elliptical torso from the neck to just below the hips,
/// plus sleeves over the upper arms, in the shirt's colours and pattern.
void buildShirt(OutfitBuilder o, String id, Map<String, V3> j, double s, Color base) {
  final neck = j['neck']!, sh = j['shoulder']!, hip = j['hip']!;
  final hem = _add(hip, (0, 0, -0.35 * s));
  final collar = _lerp(sh, neck, 0.7);
  const sides = 10;
  // Rings: collar, shoulders, chest, waist, hem.
  final rings = <(V3, double, double)>[
    (hem, 0.62 * s, 0.98 * s),
    (_lerp(hem, sh, 0.33), 0.6 * s, 0.95 * s),
    (_lerp(hem, sh, 0.66), 0.66 * s, 1.05 * s),
    (sh, 0.62 * s, 1.12 * s),
    (collar, 0.38 * s, 0.5 * s),
  ];
  final hawaii = [const Color(0xFF26A69A), const Color(0xFFFFCA28), const Color(0xFFEF5350), const Color(0xFF26A69A), const Color(0xFF66BB6A)];
  Color colorAt(int ring, int side) {
    // side 0 points forward; sides near 0 / sides are the chest.
    final front = side <= 1 || side >= sides - 1;
    switch (id) {
      case 'shirt_striped':
        return ring.isEven ? const Color(0xFF1E88E5) : const Color(0xFFFAFAFA);
      case 'shirt_rainbow':
        return HSLColor.fromAHSL(1, (ring * 70.0 + side * 8) % 360, 0.85, 0.58).toColor();
      case 'shirt_hawaiian':
        return hawaii[(ring * 3 + side * 7) % hawaii.length];
      case 'shirt_tux':
        return front && ring >= 1 ? (side == 0 && ring == 2 ? const Color(0xFFB71C1C) : const Color(0xFFF5F5F5)) : const Color(0xFF111111);
      case 'shirt_lightning':
        return front && (ring == 1 || ring == 2) ? const Color(0xFFFFD600) : base;
      case 'shirt_tee_black':
        return front && ring == 2 ? const Color(0xFFE0E0E0) : base;
      default:
        return ring == rings.length - 2 && id == 'shirt_hoodie' ? _shade(base, 0.85) : base;
    }
  }

  o.torso(rings, sides, colorAt, capTop: true, capBottom: false);
  // Sleeves: from the shoulder towards the elbow (long sleeves for the
  // hoodie and tux).
  final long = id == 'shirt_hoodie' || id == 'shirt_tux';
  final sleeveColor = switch (id) {
    'shirt_striped' => const Color(0xFF1E88E5),
    'shirt_rainbow' => const Color(0xFF7C4DFF),
    'shirt_hawaiian' => const Color(0xFF26A69A),
    _ => base,
  };
  for (final side in ['L', 'R']) {
    final el = j['elbow$side']!, hand = j['hand$side']!;
    // Sleeves start at the torso's side surface (not inside it) so they
    // don't cut through the shirt as the arms swing.
    final start = _add(sh, (0, (side == 'L' ? -1 : 1) * 1.06 * s, -0.2 * s));
    final end = long ? _lerp(el, hand, 0.75) : _lerp(start, el, 0.62);
    o.tube(start, long ? el : end, 0.42 * s, long ? 0.38 * s : 0.38 * s, 6, sleeveColor);
    if (long) o.tube(el, end, 0.38 * s, 0.34 * s, 6, sleeveColor);
  }
  if (id == 'shirt_hoodie') {
    // Hood resting on the upper back.
    o.tube(_add(neck, (-0.55 * s, 0, -0.2 * s)), _add(neck, (-0.75 * s, 0, 0.5 * s)), 0.55 * s, 0.3 * s, 7, _shade(base, 0.8));
  }
}

/// Backpacks sit on the figure's back (−forward) between the shoulders and
/// hips, with straps over the shoulders.
void buildBackpack(OutfitBuilder o, String id, Map<String, V3> j, double s, double time, bool walking) {
  final sh = j['shoulder']!, hip = j['hip']!;
  final mid = _lerp(hip, sh, 0.55);
  final backZ = -0.62 * s; // the torso's back surface
  V3 back(double f, double r, double z) => _add(mid, (backZ + f, r, z));
  switch (id) {
    case 'bag_classic':
      o.box(back(-0.45 * s, 0, 0), 0.45 * s, 0.85 * s, 1.15 * s, const Color(0xFF1565C0), top: const Color(0xFF0D47A1));
      o.box(back(-0.98 * s, 0, -0.45 * s), 0.12 * s, 0.6 * s, 0.45 * s, const Color(0xFF1E88E5));
    case 'bag_boombox':
      o.box(back(-0.5 * s, 0, 0.1 * s), 0.5 * s, 1.35 * s, 0.85 * s, const Color(0xFF424242), top: const Color(0xFF616161));
      for (final r in [-0.75, 0.75]) {
        o.tube(back(-1.0 * s, r * s, 0.05 * s), back(-1.08 * s, r * s, 0.05 * s), 0.42 * s, 0.42 * s, 10, const Color(0xFF9E9E9E));
        o.tube(back(-1.08 * s, r * s, 0.05 * s), back(-1.12 * s, r * s, 0.05 * s), 0.22 * s, 0.22 * s, 8, const Color(0xFF212121));
      }
    case 'bag_guitar':
      // A guitar case slung diagonally.
      o.tube(back(-0.35 * s, -0.9 * s, -1.6 * s), back(-0.35 * s, 0.7 * s, 1.9 * s), 0.75 * s, 0.4 * s, 8, const Color(0xFF6D4C41));
    case 'bag_crate':
      o.box(back(-0.6 * s, 0, 0), 0.6 * s, 0.95 * s, 0.95 * s, const Color(0xFFA1887F), top: const Color(0xFF8D6E63));
      for (var i = 0; i < 4; i++) {
        o.box(back(-0.6 * s, (-0.6 + i * 0.4) * s, 0.75 * s), 0.5 * s, 0.03 * s, 0.4 * s, const Color(0xFF111111), front: const Color(0xFFE53935));
      }
    case 'bag_jetpack':
      for (final r in [-0.5, 0.5]) {
        o.tube(back(-0.5 * s, r * s, -1.1 * s), back(-0.5 * s, r * s, 1.0 * s), 0.42 * s, 0.42 * s, 8, const Color(0xFFB0BEC5));
        o.tube(back(-0.5 * s, r * s, -1.1 * s), back(-0.5 * s, r * s, -1.5 * s), 0.3 * s, 0.22 * s, 8, const Color(0xFF546E7A));
        // Flame flicker.
        final flick = 0.6 + 0.4 * math.sin(time * 30 + r * 7).abs();
        o.tube(back(-0.5 * s, r * s, -1.5 * s), back(-0.5 * s, r * s, (-1.5 - 1.1 * flick) * s), 0.22 * s, 0.02 * s, 6, const Color(0xFFFF9100), caps: false);
      }
    case 'bag_wings':
      final flap = walking ? math.sin(time * 9) * 0.25 : math.sin(time * 2) * 0.08;
      for (final side in [-1.0, 1.0]) {
        final root = back(-0.2 * s, side * 0.3 * s, 0.6 * s);
        final tip = back((-1.2 - flap * 2) * s, side * 3.4 * s, (1.6 + flap * 3) * s);
        final low = back((-0.9 - flap) * s, side * 2.6 * s, -0.9 * s);
        o.panel(root, tip, low, back(-0.3 * s, side * 0.4 * s, -0.5 * s), const Color(0xFFFAFAFA));
      }
      return; // wings have no straps
    default:
      o.box(back(-0.45 * s, 0, 0), 0.45 * s, 0.8 * s, 1.0 * s, const Color(0xFF616161));
  }
  // Shoulder straps: from the top of the pack over the shoulder, down the
  // chest, then under the arm and back round to the bottom of the pack.
  const strap = Color(0xFF263238);
  for (final side in [-1.0, 1.0]) {
    final pts = <V3>[
      _add(sh, (backZ - 0.05 * s, side * 0.6 * s, 0.15 * s)),
      _add(sh, (-0.1 * s, side * 0.64 * s, 0.6 * s)),
      _add(sh, (0.66 * s, side * 0.62 * s, 0.05 * s)),
      _add(sh, (0.7 * s, side * 0.72 * s, -1.1 * s)),
      // Round the ribs, hugging the torso (inside the arm, which hangs
      // clear of it), and back to the bottom of the pack.
      _add(sh, (0.1 * s, side * 1.12 * s, -1.35 * s)),
      _add(sh, (backZ - 0.05 * s, side * 0.86 * s, -1.7 * s)),
    ];
    for (var i = 0; i + 1 < pts.length; i++) {
      o.tube(pts[i], pts[i + 1], 0.12 * s, 0.12 * s, 4, strap);
    }
  }
}

/// 3D hats sitting on the head sphere ([head] centre, radius [r]) and
/// facing the figure's forward (+f) direction, so they turn with the player.
void buildHat(OutfitBuilder o, String id, V3 head, double r, double time) {
  V3 at(double f, double rt, double z) => _add(head, (f * r, rt * r, z * r));
  void dome(double z0, double radius, double height, Color c, {int rings = 4, Color? band}) {
    o.torso([
      for (var i = 0; i <= rings; i++)
        (at(0, 0, z0 + height * math.sin(i / rings * math.pi / 2)), radius * r * math.cos(i / rings * math.pi / 2) + 0.02 * r, radius * r * math.cos(i / rings * math.pi / 2) + 0.02 * r)
    ], 10, (ring, side) => ring == 0 && band != null ? band : c, capTop: true, capBottom: false);
  }

  void disk(double z, double rf, double rr, double thick, Color c, {double f = 0}) {
    o.torso([(at(f, 0, z - thick / 2), rf * r, rr * r), (at(f, 0, z + thick / 2), rf * r, rr * r)], 14, (a, b) => c);
  }

  switch (id) {
    case 'hat_cap':
      dome(0.15, 1.04, 0.95, const Color(0xFFE53935));
      o.panel(at(0.55, -0.75, 0.32), at(0.55, 0.75, 0.32), at(1.75, 0.6, 0.18), at(1.75, -0.6, 0.18), const Color(0xFFC62828));
      o.tube(at(0, 0, 1.08), at(0, 0, 1.18), 0.13 * r, 0.1 * r, 6, Colors.white);
    case 'hat_beanie':
      dome(0.05, 1.08, 1.15, const Color(0xFF43A047), band: const Color(0xFF2E7D32));
      o.tube(at(0, 0, 1.15), at(0, 0, 1.45), 0.28 * r, 0.22 * r, 6, const Color(0xFF66BB6A));
    case 'hat_headphones':
      // Band over the top, ear cups at the sides.
      const n = 6;
      for (var i = 0; i < n; i++) {
        final a0 = math.pi * i / n, a1 = math.pi * (i + 1) / n;
        o.tube(at(0, -math.cos(a0) * 1.12, math.sin(a0) * 1.12), at(0, -math.cos(a1) * 1.12, math.sin(a1) * 1.12), 0.13 * r, 0.13 * r, 5, const Color(0xFF212121));
      }
      for (final sd in [-1.0, 1.0]) {
        o.tube(at(0, sd * 0.98, 0), at(0, sd * 1.32, 0), 0.42 * r, 0.42 * r, 10, const Color(0xFF00E5FF));
      }
    case 'hat_tophat':
      disk(0.72, 1.5, 1.5, 0.08, const Color(0xFF263238));
      o.torso([(at(0, 0, 0.72), 0.82 * r, 0.82 * r), (at(0, 0, 0.98), 0.82 * r, 0.82 * r)], 12, (a, b) => const Color(0xFFD32F2F), capTop: false, capBottom: false);
      o.torso([(at(0, 0, 0.98), 0.82 * r, 0.82 * r), (at(0, 0, 2.3), 0.86 * r, 0.86 * r)], 12, (a, b) => const Color(0xFF263238));
    case 'hat_cowboy':
      disk(0.62, 2.0, 1.75, 0.08, const Color(0xFF8D6E63));
      o.torso([(at(0, 0, 0.62), 0.92 * r, 0.82 * r), (at(0, 0, 0.8), 0.92 * r, 0.82 * r)], 12, (a, b) => const Color(0xFF4E342E), capTop: false, capBottom: false);
      o.torso([(at(0, 0, 0.8), 0.92 * r, 0.82 * r), (at(0, 0, 1.6), 0.7 * r, 0.62 * r)], 12, (a, b) => const Color(0xFF8D6E63));
    case 'hat_party':
      o.tube(at(0.05, 0.1, 0.72), at(0.15, 0.25, 2.35), 0.72 * r, 0.03 * r, 10, const Color(0xFFFFEB3B));
      o.blob(at(0.15, 0.25, 2.42), 0.24 * r, const Color(0xFFE91E63));
    case 'hat_wizard':
      disk(0.68, 1.55, 1.55, 0.07, const Color(0xFF5E35B1));
      o.tube(at(0, 0, 0.7), at(-0.2, 0, 1.8), 0.85 * r, 0.45 * r, 10, const Color(0xFF5E35B1));
      o.tube(at(-0.2, 0, 1.8), at(-0.75, 0.1, 2.9), 0.45 * r, 0.04 * r, 8, const Color(0xFF5E35B1));
      o.blob(at(0.7, -0.3, 1.2), 0.16 * r, const Color(0xFFFFEB3B));
    case 'hat_crown':
      o.torso([(at(0, 0, 0.7), 0.9 * r, 0.9 * r), (at(0, 0, 1.05), 0.95 * r, 0.95 * r)], 12, (a, b) => const Color(0xFFFFC107), capTop: false, capBottom: false);
      for (var k = 0; k < 6; k++) {
        final a = k * math.pi / 3;
        o.tube(at(math.cos(a) * 0.92, math.sin(a) * 0.92, 1.0), at(math.cos(a) * 0.98, math.sin(a) * 0.98, 1.55), 0.2 * r, 0.02 * r, 5, const Color(0xFFFFC107));
        o.blob(at(math.cos(a) * 0.97, math.sin(a) * 0.97, 0.85), 0.1 * r, k.isEven ? const Color(0xFFE53935) : const Color(0xFF1E88E5));
      }
    case 'hat_halo':
      final bob = math.sin(time * 2) * 0.06;
      const n = 12;
      for (var i = 0; i < n; i++) {
        final a0 = i * 2 * math.pi / n, a1 = (i + 1) * 2 * math.pi / n;
        o.tube(at(math.cos(a0) * 0.85, math.sin(a0) * 0.85, 1.55 + bob), at(math.cos(a1) * 0.85, math.sin(a1) * 0.85, 1.55 + bob), 0.11 * r, 0.11 * r, 5,
            const Color(0xFFFFF59D));
      }
  }
}
