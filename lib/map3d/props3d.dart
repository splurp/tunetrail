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
    final fogT = ((dist - 300) / 1500).clamp(0.0, 0.4);

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
    const marble = Color(0xFFF7F1FB), marbleDark = Color(0xFFE6DAF2), pink = Color(0xFFFFC6EC);
    // Classical bust rising straight out of the ground: chest, sloped
    // shoulders, neck, head, nose, chin and a crown of curls. Faces +y.
    const head = [0.0, 6.0, 112.0];
    final bust = LowPolyMesh()
      ..prism(0, 0, -40, 40, 62, 46, 8, marble, sx: 1.3, sy: 0.62, rot: math.pi / 8, capColor: marbleDark)
      ..prism(0, 0, 40, 58, 46, 20, 8, marble, sx: 1.3, sy: 0.7, rot: math.pi / 8)
      ..prism(0, 3, 50, 90, 15, 13.5, 7, marbleDark)
      ..ellipsoid(0, 6, 112, 26, 30, 34, marble, lat: 5, lon: 9, jitter: 0.06, seed: 3)
      ..ellipsoid(0, 22, 88, 13, 10, 8, marble, lat: 3, lon: 6, seed: 9)
      ..tri([0, 36, 120], [-5, 33, 104], [5, 33, 104], marbleDark, head)
      ..tri([0, 41, 104], [-5, 33, 104], [5, 33, 104], marbleDark, head)
      ..tri([0, 41, 104], [0, 36, 120], [-5, 33, 104], marble, head)
      ..tri([0, 41, 104], [5, 33, 104], [0, 36, 120], marble, head);
    for (final (x, y, z) in [
      (-14.0, -8.0, 140.0),
      (8.0, -10.0, 142.0),
      (-22.0, -4.0, 125.0),
      (20.0, -6.0, 128.0),
      (0.0, -18.0, 130.0),
      (-6.0, 6.0, 146.0),
      (12.0, 8.0, 144.0),
      (-16.0, -16.0, 116.0),
      (16.0, -16.0, 118.0),
    ]) {
      bust.ellipsoid(x, y, z, 10, 10, 8, marbleDark, lat: 3, lon: 5, jitter: 0.15, seed: x.toInt() + 7);
    }
    // Doric column with base and capital.
    final column = LowPolyMesh()
      ..box(0, 0, -6, 26, 26, 10, marble)
      ..prism(0, 0, 4, 110, 9, 8, 10, marble, capColor: marbleDark)
      ..prism(0, 0, 110, 116, 8, 12, 10, marbleDark)
      ..box(0, 0, 116, 28, 28, 7, marble);
    // Broken column (shorter, tilted top).
    final broken = LowPolyMesh()
      ..box(0, 0, -6, 26, 26, 10, marble)
      ..prism(0, 0, 4, 58, 9, 8.6, 10, marble, capColor: pink)
      ..prism(3, 2, 58, 66, 8.6, 6, 10, marbleDark);
    return (bust, column, broken);
  }

  /// Monuments stand far out on the ground in fixed world directions around
  /// the player (like the skyline, they keep their bearing as you walk) and
  /// rise out of the ground itself.
  List<PropInstance> _vaporInstances(Camera3D cam) {
    final (bust, column, broken) = _vapor;
    PropInstance at(LowPolyMesh m, double az, double r, double scale, double faceAz) {
      final a = az * math.pi / 180;
      return PropInstance(m, cam.px + math.sin(a) * r, cam.py + math.cos(a) * r, scale: scale, yaw: -faceAz * math.pi / 180);
    }

    return [
      // Bust in three-quarter view, half-sunk into the ground.
      at(bust, 215, 780, 1.55, 75),
      at(column, 30, 640, 1.2, 0),
      at(column, 42, 700, 1.0, 0),
      at(broken, 330, 600, 1.3, 20),
      at(column, 315, 720, 1.1, 0),
      at(broken, 75, 660, 1.2, 0),
      at(column, 160, 690, 1.15, 0),
      at(broken, 250, 640, 1.0, 40),
    ];
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

  static const _cell = 70.0;

  /// Trees on a world-anchored grid, so they stay where they are as you
  /// walk. Trees near the player fade out so they never hide the action.
  List<PropInstance> _treeInstances(Camera3D cam) {
    final out = <PropInstance>[];
    const reach = 650.0;
    final c0x = ((cam.px - reach) / _cell).floor(), c1x = ((cam.px + reach) / _cell).ceil();
    final c0y = ((cam.py - reach) / _cell).floor(), c1y = ((cam.py + reach) / _cell).ceil();
    final halfW = cam.size.width / 2;
    for (var gx = c0x; gx <= c1x; gx++) {
      for (var gy = c0y; gy <= c1y; gy++) {
        if (_hash(gx, gy, 1) > 0.5) continue;
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
        if ((sx - halfW).abs() > halfW + 25 * cam.focal / zc) continue;
        // Invisible right around the player, fading back in from 45–95 m.
        final alpha = ((d - 45) / 50).clamp(0.0, 1.0);
        if (alpha <= 0) continue;
        out.add(
          PropInstance(
            _trees[(_hash(gx, gy, 4) * _trees.length).floor() % _trees.length],
            x,
            y,
            yaw: _hash(gx, gy, 5) * math.pi * 2,
            scale: 2.3 + _hash(gx, gy, 6) * 1.1,
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
