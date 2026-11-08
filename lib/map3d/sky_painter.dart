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
    // A giant marble bust looming over the horizon.
    final bx = _x(cam, 215);
    if (bx != null) {
      final h = _deg(cam, 17);
      _bust(canvas, Offset(bx, horizon + h * 0.05), h);
    }
    // Floating pastel columns / palm silhouettes for surreal flavour.
    for (final (az, elev) in [(30.0, 4.0), (330.0, 6.0), (75.0, 2.5)]) {
      final x = _x(cam, az);
      if (x == null) continue;
      final h = _deg(cam, 6);
      final base = Offset(x, _y(cam, horizon, elev) + math.sin(time * 0.6 + az) * h * 0.04);
      _column(canvas, base, h);
    }
  }

  /// A stylised classical bust in profile (original drawing), with a soft
  /// cyan/pink chromatic offset.
  void _bust(Canvas canvas, Offset bottom, double h) {
    Path shape(Offset o) {
      final u = h / 100;
      Offset q(double x, double y) => Offset(o.dx + x * u, o.dy - y * u);
      return Path()
        ..moveTo(q(-34, 0).dx, q(-34, 0).dy)
        // Shoulders and chest.
        ..cubicTo(q(-36, 14).dx, q(-36, 14).dy, q(-22, 22).dx, q(-22, 22).dy, q(-12, 26).dx, q(-12, 26).dy)
        // Back of the neck.
        ..cubicTo(q(-14, 36).dx, q(-14, 36).dy, q(-16, 44).dx, q(-16, 44).dy, q(-20, 52).dx, q(-20, 52).dy)
        // Back of the head with curls.
        ..cubicTo(q(-30, 60).dx, q(-30, 60).dy, q(-30, 80).dx, q(-30, 80).dy, q(-20, 90).dx, q(-20, 90).dy)
        ..cubicTo(q(-12, 99).dx, q(-12, 99).dy, q(4, 101).dx, q(4, 101).dy, q(12, 94).dx, q(12, 94).dy)
        // Brow, nose, lips, chin.
        ..cubicTo(q(17, 89).dx, q(17, 89).dy, q(17, 82).dx, q(17, 82).dy, q(18, 78).dx, q(18, 78).dy)
        ..lineTo(q(24, 68).dx, q(24, 68).dy)
        ..lineTo(q(19, 66).dx, q(19, 66).dy)
        ..quadraticBezierTo(q(21, 62).dx, q(21, 62).dy, q(18, 60).dx, q(18, 60).dy)
        ..quadraticBezierTo(q(20, 57).dx, q(20, 57).dy, q(17, 55).dx, q(17, 55).dy)
        ..cubicTo(q(18, 50).dx, q(18, 50).dy, q(14, 46).dx, q(14, 46).dy, q(8, 46).dx, q(8, 46).dy)
        // Front of the neck down to the chest.
        ..cubicTo(q(6, 40).dx, q(6, 40).dy, q(8, 32).dx, q(8, 32).dy, q(14, 26).dx, q(14, 26).dy)
        ..cubicTo(q(26, 20).dx, q(26, 20).dy, q(34, 12).dx, q(34, 12).dy, q(34, 0).dx, q(34, 0).dy)
        ..close();
    }

    final rect = Rect.fromLTWH(bottom.dx - h * 0.4, bottom.dy - h, h * 0.8, h);
    canvas.drawPath(shape(bottom + Offset(-h * 0.012, 0)), Paint()..color = const Color(0x5548DBFB));
    canvas.drawPath(shape(bottom + Offset(h * 0.012, 0)), Paint()..color = const Color(0x55FF6EC7));
    canvas.drawPath(
        shape(bottom),
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFFF7F3FA), Color(0xFFD9CDEA), Color(0xFFBBA9DA)])
              .createShader(rect));
    // A few curl highlights on the hair.
    final curl = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.012
      ..color = const Color(0x66FFFFFF);
    for (final (x, y) in [(-18.0, 86.0), (-8.0, 93.0), (2.0, 95.0), (-24.0, 74.0)]) {
      canvas.drawCircle(Offset(bottom.dx + x * h / 100, bottom.dy - y * h / 100), h * 0.035, curl);
    }
  }

  void _column(Canvas canvas, Offset base, double h) {
    final w = h * 0.22;
    final body = Rect.fromLTWH(base.dx - w / 2, base.dy - h, w, h);
    canvas.drawRect(body, Paint()..shader = const LinearGradient(colors: [Color(0xFFF2EAF7), Color(0xFFC9B8E2)]).createShader(body));
    final flute = Paint()
      ..color = const Color(0x33A58BD0)
      ..strokeWidth = w * 0.06;
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(Offset(body.left + w * i / 4, body.top), Offset(body.left + w * i / 4, body.bottom), flute);
    }
    canvas.drawRect(Rect.fromLTWH(base.dx - w * 0.7, base.dy - h - w * 0.25, w * 1.4, w * 0.25), Paint()..color = const Color(0xFFF7F3FA));
    canvas.drawRect(Rect.fromLTWH(base.dx - w * 0.7, base.dy, w * 1.4, w * 0.25), Paint()..color = const Color(0xFFF7F3FA));
  }

  @override
  bool shouldRepaint(SkyPainter old) => true;
}
