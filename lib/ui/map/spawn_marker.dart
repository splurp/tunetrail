import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/spawns.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';

/// Floating, glowing song icon on the map. Driven by one shared map clock.
class SpawnMarker extends StatelessWidget {
  const SpawnMarker({super.key, required this.spawn, required this.clock, required this.inRange, this.onTap});
  final Spawn spawn;
  final ValueNotifier<double> clock;
  final bool inRange;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = rarityColor(spawn.rarity);
    final seed = spawn.id.hashCode % 1000 / 1000.0;
    final level = spawn.rarity.index;
    final art = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c, width: 3),
        color: Colors.black,
      ),
      child: Art(spawn.song.cover(56), size: 40, circle: true, decodeSize: 96),
    );
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: inRange ? 1 : 0.72,
        child: ValueListenableBuilder<double>(
          valueListenable: clock,
          builder: (context, t, child) {
            final phase = (t + seed * 7) * (1.2 + level * 0.15);
            final bob = math.sin(phase * 2) * 6;
            final pulse = (math.sin(phase * 3) + 1) / 2;
            return Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              // Ground shadow (stays put while the icon floats).
              Positioned(
                bottom: 4,
                child: Container(
                  width: 30 - bob,
                  height: 7,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, -14 + bob),
                child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                  if (level >= Rarity.legendary.index)
                    Transform.rotate(
                      angle: t * 0.8,
                      child: CustomPaint(size: const Size(96, 96), painter: _RaysPainter(c)),
                    ),
                  // Glow halo — bigger & brighter for rarer songs.
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: c.withValues(alpha: 0.35 + 0.35 * pulse),
                          blurRadius: 10 + level * 5 + pulse * 8,
                          spreadRadius: 1 + level * 1.5 + pulse * 2,
                        ),
                      ],
                    ),
                  ),
                  child!,
                  if (spawn.shiny)
                    Positioned(
                      top: -6,
                      right: -6,
                      child: Transform.scale(
                        scale: 0.8 + pulse * 0.4,
                        child: const Icon(Icons.auto_awesome, color: Colors.white, size: 18, shadows: [Shadow(color: Colors.cyanAccent, blurRadius: 8)]),
                      ),
                    ),
                  Positioned(
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.music_note, size: 11, color: Colors.black),
                    ),
                  ),
                ]),
              ),
            ]);
          },
          child: spawn.shiny ? ClipOval(child: Glint(strength: 0.6, child: art)) : art,
        ),
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
      ..shader = RadialGradient(colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0)])
          .createShader(Rect.fromCircle(center: c, radius: size.width / 2));
    for (var i = 0; i < 10; i++) {
      final a = i * math.pi / 5;
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + math.cos(a - 0.12) * size.width / 2, c.dy + math.sin(a - 0.12) * size.width / 2)
        ..lineTo(c.dx + math.cos(a + 0.12) * size.width / 2, c.dy + math.sin(a + 0.12) * size.width / 2)
        ..close();
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_RaysPainter old) => old.color != color;
}
