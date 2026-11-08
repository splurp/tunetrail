import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/widgets/stick_figure.dart';
import 'camera.dart';

/// Draws the player as a true 3D stick figure standing on the map.
///
/// The skeleton (hips, knees, feet, shoulders, elbows, hands, head) lives in
/// world space, is animated with a walk cycle, turns to face the direction
/// of travel and is projected through the same camera as the ground.
/// Cosmetics are drawn as camera-facing art anchored to the projected joints.
class Figure3DPainter extends CustomPainter {
  Figure3DPainter({
    required this.camera,
    required this.look,
    required this.time,
    required this.walking,
    required this.facing,
    required this.accent,
  });

  final Camera3D camera;
  final FigureLook look;
  final double time; // seconds
  final bool walking;
  final double facing; // degrees clockwise from north
  final Color accent;

  /// Figure scale: deliberately oversized (Pokémon-Go style) so the avatar
  /// reads clearly against the streets.
  static const s = 3.6;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = camera
      ..size = size
      ..update();
    final fr = facing * math.pi / 180;
    final fx = math.sin(fr), fy = math.cos(fr); // forward (east, north)
    final rx = math.cos(fr), ry = -math.sin(fr); // right
    final phase = time * (walking ? 7.5 : 1.6);

    // Body bob.
    final bob = walking ? math.sin(phase * 2).abs() * 0.35 * s : math.sin(phase) * 0.08 * s;

    // Local → world helper (f = forward, r = right, z = up, metres).
    (double, double, double) w(double f, double r, double z) => (cam.px + fx * f + rx * r, cam.py + fy * f + ry * r, z);

    Offset? proj((double, double, double) p) => cam.project(p.$1, p.$2, p.$3);
    double depthOf((double, double, double) p) => cam.depth(cam.alignY(p.$1, p.$2), p.$3);

    double z(double designY) => (112 - designY) * 0.1 * s;

    // Ground shadow + soft accent disc.
    final shadow = Path();
    final disc = Path();
    for (var i = 0; i <= 32; i++) {
      final a = i * 2 * math.pi / 32;
      final p = cam.project(cam.px + math.cos(a) * 2.8 * s, cam.py + math.sin(a) * 2.8 * s);
      final q = cam.project(cam.px + math.cos(a) * 5.5 * s, cam.py + math.sin(a) * 5.5 * s);
      if (p != null) i == 0 ? shadow.moveTo(p.dx, p.dy) : shadow.lineTo(p.dx, p.dy);
      if (q != null) i == 0 ? disc.moveTo(q.dx, q.dy) : disc.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(disc, Paint()..color = accent.withValues(alpha: 0.10));
    canvas.drawPath(
        disc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = accent.withValues(alpha: 0.4));
    canvas.drawPath(
        shadow,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));

    // Skeleton.
    final hip = w(0, 0, z(76) + bob);
    final neck = w(0, 0, z(36) + bob);
    final head = w(0, 0, z(22) + bob);
    final shoulder = w(0, 0, z(42) + bob);
    const legLen = 3.4 * s;
    const armLen = 3.0 * s;
    final swing = walking ? math.sin(phase) * 0.6 : 0.0;

    (List<(double, double, double)>, double) leg(double side, double a) {
      final bend = walking ? (0.55 * math.max(0, math.sin(phase * side + math.pi / 2))) : 0.0;
      final kneeF = math.sin(a) * legLen / 2, kneeZ = hip.$3 - math.cos(a) * legLen / 2;
      final footF = kneeF + math.sin(a - bend) * legLen / 2;
      final footZ = math.max(0.0, kneeZ - math.cos(a - bend) * legLen / 2);
      final lat = side * 0.55 * s;
      return ([hip, w(kneeF, lat * 0.8, kneeZ), w(footF, lat, footZ)], 0);
    }

    (List<(double, double, double)>, double) arm(double side, double a) {
      final elbowF = math.sin(a) * armLen / 2;
      final elbowZ = shoulder.$3 - math.cos(a) * armLen / 2;
      final handF = elbowF + math.sin(a + 0.35) * armLen / 2;
      final handZ = elbowZ - math.cos(a + 0.35) * armLen / 2;
      return ([shoulder, w(elbowF, side * 1.0 * s, elbowZ), w(handF, side * 1.25 * s, handZ)], 0);
    }

    final limbs = [leg(-1, swing).$1, leg(1, -swing).$1, arm(-1, -swing * 0.9).$1, arm(1, swing * 0.9).$1];
    final torsoDepth = depthOf(hip);

