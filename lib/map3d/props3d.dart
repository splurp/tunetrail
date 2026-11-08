import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/rendering.dart';

import 'camera.dart';

/// Which set of 3D props stands on the ground for a theme.
enum PropSet { none, vaporMonuments, sakuraTrees }

/// A flat-shaded low-poly mesh: a soup of triangles in local metres
/// (x east, y north, z up). Each triangle also records the centre of the
/// convex part it belongs to, so outward normals (for lighting and
/// back-face culling) don't depend on winding order.
class LowPolyMesh {
  final List<double> v = []; // 9 per triangle
  final List<double> c = []; // 3 per triangle: part centre
  final List<Color> color = [];

  int get triangles => color.length;

  void tri(List<double> a, List<double> b, List<double> d, Color col, List<double> centre) {
    v.addAll([...a, ...b, ...d]);
    c.addAll(centre);
    color.add(col);
  }

  /// Tapered n-sided prism (cylinder) from z0 to z1.
  void prism(
    double x,
    double y,
    double z0,
    double z1,
    double r0,
    double r1,
    int sides,
    Color col, {
    double rot = 0,
    Color? capColor,
    double sx = 1,
    double sy = 1,
  }) {
    final centre = [x, y, (z0 + z1) / 2];
    List<double> p(int i, double z, double r) {
      final a = rot + i * 2 * math.pi / sides;
      return [x + math.cos(a) * r * sx, y + math.sin(a) * r * sy, z];
    }

    for (var i = 0; i < sides; i++) {
      final a0 = p(i, z0, r0), a1 = p(i + 1, z0, r0), b0 = p(i, z1, r1), b1 = p(i + 1, z1, r1);
      tri(a0, a1, b1, col, centre);
      tri(a0, b1, b0, col, centre);
      if (r1 > 0) tri([x, y, z1], b0, b1, capColor ?? col, centre);
      if (r0 > 0) tri([x, y, z0], a1, a0, capColor ?? col, centre);
    }
  }

  /// Axis-aligned box.
  void box(double x, double y, double z0, double w, double d, double h, Color col) {
    prism(x, y, z0, z0 + h, math.sqrt2 / 2, math.sqrt2 / 2, 4, col, rot: math.pi / 4, sx: w, sy: d);
  }

