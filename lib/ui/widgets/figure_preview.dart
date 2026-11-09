import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../map3d/camera.dart';
import '../../map3d/figure3d.dart';
import 'stick_figure.dart';

/// The player's real 3D figure (the one on the map), standing and slowly
/// turning, so clothing previews look exactly like they will in game.
class Figure3DPreview extends StatefulWidget {
  const Figure3DPreview({super.key, required this.look, this.size = 120, this.turn = true});
  final FigureLook look;
  final double size;

  /// Sway left and right to show the outfit in 3D.
  final bool turn;

  @override
  State<Figure3DPreview> createState() => _Figure3DPreviewState();
}

class _Figure3DPreviewState extends State<Figure3DPreview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 60))..repeat();
  final IdleDirector _idle = IdleDirector(1);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 0.8,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _PreviewPainter(widget.look, _c.value * 60, _idle, widget.turn),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.look, this.time, this.idle, this.turn);
  final FigureLook look;
  final double time;
  final IdleDirector idle;
  final bool turn;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = Camera3D()
      ..distance = 150
      ..pitch = 14
      ..size = size
      ..update();
    // Fit the figure (ground to just above a tall hat) into the box.
    final g = cam.project(cam.px, cam.py, 0), t = cam.project(cam.px, cam.py, 13.5 * Figure3DPainter.s);
    if (g == null || t == null) return;
    final k = size.height * 0.8 / (g.dy - t.dy);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height * 0.47);
    canvas.scale(k);
    canvas.translate(-g.dx, -(g.dy + t.dy) / 2);
    final facing = 180.0 + (turn ? math.sin(time * 0.9) * 50 : 20);
    Figure3DPainter(
      camera: cam,
      look: look,
      time: time,
      idle: idle,
      facing: facing,
      accent: Colors.transparent,
      contrast: Colors.white,
    ).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => true;
}
