import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/game.dart';
import '../../map3d/camera.dart';
import '../../map3d/figure3d.dart';
import '../widgets/stick_figure.dart';
import '../widgets/ui_kit.dart';

/// Other players and DJs on the map: full 3D characters with their
/// cosmetics and a name above their head. [front] picks the ones nearer
/// the camera than the player (drawn over the player) or those behind.
class ActorsPainter extends CustomPainter {
  ActorsPainter({required this.camera, required this.game, required this.time, required this.front, required this.accent, required this.contrast});
  final Camera3D camera;
  final Game game;
  final double time;
  final bool front;
  final Color accent, contrast;

  @override
  void paint(Canvas canvas, Size size) {
    final w = game.world;
    if (w.players.isEmpty && w.djs.isEmpty) return;
    final cam = camera
      ..size = size
      ..update();
    final actors = <(double, void Function())>[];
    void add(double x, double y, FigureLook look, IdleDirector idle, double facing, String label, Color labelColor) {
      final ya = cam.alignY(x, y);
      if ((ya < 0) != front) return;
      if (ya < cam.yNear + 20 || ya > 700) return;
      actors.add((
        cam.depth(ya, 0),
        () {
          Figure3DPainter(camera: cam, look: look, time: time, idle: idle, facing: facing, accent: accent, contrast: contrast, x: x, y: y, disc: false)
              .paint(canvas, size);
          _label(canvas, cam, x, y, label, labelColor, size);
        }
      ));
    }

    for (final p in w.players.values) {
      final (x, y) = game.mapData.toWorld(p.drawLat, p.drawLng);
      add(x, y, FigureLook.fromJson(p.look), p.idle, p.drawHeading, p.name, Colors.white);
    }
    for (final dj in w.djs) {
      final (x, y) = w.djPosition(dj);
      // DJs stand at their decks, turned a fixed way.
      add(x, y, FigureLook.fromJson(dj.look), w.djIdle(dj.id), (hashString(dj.id) % 360).toDouble(), '♪ ${dj.name}', accent);
    }
    actors.sort((a, b) => b.$1.compareTo(a.$1));
    for (final a in actors) {
      a.$2();
    }
  }

  static void _label(Canvas canvas, Camera3D cam, double x, double y, String text, Color color, Size size) {
    if (text.isEmpty) return;
    final top = cam.project(x, y, 14.6 * Figure3DPainter.s);
    if (top == null || top.dx < -60 || top.dx > size.width + 60) return;
    final scale = (cam.scaleAt(x, y) / cam.scaleAt(cam.px, cam.py)).clamp(0.55, 1.2);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 12.5 * scale,
          fontWeight: FontWeight.w700,
          color: color,
          shadows: const [Shadow(color: Colors.black, blurRadius: 4), Shadow(color: Colors.black87, blurRadius: 2, offset: Offset(0, 1))],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 150);
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: top.translate(0, -tp.height / 2 - 2), width: tp.width + 12, height: tp.height + 4), const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = Colors.black.withValues(alpha: 0.42));
    tp.paint(canvas, Offset(top.dx - tp.width / 2, top.dy - tp.height - 2));
  }

  @override
  bool shouldRepaint(ActorsPainter old) => true;
}

/// Invisible tap targets over the glowing features that give something
/// and over the DJs.
class WorldTapLayer extends StatelessWidget {
  const WorldTapLayer({super.key, required this.cam, required this.game, required this.onFeature, required this.onDj});
  final Camera3D cam;
  final Game game;
  final void Function(MapFeature) onFeature;
  final void Function(DjNpc) onDj;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        cam
          ..size = size
          ..update();
        final out = <Widget>[];
        void target(Key key, double x, double y, double height, double boxSize, VoidCallback onTap) {
          final ya = cam.alignY(x, y);
          if (ya < cam.yNear + 10 || ya > 520) return;
          final base = cam.project(x, y), top = cam.project(x, y, height);
          if (base == null || top == null) return;
          if (base.dx < -40 || base.dx > size.width + 40 || base.dy < -40 || base.dy > size.height + 60) return;
          final h = math.max(boxSize, base.dy - top.dy + 16);
          out.add(Positioned(
            key: key,
            left: base.dx - boxSize / 2,
            top: base.dy - h + 8,
            width: boxSize,
            height: h,
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap),
          ));
        }

        for (final f in game.world.features) {
          if (!f.glow) continue;
          target(ValueKey('f${f.id}'), f.x, f.y, 9, 52, () => onFeature(f));
        }
        for (final dj in game.world.djs) {
          final (x, y) = game.world.djPosition(dj);
          target(ValueKey(dj.id), x, y, 13.5 * Figure3DPainter.s, 64, () => onDj(dj));
        }
        return Stack(clipBehavior: Clip.none, children: out);
      });
}

/// A reward pop-up: an icon, a big amount and a line of where it came from.
Future<void> showRewardDialog(BuildContext context, {required IconData icon, required Color color, required String amount, required String text}) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Icon(icon, size: 54, color: color),
          const SizedBox(height: 10),
          Text(amount, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 6),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: kTextSecondary)),
        ]),
        actionsAlignment: MainAxisAlignment.center,
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nice'))],
      ),
    );