  /// Tapered round tube along any axis (arms of drapery, flutes, laurel).
  void tube(List<double> p0, List<double> p1, double r0, double r1, int sides, Color col, {bool caps = true}) {
    final ax = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
    final al = math.sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
    if (al < 1e-9) return;
    final a = [ax[0] / al, ax[1] / al, ax[2] / al];
    final ref = a[2].abs() > 0.9 ? [1.0, 0.0, 0.0] : [0.0, 0.0, 1.0];
    var u = [a[1] * ref[2] - a[2] * ref[1], a[2] * ref[0] - a[0] * ref[2], a[0] * ref[1] - a[1] * ref[0]];
    final ul = math.sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
    u = [u[0] / ul, u[1] / ul, u[2] / ul];
    final v = [a[1] * u[2] - a[2] * u[1], a[2] * u[0] - a[0] * u[2], a[0] * u[1] - a[1] * u[0]];
    final centre = [(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2, (p0[2] + p1[2]) / 2];
    List<double> at(List<double> c, double r, int k) {
      final t = k * 2 * math.pi / sides;
      return [for (var i = 0; i < 3; i++) c[i] + (u[i] * math.cos(t) + v[i] * math.sin(t)) * r];
    }

    for (var k = 0; k < sides; k++) {
      final q0 = at(p0, r0, k), q1 = at(p0, r0, k + 1), q2 = at(p1, r1, k + 1), q3 = at(p1, r1, k);
      tri(q0, q1, q2, col, centre);
      tri(q0, q2, q3, col, centre);
      if (caps) {
        tri(p0, q1, q0, col, centre);
        tri(p1, q3, q2, col, centre);
      }
    }
  }

  /// A surface of revolution-like blob: [radius] gives the distance from
  /// [c] for each direction (theta from +z, phi around z from +y).
  void sculpt(List<double> c, double Function(double theta, double phi) radius, Color Function(double theta, double phi) colorAt,
      {int lat = 14, int lon = 22}) {
    List<double> pt(int i, int j) {
      final th = math.pi * i / lat, ph = 2 * math.pi * j / lon;
      final r = radius(th, ph);
      return [c[0] + r * math.sin(th) * math.sin(ph), c[1] + r * math.sin(th) * math.cos(ph), c[2] + r * math.cos(th)];
    }

    for (var i = 0; i < lat; i++) {
      for (var j = 0; j < lon; j++) {
        final col = colorAt(math.pi * (i + 0.5) / lat, 2 * math.pi * (j + 0.5) / lon);
        final a = pt(i, j), b = pt(i, j + 1), d = pt(i + 1, j + 1), e = pt(i + 1, j);
        if (i != 0) tri(a, b, d, col, c);
        if (i != lat - 1) tri(a, d, e, col, c);
      }
    }
  }

  /// Low-poly ellipsoid with optional vertex jitter for an organic look.
  void ellipsoid(
    double x,
    double y,
    double z,
    double rx,
    double ry,
    double rz,
    Color col, {
    int lat = 4,
    int lon = 7,
    double jitter = 0,
    int seed = 1,
    Color Function(int band)? bandColor,
  }) {
    final centre = [x, y, z];
    final rnd = math.Random(seed);
    final pts = <List<double>>[];
    for (var i = 0; i <= lat; i++) {
      final th = math.pi * i / lat;
      for (var j = 0; j < lon; j++) {
        final ph = 2 * math.pi * (j + (i.isOdd ? 0.5 : 0)) / lon;
        final k = (i == 0 || i == lat) ? 0.0 : 1 + (rnd.nextDouble() - 0.5) * jitter;
        pts.add([
          x + rx * k * math.sin(th) * math.cos(ph),
          y + ry * k * math.sin(th) * math.sin(ph),
          z + rz * (i == 0 || i == lat ? 1 : (1 + (rnd.nextDouble() - 0.5) * jitter)) * math.cos(th),
        ]);
      }
    }
    List<double> at(int i, int j) => pts[i * lon + (j % lon)];
    for (var i = 0; i < lat; i++) {
      final cl = bandColor?.call(i) ?? col;
      for (var j = 0; j < lon; j++) {
        final o = i.isOdd ? 1 : 0;
        if (i != 0) tri(at(i, j), at(i, j + 1), at(i + 1, j + o), cl, centre);
        if (i != lat - 1) tri(at(i, j + 1), at(i + 1, j + 1 + o), at(i + 1, j + o), cl, centre);
      }
    }
  }
}

/// Lighting for a prop set: a key light plus an optional tinted rim light.
class PropLight {
  const PropLight({required this.key, this.ambient = 0.5, this.rim, this.rimColor, this.keyTint, this.fog = const Color(0x00000000)});
  final List<double> key; // world direction *towards* the light (unit)
  final double ambient;
  final List<double>? rim;
  final Color? rimColor, keyTint;
  final Color fog;
}

/// An instance of a mesh in the world.
class PropInstance {
  PropInstance(this.mesh, this.x, this.y, {this.yaw = 0, this.scale = 1, this.alpha = 1});
  final LowPolyMesh mesh;
  final double x, y, yaw, scale;
  double alpha;
}

/// Draws [PropInstance]s with flat shading, back-face culling and
/// back-to-front ordering, using the map's perspective camera.
class PropsPainter extends CustomPainter {
  PropsPainter({required this.camera, required this.set, required this.fog, super.repaint});
  final Camera3D camera;
  final PropSet set;
  final Color fog;

  static final _vapor = _vaporMeshes();

  /// The vaporwave bust mesh (for render checks).
  static LowPolyMesh get bustMesh => _vapor.$1;

  /// Draws one instance (for render checks).
  void debugDraw(Canvas canvas, Size size, PropInstance p) {
    final cam = camera
      ..size = size
      ..update();
    _draw(canvas, cam, p, PropLight(key: _unit([-0.5, 0.6, 0.65]), ambient: 0.62, keyTint: const Color(0xFFFFD6F2), rim: _unit([0.8, -0.3, 0.2]), rimColor: const Color(0xFF48DBFB), fog: fog), size);
  }
  static final _trees = _sakuraMeshes();

