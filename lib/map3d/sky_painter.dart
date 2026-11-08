import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'camera.dart';
import 'palette.dart';

/// Decorations that live in the sky, anchored to world directions so they
/// stay put as the camera turns.
enum SkyDecor { none, synthSun, stars, aurora, vaporBust }

/// Paints the sky (behind the ground): gradient plus world-anchored decor.
class SkyPainter extends CustomPainter {
  SkyPainter({required this.camera, required this.palette, required this.decor, required this.time});
  final Camera3D camera;
  final MapPalette palette;
  final SkyDecor decor;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final horizon = cam.horizonY;
    if (horizon <= 0) return; // looking down (overhead view): no sky
    final sky = Rect.fromLTWH(0, 0, size.width, horizon + 2);
    canvas.drawRect(sky,
        Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [palette.skyTop, palette.skyBottom]).createShader(sky));
    canvas.save();
    canvas.clipRect(sky);
    switch (decor) {
      case SkyDecor.none:
        break;
      case SkyDecor.synthSun:
        _synthSun(canvas, cam, horizon);
      case SkyDecor.stars:
        _stars(canvas, cam, horizon);
      case SkyDecor.aurora:
        _stars(canvas, cam, horizon, count: 70);
        _aurora(canvas, cam, horizon, size);
      case SkyDecor.vaporBust:
        _vaporwave(canvas, cam, horizon);
    }
    canvas.restore();
  }

  /// Screen x for a world azimuth (degrees), or null when out of view.
  double? _x(Camera3D cam, double az) {
    final rel = ((az - cam.bearing + 540) % 360) - 180;
    if (rel.abs() > 80) return null;
    return cam.cx + cam.focal * math.tan(rel * math.pi / 180);
  }

  double _y(Camera3D cam, double horizon, double elevDeg) => horizon - cam.focal * math.tan(elevDeg * math.pi / 180);
  double _deg(Camera3D cam, double deg) => cam.focal * math.tan(deg * math.pi / 180);

  double _rand(int i, int salt) {
    final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  // --------------------------------------------------------- synthwave sun
  void _synthSun(Canvas canvas, Camera3D cam, double horizon) {
    const az = 295.0;
    final x = _x(cam, az);
    if (x == null) return;
    final r = _deg(cam, 8.5);
    final c = Offset(x, horizon - r * 0.45);
    final rect = Rect.fromCircle(center: c, radius: r);
    // Glow.
    canvas.drawCircle(c, r * 1.6, Paint()..shader = RadialGradient(colors: [const Color(0x66FF4FD8), const Color(0x00FF4FD8)]).createShader(Rect.fromCircle(center: c, radius: r * 1.6)));
    canvas.saveLayer(rect.inflate(2), Paint());
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFE66D), Color(0xFFFF8A3D), Color(0xFFFF2E93)], stops: [0, 0.5, 1])
              .createShader(rect));
    // The classic horizontal gaps, widening towards the bottom.
    final clear = Paint()..blendMode = BlendMode.clear;
    for (var i = 0; i < 7; i++) {
      final t = i / 6;
      final y = c.dy + r * (0.02 + t * 0.9);
      final h = r * (0.025 + t * 0.075);
      canvas.drawRect(Rect.fromLTWH(c.dx - r, y, r * 2, h), clear);
    }
    canvas.restore();
  }

  // ---------------------------------------------------------------- stars
  void _stars(Canvas canvas, Camera3D cam, double horizon, {int count = 140}) {
    final p = Paint();
    for (var i = 0; i < count; i++) {
      final az = _rand(i, 1) * 360;
      final x = _x(cam, az);
      if (x == null) continue;
      final elev = 1.2 + math.pow(_rand(i, 2), 0.8) * 19;
      final y = _y(cam, horizon, elev.toDouble());
      final tw = (math.sin(time * (0.8 + _rand(i, 3) * 2) + i) + 1) / 2;
      p.color = Colors.white.withValues(alpha: 0.12 + tw * 0.55);
      canvas.drawCircle(Offset(x, y), 0.6 + _rand(i, 4) * 1.1, p);
    }
  }

  // --------------------------------------------------------------- aurora
  void _aurora(Canvas canvas, Camera3D cam, double horizon, Size size) {
    final colors = [const Color(0xFF69F0AE), const Color(0xFF40C4FF), const Color(0xFFB388FF)];
    for (var band = 0; band < 3; band++) {
      final path = Path();
      final base = <Offset>[];
      for (var rel = -80.0; rel <= 80; rel += 4) {
        final az = cam.bearing + rel;
        final x = cam.cx + cam.focal * math.tan(rel * math.pi / 180);
        // Shape depends on world azimuth so the curtain is fixed in the sky.
        final elev = 11 + band * 3 + math.sin(az * math.pi / 50 + time * (0.25 + band * 0.08) + band) * 2.5 + math.sin(az * math.pi / 19 + time * 0.6) * 1;
        base.add(Offset(x, _y(cam, horizon, elev)));
      }
      path.moveTo(base.first.dx, base.first.dy);
      for (final o in base.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      final h = _deg(cam, 8);
      for (final o in base.reversed) {
        path.lineTo(o.dx, o.dy + h);
      }
      path.close();
      final top = base.map((o) => o.dy).reduce(math.min);
      canvas.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colors[band].withValues(alpha: 0.32), colors[band].withValues(alpha: 0)])
                .createShader(Rect.fromLTWH(0, top, size.width, h * 1.6))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }
  }

  // ------------------------------------------------------------ vaporwave
  void _vaporwave(Canvas canvas, Camera3D cam, double horizon) {
    // Pastel grid sun.
    final sx = _x(cam, 120);
    if (sx != null) {
      final r = _deg(cam, 7);
      final c = Offset(sx, horizon - r * 0.55);
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.saveLayer(rect.inflate(2), Paint());
      canvas.drawCircle(c, r, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFF1A8), Color(0xFFFF9FD8)]).createShader(rect));
      final clear = Paint()..blendMode = BlendMode.clear;
      for (var i = 0; i < 5; i++) {
        canvas.drawRect(Rect.fromLTWH(c.dx - r, c.dy + r * (0.15 + i * 0.17), r * 2, r * (0.03 + i * 0.03)), clear);
      }
      canvas.restore();
    }
    // The marble bust and columns are real 3D props standing on the
    // distant ground (see props3d.dart).
  }

  @override
  bool shouldRepaint(SkyPainter old) => true;
}
