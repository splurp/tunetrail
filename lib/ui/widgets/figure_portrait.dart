import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../map3d/camera.dart';
import '../../map3d/figure3d.dart';
import 'stick_figure.dart';

/// How long the hello wave lasts.
const _waveTime = Duration(milliseconds: 1700);

/// The character's head and shoulders in a circle on a profile namecard.
/// It waves hello when the profile opens — leaning in so its head and
/// waving arm come out of the circle — then looks around now and then.
/// Tapping it opens [FigureViewerScreen].
class FigurePortrait extends StatefulWidget {
  const FigurePortrait({super.key, required this.look, this.diameter = 108, this.name = '', this.ring = Colors.white24});
  final FigureLook look;
  final double diameter;
  final String name;
  final Color ring;

  @override
  State<FigurePortrait> createState() => _FigurePortraitState();
}

class _FigurePortraitState extends State<FigurePortrait> with TickerProviderStateMixin {
  late final Ticker _ticker;
  late final AnimationController _wave = AnimationController(vsync: this, duration: _waveTime);
  final IdleDirector _idle = IdleDirector(null, false);
  final ValueNotifier<double> _time = ValueNotifier(0);
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final dt = (elapsed - _last).inMicroseconds / 1e6;
      _last = elapsed;
      _idle.update(dt, false);
      _time.value = elapsed.inMicroseconds / 1e6;
    })
      ..start();
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (mounted) _wave.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _wave.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.diameter;
    return Semantics(
      button: true,
      label: 'View ${widget.name.isEmpty ? 'character' : '${widget.name}\'s character'} in 3D',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(PageRouteBuilder<void>(
          pageBuilder: (_, a, _) => FadeTransition(opacity: a, child: FigureViewerScreen(look: widget.look, name: widget.name)),
        )),
        child: SizedBox(
          width: d,
          height: d,
          child: Stack(clipBehavior: Clip.none, children: [
            // The disc behind the character.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(colors: [Color(0xFF3A3A44), Color(0xFF1B1B21)], radius: 0.85),
                  border: Border.all(color: widget.ring, width: 2),
                  boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 3))],
                ),
              ),
            ),
            // The character, drawn in a bigger box so it can lean out.
            Positioned(
              left: -0.45 * d,
              top: -0.55 * d,
              width: 1.9 * d,
              height: 1.55 * d,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_time, _wave]),
                    builder: (_, _) => CustomPaint(painter: _PortraitPainter(widget.look, _time.value, _idle, _wave.value, d)),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _PortraitPainter extends CustomPainter {
  _PortraitPainter(this.look, this.time, this.idle, this.wave, this.d);
  final FigureLook look;
  final double time, wave, d;
  final IdleDirector idle;

  @override
  void paint(Canvas canvas, Size size) {
    // Where the circle sits in this (larger) box.
    final circle = Rect.fromLTWH(0.45 * d, 0.55 * d, d, d);
    final env = wave <= 0 || wave >= 1 ? 0.0 : math.sin(math.pi * Curves.easeInOut.transform(wave));
    // Inside the circle, plus everything above its middle while waving:
    // the head and the waving arm come out over the rim; the body stays
    // cut off by the bottom of the circle.
    final clip = Path()..addOval(circle);
    if (env > 0) clip.addRect(Rect.fromLTRB(0, 0, size.width, circle.center.dy));
    canvas.save();
    canvas.clipPath(clip);

    final cam = Camera3D()
      ..distance = 150
      ..pitch = 10
      ..size = size
      ..update();
    const s = Figure3DPainter.s;
    // Frame chest to hat-top inside the circle.
    final low = cam.project(cam.px, cam.py, 5.6 * s), top = cam.project(cam.px, cam.py, 13.4 * s);
    if (low == null || top == null) return;
    final k = circle.height * 1.02 / (low.dy - top.dy) * (1 + 0.22 * env);
    canvas.translate(circle.center.dx - 0.04 * d * env, circle.bottom + 0.08 * d - 0.16 * d * env);
    canvas.scale(k);
    canvas.translate(-low.dx, -low.dy);
    Figure3DPainter(
      camera: cam,
      look: look,
      time: time,
      idle: idle,
      facing: 192,
      accent: Colors.transparent,
      contrast: Colors.white,
      wave: wave,
    ).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PortraitPainter old) => true;
}

