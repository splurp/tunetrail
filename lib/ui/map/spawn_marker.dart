import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/spawns.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';

/// A song hovering above the ground: album art in a thin rarity ring, a
/// soft rarity glow that pulses, and a shadow on the ground beneath it.
/// Rarer songs glow stronger; Legendaries get slow light rays; shinies
/// sparkle.
class SpawnMarker extends StatelessWidget {
  const SpawnMarker({super.key, required this.spawn, required this.clock, required this.inRange, this.onTap});
  final Spawn spawn;
  final ValueNotifier<double> clock;
  final bool inRange;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = rarityColor(spawn.rarity);
    final level = spawn.rarity.index;
    final seed = (spawn.id.hashCode % 1000) / 1000.0;
    final t = clock.value;
    final phase = t * 1.4 + seed * 7;
    final bob = math.sin(phase * 2) * 5;
    final pulse = (math.sin(phase * 3) + 1) / 2;
    Widget art = Container(
      width: 46,
      height: 46,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF0D0D10), border: Border.all(color: c, width: 2)),
      child: Art(spawn.song.cover(56), size: 41, circle: true, decodeSize: 96),
    );
    if (spawn.shiny) art = ClipOval(child: Glint(strength: 0.55, child: art));
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: inRange ? 1 : 0.42,
        child: Stack(alignment: Alignment.bottomCenter, clipBehavior: Clip.none, children: [
          // Ground shadow.
          Positioned(
            bottom: 0,
            child: Container(
              width: 26 - bob,
              height: 7,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
            ),
          ),
          Positioned(
            bottom: 18 + bob,
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              if (level == Rarity.legendary.index)
                Transform.rotate(angle: t * 0.5, child: CustomPaint(size: const Size(92, 92), painter: _RaysPainter(c))),
              if (level >= 1)
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
                    BoxShadow(color: c.withValues(alpha: 0.18 + 0.12 * level * (0.5 + pulse * 0.5)), blurRadius: 6.0 + level * 4 + pulse * 4, spreadRadius: level * 0.8),
                  ]),
                ),
              art,
              if (spawn.shiny)
                Positioned(
                  top: -5,
                  right: -5,
                  child: Transform.scale(scale: 0.8 + pulse * 0.3, child: const Icon(Icons.auto_awesome, color: Colors.white, size: 15)),
                ),
              if (spawn.edition != Edition.standard)
                Positioned(
                  bottom: -6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: const Color(0xFF0D0D10), shape: BoxShape.circle, border: Border.all(color: Colors.white70, width: 1)),
                    child: Icon(spawn.edition == Edition.movie ? Icons.movie_outlined : Icons.graphic_eq, size: 11, color: Colors.white),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _RaysPainter extends CustomPainter {
  _RaysPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final p = Paint()
      ..shader = RadialGradient(colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: size.width / 2));
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + math.cos(a - 0.1) * size.width / 2, c.dy + math.sin(a - 0.1) * size.width / 2)
        ..lineTo(c.dx + math.cos(a + 0.1) * size.width / 2, c.dy + math.sin(a + 0.1) * size.width / 2)
        ..close();
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_RaysPainter old) => old.color != color;
}