  @override
  void paint(Canvas canvas, Size size) {
    if (set == PropSet.none) return;
    final cam = camera
      ..size = size
      ..update();
    final items = switch (set) {
      PropSet.vaporMonuments => _vaporInstances(cam),
      PropSet.sakuraTrees => _treeInstances(cam),
      PropSet.none => const <PropInstance>[],
    };
    final light = switch (set) {
      PropSet.vaporMonuments => PropLight(
        key: _unit([-0.5, 0.6, 0.65]),
        ambient: 0.62,
        keyTint: const Color(0xFFFFD6F2),
        rim: _unit([0.8, -0.3, 0.2]),
        rimColor: const Color(0xFF48DBFB),
        fog: fog,
      ),
      _ => PropLight(key: _unit([-0.4, 0.5, 0.75]), ambient: 0.58, fog: fog),
    };
    // Back to front.
    final depthOf = <PropInstance, double>{for (final p in items) p: cam.depth(cam.alignY(p.x, p.y), 0)};
    items.sort((a, b) => depthOf[b]!.compareTo(depthOf[a]!));
    for (final p in items) {
      _draw(canvas, cam, p, light, size);
    }
  }

  // ------------------------------------------------------------ rendering
  static List<double> _unit(List<double> v) {
    final l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / l, v[1] / l, v[2] / l];
  }

