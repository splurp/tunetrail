import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../map3d/camera.dart';
import '../../map3d/figure3d.dart';
import 'stick_figure.dart';

/// The player's real 3D figure (the one on the map), standing and slowly
/// turning, so clothing previews look exactly like they will in game.
class Figure3DPreview extends StatefulWidget {
  const Figure3DPreview({super.key, required this.look, this.size = 120, this.turn = true, this.animate = true, this.facing = 200});
  final FigureLook look;
  final double size;

  /// Facing of a still preview (degrees; 180 = towards the viewer, 0 = back
  /// to the viewer). Backpacks are shown from behind.
  final double facing;

  /// Animate (sway, breathe). Off = drawn once and cached, for grids of
  /// many previews (the shop) where animating them all costs frames.
  final bool animate;

  /// Sway left and right to show the outfit in 3D.
  final bool turn;

  @override
  State<Figure3DPreview> createState() => _Figure3DPreviewState();
}

class _Figure3DPreviewState extends State<Figure3DPreview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 60));
  final IdleDirector _idle = IdleDirector(1);

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(Figure3DPreview old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) _c.repeat();
    if (!widget.animate && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Still previews rendered once into images (keyed by look and pixel
  /// size): drawing an image is far cheaper than re-rasterising the figure
  /// every frame, which renderers without a raster cache (Impeller) do.
  static final Map<String, ui.Image> _stills = {};

  static String _key(FigureLook l, int w, int h, double f) => '${l.color.toARGB32()}|${l.hat}|${l.shirt}|${l.pet}|${l.backpack}|${w}x$h|$f';

  ui.Image _still(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = (widget.size * 0.8 * dpr).round(), h = (widget.size * dpr).round();
    final key = _key(widget.look, w, h, widget.facing);
    final hit = _stills[key];
    if (hit != null) return hit;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(dpr);
    _PreviewPainter(widget.look, 1.2, IdleDirector(1), false, facing: widget.facing).paint(canvas, Size(widget.size * 0.8, widget.size));
    final img = rec.endRecording().toImageSync(w, h);
    // (Old entries are dropped, not disposed: another preview may still
    // be showing the same image.)
    if (_stills.length > 200) _stills.remove(_stills.keys.first);
    return _stills[key] = img;
  }

  bool _hover = false;

  void _setHover(bool h) {
    if (widget.animate || h == _hover) return;
    setState(() => _hover = h);
    if (h) {
      _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Still previews come alive (turning) while the pointer is over them.
    return MouseRegion(onEnter: (_) => _setHover(true), onExit: (_) => _setHover(false), child: _body(context));
  }

  Widget _body(BuildContext context) {
    if (!widget.animate && !_hover) {
      return SizedBox(
        width: widget.size * 0.8,
        height: widget.size,
        child: RawImage(image: _still(context), fit: BoxFit.contain, filterQuality: FilterQuality.medium),
      );
    }
    return SizedBox(
      width: widget.size * 0.8,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _PreviewPainter(widget.look, _c.value * 60, _idle, widget.turn, facing: widget.facing),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.look, this.time, this.idle, this.turn, {this.facing = 200});
  final double facing;
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
    final facing = turn ? this.facing + math.sin(time * 0.9) * 50 : this.facing;
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
  bool shouldRepaint(_PreviewPainter old) => old.time != time || old.turn != turn || old.facing != facing || !_sameLook(old.look, look);

  static bool _sameLook(FigureLook a, FigureLook b) =>
      a.color == b.color && a.hat == b.hat && a.shirt == b.shirt && a.pet == b.pet && a.backpack == b.backpack;
}