/// Full-screen 3D view of a character: all their cosmetics, colour and pet,
/// idling and looking around on a dotted floor. Swipe to turn it.
class FigureViewerScreen extends StatefulWidget {
  const FigureViewerScreen({super.key, required this.look, this.name = ''});
  final FigureLook look;
  final String name;

  @override
  State<FigureViewerScreen> createState() => _FigureViewerScreenState();
}

class _FigureViewerScreenState extends State<FigureViewerScreen> with TickerProviderStateMixin {
  late final Ticker _ticker;
  late final AnimationController _wave = AnimationController(vsync: this, duration: _waveTime);
  final IdleDirector _idle = IdleDirector();
  final ValueNotifier<double> _time = ValueNotifier(0);
  Duration _last = Duration.zero;
  double _facing = 195, _spin = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final dt = (elapsed - _last).inMicroseconds / 1e6;
      _last = elapsed;
      // A flick keeps it turning for a moment.
      if (_spin.abs() > 0.5) {
        _facing += _spin * dt;
        _spin *= math.pow(0.04, dt).toDouble();
      }
      _idle.update(dt, false);
      _time.value = elapsed.inMicroseconds / 1e6;
    })
      ..start();
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _wave.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _wave.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF26262B),
      body: Stack(fit: StackFit.expand, children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _spin = 0,
            onHorizontalDragUpdate: (d) => _facing -= d.delta.dx * 0.55,
            onHorizontalDragEnd: (d) => _spin = -(d.primaryVelocity ?? 0) * 0.25,
            child: AnimatedBuilder(
              animation: Listenable.merge([_time, _wave]),
              builder: (_, _) => CustomPaint(painter: _ViewerPainter(widget.look, _time.value, _idle, _wave.value, _facing)),
            ),
          ),
        ),
        Align(
          alignment: Alignment.topLeft,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                ),
                if (widget.name.isNotEmpty) Text(widget.name, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: Text('Swipe to turn', style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ViewerPainter extends CustomPainter {
  _ViewerPainter(this.look, this.time, this.idle, this.wave, this.facing);
  final FigureLook look;
  final double time, wave, facing;
  final IdleDirector idle;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = Camera3D()
      ..distance = 150
      ..pitch = 16
      ..size = size
      ..update();
    const s = Figure3DPainter.s;
    final g = cam.project(cam.px, cam.py, 0), t = cam.project(cam.px, cam.py, 13.5 * s);
    if (g == null || t == null) return;
    // The figure fills about half the screen height.
    final k = math.min(size.height * 0.5, size.width * 0.95) / (g.dy - t.dy);
    canvas.save();
    canvas.translate(size.width / 2, size.height * 0.62);
    canvas.scale(k);
    canvas.translate(-g.dx, -g.dy);

    // Dotted floor in perspective, fading into the distance.
    const step = 2.4 * s;
    const n = 26;
    final dot = Paint();
    for (var i = -n; i <= n; i++) {
      for (var j = -n; j <= n; j++) {
        final x = cam.px + i * step, y = cam.py + j * step;
        final p = cam.project(x, y, 0);
        if (p == null) continue;
        final r = math.sqrt((i * i + j * j).toDouble()) / n;
        if (r > 1) continue;
        final px = cam.scaleAt(x, y);
        dot.color = Color.fromRGBO(170, 170, 180, (0.55 * (1 - r) * (1 - r)).clamp(0.0, 1.0));
        canvas.drawCircle(p, math.max(0.35, 0.11 * s * px), dot);
      }
    }

    Figure3DPainter(
      camera: cam,
      look: look,
      time: time,
      idle: idle,
      facing: facing,
      accent: const Color(0xFF8E8E9A),
      contrast: Colors.white,
      wave: wave,
    ).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ViewerPainter old) => true;
}
