import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'camera.dart';

/// Draws a trail of footprints on the ground plane (projected in true
/// perspective), revealed progressively from the player towards a song.
class FootstepsPainter extends CustomPainter {
  FootstepsPainter({required this.camera, required this.prints, required this.reveal, required this.opacity, required this.color, this.vanish = 0});

  /// 0..1: prints fade away one after another from the start of the trail.
  final double vanish;

  final Camera3D camera;
  final List<(double, double, double, bool)> prints;

  /// 0..1 fraction of the trail shown.
  final double reveal;
  final double opacity;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (prints.isEmpty || opacity <= 0) return;
    final cam = camera
      ..size = size
      ..update();
    final n = (prints.length * reveal).ceil().clamp(0, prints.length);
    final paint = Paint()..isAntiAlias = true;
    for (var i = 0; i < n; i++) {
      final (x, y, a, left) = prints[i];
      // Newest prints fade in.
      final age = ((n - i) / 6).clamp(0.0, 1.0);
      final fx = math.sin(a), fy = math.cos(a); // forward
      final rx = math.cos(a), ry = -math.sin(a); // right
      Path? foot(double cx, double cy, double halfLen, double halfWidth) {
        final p = Path();
        for (var k = 0; k <= 14; k++) {
          final t = k * 2 * math.pi / 14;
          final f = math.sin(t) * halfLen, r = math.cos(t) * halfWidth;
          final s = cam.project(cx + fx * f + rx * r, cy + fy * f + ry * r);
          if (s == null) return null;
          k == 0 ? p.moveTo(s.dx, s.dy) : p.lineTo(s.dx, s.dy);
        }
        return p..close();
      }

      // Vanishing: a fade front sweeps from the first print to the last.
      const soft = 5.0;
      final gone = ((vanish * (prints.length + soft) - i) / soft).clamp(0.0, 1.0);
      if (gone >= 1) continue;
      paint.color = color.withValues(alpha: opacity * (0.35 + 0.55 * age) * (1 - gone));
      final mirror = left ? -1.0 : 1.0;
      final sole = foot(x - fx * 0.5, y - fy * 0.5, 2.0, 1.05);
      final heel = foot(x - fx * 2.9 + rx * 0.15 * mirror, y - fy * 2.9 + ry * 0.15 * mirror, 1.0, 0.82);
      if (sole != null) canvas.drawPath(sole, paint);
      if (heel != null) canvas.drawPath(heel, paint);
    }
  }

  @override
  bool shouldRepaint(FootstepsPainter old) => true;
}