    final hipP = proj(hip), neckP = proj(neck), headP = proj(head);
    if (hipP == null || neckP == null || headP == null) return;
    final pxPerM = cam.focal / depthOf(head);
    final lineW = 0.62 * s * pxPerM;
    final color = look.color;

    // Facing relative to camera: >0 = facing away (back visible).
    final (faX, faY) = cam.worldDirToAligned(fx, fy);
    final widthF = 0.45 + 0.55 * faY.abs();

    // Design-unit → screen mapping anchored at the neck.
    final kx = 0.1 * s * pxPerM;
    final ky = (hipP.dy - neckP.dy) / 40;

    void drawLimb(List<(double, double, double)> pts, bool far) {
      final ps = [for (final p in pts) proj(p)];
      if (ps.any((p) => p == null)) return;
      final path = Path()..moveTo(ps[0]!.dx, ps[0]!.dy);
      for (var i = 1; i < ps.length; i++) {
        path.lineTo(ps[i]!.dx, ps[i]!.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = far ? Color.lerp(color, Colors.black, 0.35)! : color
            ..style = PaintingStyle.stroke
            ..strokeWidth = lineW
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
    }

    void backpack() {
      if (look.backpack == null) return;
      canvas.save();
      final shift = look.backpack == 'bag_wings' ? 0.0 : 14 + 16 * faX;
      canvas.translate(neckP.dx, neckP.dy);
      canvas.scale(kx * widthF, ky);
      canvas.translate(shift, -36);
      StickFigurePainter.drawBackpack(canvas, look.backpack, walking, phase);
      canvas.restore();
    }

    final backVisible = faY > 0;
    if (!backVisible) backpack();

    // Far limbs first.
    final sorted = [...limbs]..sort((a, b) => depthOf(b.last).compareTo(depthOf(a.last)));
    for (final l in sorted) {
      if (depthOf(l.last) > torsoDepth) drawLimb(l, true);
    }
    // Torso.
    canvas.drawLine(
        neckP,
        hipP,
        Paint()
          ..color = color
          ..strokeWidth = lineW
          ..strokeCap = StrokeCap.round);
    if (look.shirt != null) {
      canvas.save();
      canvas.translate(neckP.dx, neckP.dy);
      canvas.scale(kx * widthF, ky);
      canvas.translate(0, -36);
      StickFigurePainter.drawShirt(canvas, look.shirt, const Offset(0, 36), const Offset(0, 76));
      canvas.restore();
    }
    if (backVisible) backpack();
    for (final l in sorted) {
      if (depthOf(l.last) <= torsoDepth) drawLimb(l, false);
    }

    // Head (a sphere-ish disc with rim light).
    final headR = 1.4 * s * pxPerM;
    canvas.drawCircle(headP, headR, Paint()..color = const Color(0xFF0E0E12));
    canvas.drawCircle(
        headP,
        headR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineW
          ..color = color);
    if (!backVisible) {
      // Eyes face the camera when the figure does; they slide sideways as it
      // turns, which sells the 3D rotation.
      final eyeSide = faX;
      for (final side in [-1.0, 1.0]) {
        final e = proj(w(0.9 * s * 0.6, side * 0.55 * s, z(21) + bob));
        if (e == null) continue;
        final offset = Offset(e.dx - headP.dx, e.dy - headP.dy);
        canvas.drawCircle(headP + offset * 0.9 + Offset(eyeSide * headR * 0.15, 0), headR * 0.16, Paint()..color = color);
      }
    }
    if (look.hat != null) {
      canvas.save();
      canvas.translate(headP.dx, headP.dy);
      canvas.scale(kx * widthF.clamp(0.8, 1.0), ky);
      canvas.translate(0, -22);
      StickFigurePainter.drawHat(canvas, look.hat, const Offset(0, 22), phase);
      canvas.restore();
    }

    // Pet trots beside the player.
    if (look.pet != null) {
      final petW = w(-1.2 * s, 4.2 * s, 0);
      final pp = proj(petW);
      if (pp != null) {
        final k = 0.1 * s * cam.focal / depthOf(petW);
        canvas.save();
        canvas.translate(pp.dx, pp.dy);
        canvas.scale(k, k * 0.85);
        canvas.translate(0, -118);
        StickFigurePainter.drawPet(canvas, look.pet!, phase, walking);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(Figure3DPainter old) => true;
}