  void _draw(Canvas canvas, Camera3D cam, PropInstance p, PropLight light, Size size) {
    if (p.alpha <= 0.01) return;
    final m = p.mesh;
    final n = m.triangles;
    final cy = math.cos(p.yaw), sy = math.sin(p.yaw);
    // Camera position in world space (for culling).
    final br = cam.bearing * math.pi / 180, pr = cam.pitch * math.pi / 180;
    final back = cam.distance * math.cos(pr);
    final camX = cam.px - math.sin(br) * back, camY = cam.py - math.cos(br) * back, camZ = cam.distance * math.sin(pr);
    final dist = math.sqrt(math.pow(p.x - cam.px, 2) + math.pow(p.y - cam.py, 2));
    // Distance haze: monuments kilometres away sit deep in the fog.
    final fogT = ((dist - 400) / 4500).clamp(0.0, 0.82);

    final pos = <double>[];
    final cols = <int>[];
    final depths = <double>[];
    final w = List<double>.filled(9, 0);
    for (var t = 0; t < n; t++) {
      // To world space.
      for (var k = 0; k < 3; k++) {
        final lx = m.v[t * 9 + k * 3] * p.scale, ly = m.v[t * 9 + k * 3 + 1] * p.scale, lz = m.v[t * 9 + k * 3 + 2] * p.scale;
        w[k * 3] = p.x + lx * cy - ly * sy;
        w[k * 3 + 1] = p.y + lx * sy + ly * cy;
        w[k * 3 + 2] = lz;
      }
      // Normal, oriented away from the part centre.
      final ux = w[3] - w[0], uy = w[4] - w[1], uz = w[5] - w[2];
      final vx = w[6] - w[0], vy = w[7] - w[1], vz = w[8] - w[2];
      var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-9) continue;
      nx /= nl;
      ny /= nl;
      nz /= nl;
      final fx = (w[0] + w[3] + w[6]) / 3, fy = (w[1] + w[4] + w[7]) / 3, fz = (w[2] + w[5] + w[8]) / 3;
      final lcx = m.c[t * 3] * p.scale, lcy = m.c[t * 3 + 1] * p.scale;
      final pcx = p.x + lcx * cy - lcy * sy, pcy = p.y + lcx * sy + lcy * cy, pcz = m.c[t * 3 + 2] * p.scale;
      if (nx * (fx - pcx) + ny * (fy - pcy) + nz * (fz - pcz) < 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
      }
      if (nx * (camX - fx) + ny * (camY - fy) + nz * (camZ - fz) <= 0) continue; // back face
      // Clip to above the ground plane (z >= 0) so buried parts stay hidden.
      final poly = <List<double>>[];
      for (var k = 0; k < 3; k++) {
        final p0 = [w[k * 3], w[k * 3 + 1], w[k * 3 + 2]];
        final k1 = (k + 1) % 3;
        final p1 = [w[k1 * 3], w[k1 * 3 + 1], w[k1 * 3 + 2]];
        if (p0[2] >= 0) poly.add(p0);
        if ((p0[2] >= 0) != (p1[2] >= 0)) {
          final f = p0[2] / (p0[2] - p1[2]);
          poly.add([p0[0] + (p1[0] - p0[0]) * f, p0[1] + (p1[1] - p0[1]) * f, 0]);
        }
      }
      if (poly.length < 3) continue;
      var ok = true;
      var zsum = 0.0;
      final proj = <double>[];
      for (final q in poly) {
        final xa = cam.alignX(q[0], q[1]), ya = cam.alignY(q[0], q[1]);
        final zc = cam.depth(ya, q[2]);
        if (zc <= 2 || ya < cam.yNear) {
          ok = false;
          break;
        }
        zsum += zc;
        proj
          ..add(cam.sx(xa, zc))
          ..add(cam.sy(ya, q[2], zc));
      }
      if (!ok) continue;
      // Shade.
      final base = m.color[t];
      final d = math.max(0.0, nx * light.key[0] + ny * light.key[1] + nz * light.key[2]);
      var r = base.r, g = base.g, b = base.b;
      final kt = light.keyTint;
      final s = light.ambient + (1 - light.ambient) * d;
      r *= s * (kt == null ? 1 : (0.75 + 0.25 * kt.r));
      g *= s * (kt == null ? 1 : (0.75 + 0.25 * kt.g));
      b *= s * (kt == null ? 1 : (0.75 + 0.25 * kt.b));
      final rim = light.rim, rc = light.rimColor;
      if (rim != null && rc != null) {
        final rd = math.max(0.0, nx * rim[0] + ny * rim[1] + nz * rim[2]) * 0.35;
        r += rc.r * rd;
        g += rc.g * rd;
        b += rc.b * rd;
      }
      r += (light.fog.r - r) * fogT;
      g += (light.fog.g - g) * fogT;
      b += (light.fog.b - b) * fogT;
      final a = (base.a * p.alpha).clamp(0.0, 1.0);
      final argb =
          ((a * 255).round() << 24) | ((r.clamp(0.0, 1.0) * 255).round() << 16) | ((g.clamp(0.0, 1.0) * 255).round() << 8) | (b.clamp(0.0, 1.0) * 255).round();
      final depth = zsum / poly.length;
      for (var k = 1; k + 1 < poly.length; k++) {
        pos.addAll([proj[0], proj[1], proj[k * 2], proj[k * 2 + 1], proj[k * 2 + 2], proj[k * 2 + 3]]);
        cols.addAll([argb, argb, argb]);
        depths.add(depth);
      }
    }
    if (depths.isEmpty) return;
    // Painter's sort of the remaining (front-facing) triangles.
    final order = List<int>.generate(depths.length, (i) => i)..sort((a, b) => depths[b].compareTo(depths[a]));
    final op = Float32List(order.length * 6);
    final oc = Int32List(order.length * 3);
    for (var i = 0; i < order.length; i++) {
      final s = order[i];
      for (var k = 0; k < 6; k++) {
        op[i * 6 + k] = pos[s * 6 + k];
      }
      for (var k = 0; k < 3; k++) {
        oc[i * 3 + k] = cols[s * 3 + k];
      }
    }
    final verts = Vertices.raw(VertexMode.triangles, op, colors: oc);
    final paint = Paint();
    if (p.alpha < 0.999) {
      // Fade the whole prop as one layer so its own faces don't show through.
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, p.alpha));
      canvas.drawVertices(Vertices.raw(VertexMode.triangles, op, colors: Int32List.fromList([for (final c in oc) c | 0xFF000000])), BlendMode.dst, paint);
      canvas.restore();
    } else {
      canvas.drawVertices(verts, BlendMode.dst, paint);
    }
  }

  // ------------------------------------------------------------- vaporwave
  static (LowPolyMesh, LowPolyMesh, LowPolyMesh) _vaporMeshes() {
    const marble = Color(0xFFF7F1FB), marbleDark = Color(0xFFE2D4EE), shadow = Color(0xFFC9B6DE), pink = Color(0xFFFFC6EC);
    const laurel = Color(0xFFF3D98B);
    // ---- A classical (Greco-Roman) bust, rising out of the ground. Faces +y.
    final bust = LowPolyMesh();
    // Chest and shoulders under a toga: a broad, rounded torso.
    bust.sculpt([0, 0, 24], (th, ph) {
      final sx = math.sin(th) * math.sin(ph), sy = math.sin(th) * math.cos(ph), sz = math.cos(th);
      // A superellipsoid: broad squared shoulders, shallow front-to-back,
      // with the pectorals swelling slightly forward.
      const p = 3.2;
      var r = 1 / math.pow(math.pow((sx / 80).abs(), p) + math.pow((sy / 38).abs(), p) + math.pow((sz / 50).abs(), p), 1 / p);
      if (sy > 0 && sz > 0) r *= 1 + 0.08 * sy * math.sin(th) * (1 - (sx * 1.6).abs()).clamp(0.0, 1.0);
      return r;
    }, (th, ph) => marble, lat: 14, lon: 28);
    // Toga drapery: folds sweeping from the left shoulder across the chest.
    for (var k = 0; k < 7; k++) {
      final o = k * 7.0;
      bust.tube([-62 + o * 0.6, 34 + k * 1.6, 66 - o * 0.3], [40 + o * 0.5, 44 + k * 0.5, -6 - o], 4.8, 3.8, 6, k.isEven ? marbleDark : marble);
    }
    // Collarbones and neck (with the long neck muscles).
    bust.tube([-34, 30, 70], [-8, 34, 66], 3.8, 3.2, 6, marble);
    bust.tube([34, 30, 70], [8, 34, 66], 3.8, 3.2, 6, marble);
    bust.tube([0, 6, 62], [0, 9, 100], 20, 17, 14, marble);
    bust.tube([-13, 5, 98], [-5, 22, 70], 5.5, 5, 6, marbleDark);
    bust.tube([13, 5, 98], [5, 22, 70], 5.5, 5, 6, marbleDark);
    // Head: an egg shape with a tapering jaw.
    const hc = [0.0, 10.0, 122.0];
    bust.sculpt(hc, (th, ph) {
      final sz = math.cos(th), sy = math.sin(th) * math.cos(ph), sx = math.sin(th) * math.sin(ph);
      var r = 1 / math.sqrt(sx * sx / (23 * 23) + sy * sy / (27 * 27) + sz * sz / (31 * 31));
      if (sz < -0.2) r *= 1 - 0.25 * (-sz - 0.2) * (1 - sy.abs()); // narrower jaw
      if (sy > 0.6 && sz > -0.3 && sz < 0.3) r *= 0.96; // flatter face plane
      return r;
    }, (th, ph) => marble, lat: 14, lon: 22);
    // Face (front is +y): brow ridge, eye sockets, nose, lips, chin, ears.
    bust.tube([-14, 32, 130], [14, 32, 130], 3.2, 3.2, 6, marble);
    for (final x in [-8.5, 8.5]) {
      bust.ellipsoid(x, 31.5, 125, 5, 1.6, 2.6, shadow, lat: 3, lon: 6); // sockets
      bust.ellipsoid(x, 32.4, 125, 2.8, 1.4, 1.7, marbleDark, lat: 3, lon: 6); // eyes
      bust.ellipsoid(x * 2.75, 6, 124, 2.5, 6, 9, marbleDark, lat: 3, lon: 6); // ears
    }
    bust
      ..tri([0, 33, 128], [-3.6, 37, 112], [3.6, 37, 112], marble, [0, 30, 118])
      ..tri([0, 33, 128], [0, 40.5, 112.5], [-3.6, 37, 112], marble, [0, 30, 118])
      ..tri([0, 33, 128], [3.6, 37, 112], [0, 40.5, 112.5], marble, [0, 30, 118])
      ..tri([-3.6, 37, 112], [0, 40.5, 112.5], [3.6, 37, 112], shadow, [0, 30, 118]);
    bust.ellipsoid(0, 34.5, 106.5, 5.5, 2.2, 1.5, marbleDark, lat: 3, lon: 8); // upper lip
    bust.ellipsoid(0, 34, 103.6, 4.6, 2.1, 1.4, marbleDark, lat: 3, lon: 8); // lower lip
    bust.ellipsoid(0, 31, 97, 7, 5, 5, marble, lat: 4, lon: 8); // chin
    // Hair: a cap of tight curls over the crown and back of the head.
    final rnd = math.Random(11);
    for (var ring = 0; ring < 4; ring++) {
      final th = 0.25 + ring * 0.32;
      final n = 6 + ring * 4;
      for (var k = 0; k < n; k++) {
        final ph = (k + (ring.isOdd ? 0.5 : 0)) * 2 * math.pi / n;
        if (math.cos(ph) > 0.55 && ring >= 2) continue; // keep the face clear
        final r = 28.0 + rnd.nextDouble() * 2;
        bust.ellipsoid(hc[0] + r * math.sin(th) * math.sin(ph), hc[1] + r * math.sin(th) * math.cos(ph) * 0.95, hc[2] + 2 + r * math.cos(th) * 1.05, 6.2, 6.2, 5.2,
            k.isEven ? marbleDark : marble,
            lat: 3, lon: 6, jitter: 0.25, seed: ring * 31 + k);
      }
    }
    // A gilded laurel wreath.
    for (var k = 0; k < 18; k++) {
      final ph = math.pi * 0.25 + k * (math.pi * 1.5) / 17;
      final x = 26 * math.sin(ph), y = 10 + 29 * math.cos(ph);
      final dx = math.cos(ph) * 6, dy = -math.sin(ph) * 6;
      bust.tube([x, y, 138], [x + dx, y + dy, 142], 2.6, 0.4, 4, laurel);
    }
    // ---- Ionic column: base mouldings, fluted shaft, scrolled capital.
    final column = LowPolyMesh()
      ..box(0, 0, -6, 30, 30, 8, marble)
      ..prism(0, 0, 2, 6, 13, 12, 16, marbleDark)
      ..prism(0, 0, 6, 9, 11.5, 10.5, 16, marble);
    for (var k = 0; k < 20; k++) {
      final a = k * 2 * math.pi / 20;
      column.tube([math.cos(a) * 9.6, math.sin(a) * 9.6, 9], [math.cos(a) * 8.6, math.sin(a) * 8.6, 112], 1.7, 1.5, 4, k.isEven ? marble : marbleDark, caps: false);
    }
    column
      ..prism(0, 0, 9, 112, 8.6, 7.8, 20, shadow)
      ..prism(0, 0, 112, 116, 8.2, 11, 16, marbleDark)
      ..tube([-14, -4, 119], [-14, 4, 119], 5, 5, 10, marble)
      ..tube([14, -4, 119], [14, 4, 119], 5, 5, 10, marble)
      ..box(0, 0, 116, 26, 12, 6, marble)
      ..box(0, 0, 122, 32, 32, 5, marble);
    // Broken column with a pink fracture face.
    final broken = LowPolyMesh()
      ..box(0, 0, -6, 30, 30, 8, marble)
      ..prism(0, 0, 2, 6, 13, 12, 16, marbleDark);
    for (var k = 0; k < 20; k++) {
      final a = k * 2 * math.pi / 20;
      final top = 52 + 10 * math.sin(a * 2 + 1).abs();
      broken.tube([math.cos(a) * 9.6, math.sin(a) * 9.6, 6], [math.cos(a) * 9.1, math.sin(a) * 9.1, top], 1.7, 1.6, 4, k.isEven ? marble : marbleDark, caps: false);
    }
    broken.prism(0, 0, 6, 54, 8.9, 8.5, 20, shadow, capColor: pink);
    return (bust, column, broken);
  }

  static double _h(int x, int y, int salt) => _hash(x, y, salt);

  /// Colossal monuments stand far out in the world on a ~2.6 km grid, so
  /// they stay put as you walk (slow parallax) and rise out of the ground
  /// through the distance fog.
  List<PropInstance> _vaporInstances(Camera3D cam) {
    final (bust, column, broken) = _vapor;
    const cell = 3400.0;
    final out = <PropInstance>[];
    final c0x = (cam.px / cell).floor() - 3, c0y = (cam.py / cell).floor() - 3;
    for (var gx = c0x; gx <= c0x + 6; gx++) {
      for (var gy = c0y; gy <= c0y + 6; gy++) {
        final x = (gx + 0.2 + 0.6 * _h(gx, gy, 21)) * cell;
        final y = (gy + 0.2 + 0.6 * _h(gx, gy, 22)) * cell;
        final d = math.sqrt(math.pow(x - cam.px, 2) + math.pow(y - cam.py, 2));
        // Only far away (they're colossal) — none looming over the player.
        if (d < 2600 || d > 8500) continue;
        final kind = _h(gx, gy, 23);
        // Face roughly towards the player's area, in three-quarter view.
        final faceAz = math.atan2(cam.px - x, cam.py - y) * 180 / math.pi + 35;
        final yaw = -faceAz * math.pi / 180;
        if (kind > 0.8) continue; // some cells stay empty
        if (kind < 0.3) {
          out.add(PropInstance(bust, x, y, scale: 3.3 + 0.9 * _h(gx, gy, 24), yaw: yaw));
        } else {
          // A small colonnade of 2–4 columns, some broken.
          final n = 2 + (_h(gx, gy, 25) * 3).floor();
          final ang = _h(gx, gy, 26) * math.pi;
          for (var i = 0; i < n; i++) {
            final off = (i - (n - 1) / 2) * 110.0;
            final m = _h(gx * 7 + i, gy, 27) < 0.35 ? broken : column;
            out.add(PropInstance(m, x + math.cos(ang) * off, y + math.sin(ang) * off, scale: 2.2 + _h(gx, gy + i, 28) * 0.8, yaw: ang));
          }
        }
      }
    }
    return out;
  }

  // --------------------------------------------------------------- sakura
  static List<LowPolyMesh> _sakuraMeshes() {
    const bark = Color(0xFF6E4A4F), barkDark = Color(0xFF5A3B40);
    const blossoms = [Color(0xFFF8BBD9), Color(0xFFF48FB1), Color(0xFFFCE4EC), Color(0xFFF5A3C7)];
    final out = <LowPolyMesh>[];
    for (var v = 0; v < 4; v++) {
      final rnd = math.Random(40 + v);
      final m = LowPolyMesh()..prism(0, 0, 0, 7 + v * 0.8, 1.1, 0.7, 5, bark, capColor: barkDark);
      // A couple of branches leaning out.
      for (var b = 0; b < 2; b++) {
        final a = rnd.nextDouble() * math.pi * 2;
        m.prism(math.cos(a) * 1.2, math.sin(a) * 1.2, 5.5, 8.5, 0.5, 0.3, 4, barkDark);
      }
      final blobs = 3 + v % 2;
      for (var k = 0; k < blobs; k++) {
        final a = k * 2 * math.pi / blobs + rnd.nextDouble();
        final rr = k == 0 ? 0.0 : 2.4 + rnd.nextDouble() * 1.2;
        m.ellipsoid(
          math.cos(a) * rr,
          math.sin(a) * rr,
          9.5 + rnd.nextDouble() * 2.5,
          4.2 + rnd.nextDouble(),
          4.2 + rnd.nextDouble(),
          3.2 + rnd.nextDouble(),
          blossoms[(v + k) % blossoms.length],
          lat: 3,
          lon: 6,
          jitter: 0.35,
          seed: v * 10 + k,
        );
      }
      out.add(m);
    }
    return out;
  }

  static double _hash(int x, int y, int salt) {
    var h = x * 374761393 + y * 668265263 + salt * 1442695041;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^= h >> 16;
    return (h & 0xFFFFFF) / 0xFFFFFF;
  }

  static const _cell = 190.0;

  /// Trees on a world-anchored grid, so they stay where they are as you
  /// walk. Trees near the player fade out so they never hide the action.
  List<PropInstance> _treeInstances(Camera3D cam) {
    final out = <PropInstance>[];
    const reach = 1100.0;
    final c0x = ((cam.px - reach) / _cell).floor(), c1x = ((cam.px + reach) / _cell).ceil();
    final c0y = ((cam.py - reach) / _cell).floor(), c1y = ((cam.py + reach) / _cell).ceil();
    final halfW = cam.size.width / 2;
    for (var gx = c0x; gx <= c1x; gx++) {
      for (var gy = c0y; gy <= c1y; gy++) {
        if (_hash(gx, gy, 1) > 0.42) continue;
        final x = (gx + 0.15 + 0.7 * _hash(gx, gy, 2)) * _cell;
        final y = (gy + 0.15 + 0.7 * _hash(gx, gy, 3)) * _cell;
        final dx = x - cam.px, dy = y - cam.py;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > reach) continue;
        final ya = cam.alignY(x, y);
        if (ya < cam.yNear + 20) continue;
        final zc = cam.depth(ya, 0);
        if (zc <= 2) continue;
        final sx = cam.sx(cam.alignX(x, y), zc);
        if ((sx - halfW).abs() > halfW + 60 * cam.focal / zc) continue;
        // Invisible around the player, fading back in from 110–220 m.
        final alpha = ((d - 110) / 110).clamp(0.0, 1.0);
        if (alpha <= 0) continue;
        out.add(
          PropInstance(
            _trees[(_hash(gx, gy, 4) * _trees.length).floor() % _trees.length],
            x,
            y,
            yaw: _hash(gx, gy, 5) * math.pi * 2,
            scale: 3.4 + _hash(gx, gy, 6) * 1.6,
            alpha: alpha * alpha * (3 - 2 * alpha),
          ),
        );
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(PropsPainter old) => true;
}
