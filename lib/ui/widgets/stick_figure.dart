import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Equipped look for the player's stick figure.
class FigureLook {
  const FigureLook({required this.color, this.hat, this.shirt, this.pet, this.backpack});
  final Color color;
  final String? hat;
  final String? shirt;
  final String? pet;
  final String? backpack;
}

/// Animated, customisable stylised stick figure.
class StickFigure extends StatefulWidget {
  const StickFigure({super.key, required this.look, this.walking = false, this.size = 90, this.showPet = true, this.glow = true});
  final FigureLook look;
  final bool walking;
  final double size;
  final bool showPet;
  final bool glow;

  @override
  State<StickFigure> createState() => _StickFigureState();
}

class _StickFigureState extends State<StickFigure> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size * 1.5,
        height: widget.size * 1.25,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: StickFigurePainter(widget.look, _c.value, widget.walking, widget.showPet, widget.glow),
          ),
        ),
      ),
    );
  }
}

class StickFigurePainter extends CustomPainter {
  StickFigurePainter(this.look, this.t, this.walking, this.showPet, this.glow);
  final FigureLook look;
  final double t;
  final bool walking;
  final bool showPet;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.height / 125; // design units → pixels
    canvas.save();
    // Figure occupies the centre third; pet on the right.
    canvas.translate(size.width / 2 - 0 * s, 0);
    canvas.scale(s);
    final phase = t * math.pi * 2;
    final bob = walking ? math.sin(phase * 2).abs() * -3 : math.sin(phase) * 0.8;
    canvas.translate(0, bob);

    final c = look.color;
    final line = Paint()
      ..color = c
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Ground shadow.
    canvas.drawOval(Rect.fromCenter(center: Offset(0, 118 - bob), width: 46, height: 10),
        Paint()..color = Colors.black.withValues(alpha: 0.35));
    if (glow) {
      canvas.drawCircle(const Offset(0, 60), 42,
          Paint()
            ..color = c.withValues(alpha: 0.18)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));
    }

    const neck = Offset(0, 36);
    const hip = Offset(0, 76);
    final swing = walking ? math.sin(phase) * 0.6 : math.sin(phase) * 0.06;

    drawBackpack(canvas, look.backpack, walking, phase);

    // Legs.
    Offset leg(double a) => hip + Offset(math.sin(a) * 34, math.cos(a) * 34);
    canvas.drawLine(hip, leg(0.32 + swing), line);
    canvas.drawLine(hip, leg(-0.32 - swing), line);

    // Torso and arms, then the shirt on top with sleeves over the upper
    // arms (so arms come out of the sleeves instead of lying on the shirt).
    canvas.drawLine(neck, hip, line);
    const shoulder = Offset(0, 42);
    Offset arm(double a) => shoulder + Offset(math.sin(a) * 30, math.cos(a) * 30);
    final handL = arm(0.75 - swing * 0.8), handR = arm(-0.75 + swing * 0.8);
    canvas.drawLine(shoulder, handL, line);
    canvas.drawLine(shoulder, handR, line);
    drawShirt(canvas, look.shirt, neck, hip);
    drawSleeve(canvas, look.shirt, shoulder + const Offset(4, 0), Offset.lerp(shoulder, handL, 0.5)!, 10);
    drawSleeve(canvas, look.shirt, shoulder + const Offset(-4, 0), Offset.lerp(shoulder, handR, 0.5)!, 10);

    // Head.
    const head = Offset(0, 22);
    canvas.drawCircle(head, 14, Paint()..color = const Color(0xFF0E1018));
    canvas.drawCircle(head, 14, line);
    // Eyes.
    final eye = Paint()..color = c;
    final blink = (t * 4) % 1 < 0.04;
    if (blink) {
      canvas.drawLine(const Offset(-5, 21), const Offset(-2, 21), line..strokeWidth = 2);
      canvas.drawLine(const Offset(2, 21), const Offset(5, 21), line..strokeWidth = 2);
      line.strokeWidth = 5;
    } else {
      canvas.drawCircle(const Offset(-4.5, 21), 2.2, eye);
      canvas.drawCircle(const Offset(4.5, 21), 2.2, eye);
    }
    drawHat(canvas, look.hat, head, phase);
    canvas.restore();

    if (showPet && look.pet != null) {
      canvas.save();
      canvas.translate(size.width / 2 + 42 * s, 0);
      canvas.scale(s);
      drawPet(canvas, look.pet!, phase, walking);
      canvas.restore();
    }
  }

  // ------------------------------------------------------------- shirts
  static Color shirtColor(String id) => switch (id) {
        'shirt_tee_red' => const Color(0xFFE53935),
        'shirt_tee_black' => const Color(0xFF212121),
        'shirt_striped' => const Color(0xFFFAFAFA),
        'shirt_hoodie' => const Color(0xFF7E57C2),
        'shirt_hawaiian' => const Color(0xFF26A69A),
        'shirt_tux' => const Color(0xFF111111),
        'shirt_lightning' => const Color(0xFF1A237E),
        'shirt_rainbow' => const Color(0xFFFF4081),
        _ => Colors.grey,
      };

  /// Sleeve over the upper arm, from [shoulder] towards [elbow] (screen or
  /// design space). Drawn after the arms so arms come out of the sleeves.
  static void drawSleeve(Canvas canvas, String? id, Offset shoulder, Offset elbow, double width) {
    if (id == null) return;
    final end = Offset.lerp(shoulder, elbow, id == 'shirt_hoodie' || id == 'shirt_tux' ? 0.95 : 0.6)!;
    canvas.drawLine(
        shoulder,
        end,
        Paint()
          ..color = id == 'shirt_striped' ? const Color(0xFF1E88E5) : shirtColor(id)
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round);
  }

  static void drawShirt(Canvas canvas, String? id, Offset neck, Offset hip) {
    if (id == null) return;
    final body = Path()
      ..moveTo(-12, neck.dy + 2)
      ..lineTo(12, neck.dy + 2)
      ..lineTo(14, neck.dy + 10)
      ..lineTo(11, hip.dy + 2)
      ..lineTo(-11, hip.dy + 2)
      ..lineTo(-14, neck.dy + 10)
      ..close();
    final colors = <String, Color>{
      'shirt_tee_red': const Color(0xFFE53935),
      'shirt_tee_black': const Color(0xFF212121),
      'shirt_striped': const Color(0xFFFAFAFA),
      'shirt_hoodie': const Color(0xFF7E57C2),
      'shirt_hawaiian': const Color(0xFF26A69A),
      'shirt_tux': const Color(0xFF111111),
      'shirt_lightning': const Color(0xFF1A237E),
      'shirt_rainbow': const Color(0xFFFF4081),
    };
    final fill = Paint()..color = colors[id] ?? Colors.grey;
    if (id == 'shirt_rainbow') {
      fill.shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.red, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purple],
      ).createShader(Rect.fromLTRB(-19, neck.dy, 19, hip.dy));
    }
    if (id == 'shirt_hoodie') {
      canvas.drawCircle(const Offset(0, 30), 16, Paint()..color = const Color(0xFF5E35B1));
    }
    canvas.drawPath(body, fill);
    canvas.save();
    canvas.clipPath(body);
    switch (id) {
      case 'shirt_striped':
        for (var y = neck.dy; y < hip.dy + 4; y += 7) {
          canvas.drawRect(Rect.fromLTWH(-20, y, 40, 3), Paint()..color = const Color(0xFF1E88E5));
        }
      case 'shirt_hawaiian':
        final f = Paint()..color = const Color(0xFFFFEB3B);
        for (final o in const [Offset(-7, 44), Offset(6, 52), Offset(-4, 62), Offset(8, 70), Offset(-9, 72)]) {
          canvas.drawCircle(o, 3, f);
          canvas.drawCircle(o, 1.2, Paint()..color = const Color(0xFFE91E63));
        }
      case 'shirt_tux':
        canvas.drawPath(
            Path()
              ..moveTo(-6, neck.dy + 2)
              ..lineTo(6, neck.dy + 2)
              ..lineTo(0, hip.dy)
              ..close(),
            Paint()..color = Colors.white);
        canvas.drawPath(
            Path()
              ..moveTo(-6, neck.dy + 4)
              ..lineTo(0, neck.dy + 7)
              ..lineTo(6, neck.dy + 4)
              ..lineTo(6, neck.dy + 10)
              ..lineTo(0, neck.dy + 7)
              ..lineTo(-6, neck.dy + 10)
              ..close(),
            Paint()..color = const Color(0xFFD32F2F));
      case 'shirt_lightning':
        canvas.drawPath(
            Path()
              ..moveTo(3, 42)
              ..lineTo(-6, 58)
              ..lineTo(0, 58)
              ..lineTo(-4, 72)
              ..lineTo(7, 54)
              ..lineTo(1, 54)
              ..close(),
            Paint()..color = const Color(0xFFFFD600));
      case 'shirt_tee_black':
        canvas.drawCircle(const Offset(0, 54), 7, Paint()..color = const Color(0xFFFF1744));
        canvas.drawCircle(const Offset(0, 54), 2.5, Paint()..color = const Color(0xFF212121));
      case 'shirt_hoodie':
        canvas.drawRect(const Rect.fromLTWH(-8, 62, 16, 7), Paint()..color = const Color(0xFF5E35B1));
    }
    canvas.restore();
  }

  // --------------------------------------------------------------- hats
  static void drawHat(Canvas canvas, String? id, Offset head, double phase) {
    if (id == null) return;
    switch (id) {
      case 'hat_cap':
        final p = Paint()..color = const Color(0xFFE53935);
        // Crown covers the whole top of the head (incl. outline); brim out front.
        canvas.drawArc(Rect.fromCircle(center: head + const Offset(0, -3), radius: 18.5), math.pi, math.pi, true, p);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(head.dx - 4, head.dy - 6, 30, 6), const Radius.circular(3)), p);
        canvas.drawRect(Rect.fromLTWH(head.dx - 18.5, head.dy - 6, 37, 3), Paint()..color = const Color(0xFFB71C1C));
        canvas.drawCircle(head + const Offset(0, -21.5), 2.4, Paint()..color = Colors.white);
      case 'hat_beanie':
        final p = Paint()..color = const Color(0xFF43A047);
        canvas.drawArc(Rect.fromCircle(center: head + const Offset(0, -2), radius: 18.5), math.pi, math.pi, true, p);
        canvas.drawRect(Rect.fromLTWH(head.dx - 18.5, head.dy - 6, 37, 7), Paint()..color = const Color(0xFF2E7D32));
        canvas.drawCircle(head + const Offset(0, -22), 4.8, Paint()..color = Colors.white);
      case 'hat_headphones':
        final band = Paint()
          ..color = const Color(0xFF212121)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4;
        canvas.drawArc(Rect.fromCircle(center: head, radius: 17), math.pi * 1.05, math.pi * 0.9, false, band);
        final cup = Paint()..color = const Color(0xFF00E5FF);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: head + const Offset(-16, 2), width: 8, height: 14), const Radius.circular(4)), cup);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: head + const Offset(16, 2), width: 8, height: 14), const Radius.circular(4)), cup);
      case 'hat_tophat':
        final p = Paint()..color = const Color(0xFF263238);
        canvas.drawRect(Rect.fromLTWH(head.dx - 20, head.dy - 16, 40, 4), p);
        canvas.drawRect(Rect.fromLTWH(head.dx - 12, head.dy - 40, 24, 25), p);
        canvas.drawRect(Rect.fromLTWH(head.dx - 12, head.dy - 21, 24, 4), Paint()..color = const Color(0xFFD32F2F));
      case 'hat_cowboy':
        final p = Paint()..color = const Color(0xFF8D6E63);
        canvas.drawOval(Rect.fromCenter(center: head + const Offset(0, -13), width: 50, height: 9), p);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(head.dx - 12, head.dy - 32, 24, 19), const Radius.circular(6)), p);
        canvas.drawRect(Rect.fromLTWH(head.dx - 12, head.dy - 17, 24, 3), Paint()..color = const Color(0xFF4E342E));
      case 'hat_party':
        canvas.drawPath(
            Path()
              // Base rests on top of the head (outline edge is at −16.5).
              ..moveTo(head.dx - 12, head.dy - 14)
              ..lineTo(head.dx + 12, head.dy - 14)
              ..lineTo(head.dx, head.dy - 47)
              ..close(),
            Paint()
              ..shader = const LinearGradient(colors: [Color(0xFFFFEB3B), Color(0xFFFF4081)])
                  .createShader(Rect.fromLTWH(head.dx - 12, head.dy - 47, 24, 33)));
        canvas.drawCircle(head + const Offset(0, -48), 3.8, Paint()..color = const Color(0xFF00E5FF));
      case 'hat_wizard':
        canvas.drawPath(
            Path()
              ..moveTo(head.dx - 19, head.dy - 13)
              ..lineTo(head.dx + 19, head.dy - 13)
              ..quadraticBezierTo(head.dx + 4, head.dy - 30, head.dx + 14, head.dy - 46)
              ..quadraticBezierTo(head.dx - 6, head.dy - 30, head.dx - 19, head.dy - 13)
              ..close(),
            Paint()..color = const Color(0xFF5E35B1));
        final star = Paint()..color = const Color(0xFFFFEB3B);
        canvas.drawCircle(head + const Offset(-2, -20), 2.2, star);
        canvas.drawCircle(head + const Offset(5, -30), 1.6, star);
      case 'hat_crown':
        final p = Paint()..color = const Color(0xFFFFC107);
        canvas.drawPath(
            Path()
              ..moveTo(head.dx - 14, head.dy - 13)
              ..lineTo(head.dx - 15, head.dy - 32)
              ..lineTo(head.dx - 7, head.dy - 23)
              ..lineTo(head.dx, head.dy - 36)
              ..lineTo(head.dx + 7, head.dy - 23)
              ..lineTo(head.dx + 15, head.dy - 32)
              ..lineTo(head.dx + 14, head.dy - 13)
              ..close(),
            p);
        canvas.drawCircle(head + const Offset(0, -19), 2.6, Paint()..color = const Color(0xFFE91E63));
        canvas.drawCircle(head + Offset(0, -36 + math.sin(phase * 2) * 0.5), 2.2, Paint()..color = Colors.white);
      case 'hat_halo':
        canvas.drawOval(
            Rect.fromCenter(center: head + Offset(0, -22 + math.sin(phase) * 2), width: 30, height: 8),
            Paint()
              ..color = const Color(0xFFFFF59D)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3.5
              ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3));
    }
  }

  // ---------------------------------------------------------- backpacks
  static void drawBackpack(Canvas canvas, String? id, bool walking, double phase) {
    if (id == null) return;
    switch (id) {
      case 'bag_classic':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-24, 38, 20, 28), const Radius.circular(6)),
            Paint()..color = const Color(0xFF1565C0));
        canvas.drawRect(const Rect.fromLTWH(-22, 52, 16, 8), Paint()..color = const Color(0xFF0D47A1));
      case 'bag_boombox':
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-34, 40, 30, 20), const Radius.circular(3)),
            Paint()..color = const Color(0xFF424242));
        final pulse = 4.0 + (walking ? math.sin(phase * 4).abs() * 1.5 : 0);
        canvas.drawCircle(const Offset(-27, 51), pulse, Paint()..color = const Color(0xFF00E5FF));
        canvas.drawCircle(const Offset(-11, 51), pulse, Paint()..color = const Color(0xFF00E5FF));
      case 'bag_guitar':
        canvas.save();
        canvas.translate(-10, 60);
        canvas.rotate(-0.5);
        final p = Paint()..color = const Color(0xFF6D4C41);
        canvas.drawOval(Rect.fromCenter(center: const Offset(0, 14), width: 22, height: 26), p);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: const Offset(0, -14), width: 9, height: 36), const Radius.circular(3)), p);
        canvas.restore();
      case 'bag_crate':
        canvas.drawRect(const Rect.fromLTWH(-30, 38, 24, 24), Paint()..color = const Color(0xFFA1887F));
        for (var i = 0; i < 3; i++) {
          canvas.drawCircle(Offset(-25.0 + i * 7, 38), 6, Paint()..color = const Color(0xFF111111));
        }
      case 'bag_jetpack':
        final p = Paint()..color = const Color(0xFFB0BEC5);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-26, 38, 10, 26), const Radius.circular(4)), p);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-15, 38, 10, 26), const Radius.circular(4)), p);
        final flame = 8 + math.sin(phase * 6).abs() * (walking ? 10 : 3);
        final fp = Paint()..color = const Color(0xFFFF9100);
        canvas.drawPath(Path()..moveTo(-25, 64)..lineTo(-21, 64 + flame)..lineTo(-17, 64)..close(), fp);
        canvas.drawPath(Path()..moveTo(-14, 64)..lineTo(-10, 64 + flame)..lineTo(-6, 64)..close(), fp);
      case 'bag_wings':
        final flap = math.sin(phase * (walking ? 3 : 1)) * 0.25;
        final p = Paint()..color = Colors.white.withValues(alpha: 0.9);
        for (final dir in [-1.0, 1.0]) {
          canvas.save();
          canvas.translate(0, 46);
          canvas.rotate(dir * (0.3 + flap));
          canvas.drawPath(
              Path()
                ..moveTo(0, 0)
                ..quadraticBezierTo(dir * 30, -26, dir * 44, -10)
                ..quadraticBezierTo(dir * 30, 0, dir * 36, 10)
                ..quadraticBezierTo(dir * 20, 8, 0, 6)
                ..close(),
              p);
          canvas.restore();
        }
    }
  }

  // ---------------------------------------------------------------- pets
  static void drawPet(Canvas canvas, String id, double phase, bool walking) {
    final hop = walking ? -math.sin(phase * 2).abs() * 6 : -math.sin(phase).abs() * 2;
    final base = Offset(0, 104 + hop);
    canvas.drawOval(Rect.fromCenter(center: const Offset(0, 118), width: 26, height: 6),
        Paint()..color = Colors.black.withValues(alpha: 0.3));
    final eye = Paint()..color = Colors.black;
    switch (id) {
      case 'pet_cat':
        final p = Paint()..color = const Color(0xFFFF9800);
        canvas.drawOval(Rect.fromCenter(center: base, width: 24, height: 18), p);
        canvas.drawPath(Path()..moveTo(-10, base.dy - 6)..lineTo(-7, base.dy - 16)..lineTo(-2, base.dy - 8)..close(), p);
        canvas.drawPath(Path()..moveTo(10, base.dy - 6)..lineTo(7, base.dy - 16)..lineTo(2, base.dy - 8)..close(), p);
        canvas.drawCircle(base + const Offset(-4, -1), 1.8, eye);
        canvas.drawCircle(base + const Offset(4, -1), 1.8, eye);
        canvas.drawArc(Rect.fromCircle(center: base + Offset(14, -4 + math.sin(phase * 2) * 2), radius: 6), -1.5, 2.5, false,
            Paint()
              ..color = const Color(0xFFFF9800)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3);
      case 'pet_dog':
        final p = Paint()..color = const Color(0xFF8D6E63);
        canvas.drawOval(Rect.fromCenter(center: base, width: 26, height: 18), p);
        canvas.drawOval(Rect.fromCenter(center: base + const Offset(-12, -2), width: 7, height: 13), Paint()..color = const Color(0xFF5D4037));
        canvas.drawOval(Rect.fromCenter(center: base + const Offset(12, -2), width: 7, height: 13), Paint()..color = const Color(0xFF5D4037));
        canvas.drawCircle(base + const Offset(-4, -2), 1.8, eye);
        canvas.drawCircle(base + const Offset(4, -2), 1.8, eye);
        canvas.drawCircle(base + const Offset(0, 3), 2.2, eye);
      case 'pet_bird':
        final fly = Offset(0, -26 + math.sin(phase * 2) * 4);
        final p = Paint()..color = const Color(0xFF29B6F6);
        canvas.drawCircle(base + fly, 8, p);
        final flap = math.sin(phase * 8) * 6;
        canvas.drawPath(Path()..moveTo(base.dx, base.dy + fly.dy)..lineTo(base.dx - 12, base.dy + fly.dy - flap)..lineTo(base.dx - 4, base.dy + fly.dy + 3)..close(), p);
        canvas.drawPath(Path()..moveTo(8, base.dy + fly.dy)..lineTo(13, base.dy + fly.dy + 2)..lineTo(8, base.dy + fly.dy + 3)..close(), Paint()..color = Colors.orange);
        canvas.drawCircle(base + fly + const Offset(3, -2), 1.5, eye);
      case 'pet_slime':
        final squish = 1 + math.sin(phase * 2) * 0.12;
        canvas.drawOval(Rect.fromCenter(center: base + const Offset(0, 2), width: 24 * squish, height: 18 / squish),
            Paint()..color = const Color(0xFF76FF03).withValues(alpha: 0.85));
        canvas.drawCircle(base + const Offset(-4, 0), 2, eye);
        canvas.drawCircle(base + const Offset(4, 0), 2, eye);
      case 'pet_robot':
        final p = Paint()..color = const Color(0xFF90A4AE);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: base, width: 20, height: 18), const Radius.circular(4)), p);
        canvas.drawLine(base + const Offset(0, -9), base + const Offset(0, -15), Paint()..color = const Color(0xFF90A4AE)..strokeWidth = 2);
        canvas.drawCircle(base + const Offset(0, -16), 2.5, Paint()..color = (phase % 1.0) > 0.5 ? Colors.red : Colors.redAccent);
        canvas.drawRect(Rect.fromCenter(center: base + const Offset(0, -1), width: 14, height: 5), Paint()..color = const Color(0xFF00E5FF));
      case 'pet_ghost':
        final f = Offset(0, -10 + math.sin(phase) * 4);
        final path = Path()
          ..moveTo(-10, base.dy + f.dy + 8)
          ..lineTo(-10, base.dy + f.dy - 2)
          ..arcToPoint(Offset(10, base.dy + f.dy - 2), radius: const Radius.circular(10))
          ..lineTo(10, base.dy + f.dy + 8);
        for (var i = 0; i < 4; i++) {
          path.lineTo(10 - (i + 0.5) * 5, base.dy + f.dy + (i.isEven ? 4 : 9));
        }
        path.close();
        canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.85));
        canvas.drawCircle(base + f + const Offset(-3.5, -2), 1.8, eye);
        canvas.drawCircle(base + f + const Offset(3.5, -2), 1.8, eye);
      case 'pet_dragon':
        final p = Paint()..color = const Color(0xFFD50000);
        final flap = math.sin(phase * 4) * 0.4;
        canvas.save();
        canvas.translate(base.dx, base.dy - 4);
        for (final d in [-1.0, 1.0]) {
          canvas.save();
          canvas.rotate(d * (0.4 + flap));
          canvas.drawPath(Path()..moveTo(0, 0)..lineTo(d * 16, -12)..lineTo(d * 12, 2)..close(), Paint()..color = const Color(0xFFFF6D00));
          canvas.restore();
        }
        canvas.restore();
        canvas.drawOval(Rect.fromCenter(center: base, width: 22, height: 18), p);
        canvas.drawCircle(base + const Offset(-4, -2), 1.8, Paint()..color = Colors.yellow);
        canvas.drawCircle(base + const Offset(4, -2), 1.8, Paint()..color = Colors.yellow);
    }
  }

  @override
  bool shouldRepaint(StickFigurePainter old) =>
      old.t != t || old.walking != walking || old.look != look;
}
