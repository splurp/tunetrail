import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../map3d/palette.dart';
import '../../map3d/sky_painter.dart';

enum MapEffect { none, grid, rain, snow, embers, petals, digitalRain, aurora, dust, stars }

/// A visual style for the 3D world: palette + an animated screen overlay.
class MapThemeDef {
  const MapThemeDef({required this.id, required this.palette, this.effect = MapEffect.none, this.vignette = const Color(0x55000000), this.sky = SkyDecor.none});
  final String id;
  final SkyDecor sky;
  final MapPalette palette;
  final MapEffect effect;
  final Color vignette;
  Color get accent => palette.accent;
}

const Map<String, MapThemeDef> kMapThemes = {
  'theme_classic': MapThemeDef(id: 'theme_classic', palette: kObsidian, vignette: Color(0x66000000)),
  'theme_midnight': MapThemeDef(id: 'theme_midnight', palette: kMidnight, sky: SkyDecor.stars),
  'theme_synthwave': MapThemeDef(id: 'theme_synthwave', palette: kSynthwave, sky: SkyDecor.synthSun, vignette: Color(0x66200030)),
  'theme_vaporwave': MapThemeDef(id: 'theme_vaporwave', palette: kVaporwave, sky: SkyDecor.vaporBust, vignette: Color(0x2200D2D3)),
  'theme_noir': MapThemeDef(id: 'theme_noir', palette: kNoir, effect: MapEffect.rain, vignette: Color(0x99000000)),
  'theme_vinyl': MapThemeDef(id: 'theme_vinyl', palette: kVinyl, effect: MapEffect.dust, vignette: Color(0x884E342E)),
  'theme_matrix': MapThemeDef(id: 'theme_matrix', palette: kMatrix, effect: MapEffect.digitalRain, vignette: Color(0x99000000)),
  'theme_arctic': MapThemeDef(id: 'theme_arctic', palette: kArctic, effect: MapEffect.snow, vignette: Color(0x22004466)),
  'theme_lava': MapThemeDef(id: 'theme_lava', palette: kMagma, effect: MapEffect.embers, vignette: Color(0x88300000)),
  'theme_aurora': MapThemeDef(id: 'theme_aurora', palette: kAurora, sky: SkyDecor.aurora),
  'theme_sakura': MapThemeDef(id: 'theme_sakura', palette: kSakura, effect: MapEffect.petals, vignette: Color(0x22F06292)),
};

MapThemeDef themeById(String id) => kMapThemes[id] ?? kMapThemes['theme_classic']!;

/// Animated overlay drawn above the map (rain, snow, embers...).
class MapEffectPainter extends CustomPainter {
  MapEffectPainter(this.theme, this.t, {this.reduce = false});
  final MapThemeDef theme;
  final double t; // seconds
  final bool reduce;

  @override
  void paint(Canvas canvas, Size size) {
    if (!reduce) {
      switch (theme.effect) {
        case MapEffect.none:
          break;
        case MapEffect.grid:
          _grid(canvas, size);
        case MapEffect.rain:
          _rain(canvas, size);
        case MapEffect.snow:
          _fall(canvas, size, 70, Colors.white, 2.4, 28, wobble: 18);
        case MapEffect.embers:
          _rise(canvas, size);
        case MapEffect.petals:
          _petals(canvas, size);
        case MapEffect.digitalRain:
          _digital(canvas, size);
        case MapEffect.aurora:
          _aurora(canvas, size);
        case MapEffect.dust:
          _fall(canvas, size, 36, Colors.white.withValues(alpha: 0.45), 1.3, 8, wobble: 30);
        case MapEffect.stars:
          _stars(canvas, size);
      }
    }
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(colors: [Colors.transparent, theme.vignette], stops: const [0.6, 1.0], radius: 0.95)
              .createShader(rect));
  }

  double _rand(int i, int salt) {
    final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  void _grid(Canvas canvas, Size size) {
    final glow = Rect.fromLTWH(0, 0, size.width, size.height * 0.3);
    canvas.drawRect(
        glow,
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x44FF6EC7), Color(0x00FF6EC7)])
              .createShader(glow));
    final sun = Offset(size.width / 2, size.height * 0.07);
    canvas.drawCircle(sun, size.width * 0.12, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xAAFFD54F), Color(0x00FF4081)]).createShader(Rect.fromCircle(center: sun, radius: size.width * 0.12)));
  }

  void _rain(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.1;
    for (var i = 0; i < 100; i++) {
      final speed = 600 + _rand(i, 1) * 400;
      final x = _rand(i, 2) * size.width;
      final y = (_rand(i, 3) * size.height + t * speed) % (size.height + 40) - 20;
      canvas.drawLine(Offset(x, y), Offset(x - 3, y + 16), p);
    }
  }

  void _fall(Canvas canvas, Size size, int n, Color c, double r, double speed, {double wobble = 10}) {
    final p = Paint()..color = c;
    for (var i = 0; i < n; i++) {
      final sp = speed * (0.6 + _rand(i, 4));
      final x = (_rand(i, 5) * size.width + math.sin(t * 0.8 + i) * wobble) % size.width;
      final y = (_rand(i, 6) * size.height + t * sp) % (size.height + 10) - 5;
      canvas.drawCircle(Offset(x, y), r * (0.5 + _rand(i, 7)), p);
    }
  }

  void _rise(Canvas canvas, Size size) {
    for (var i = 0; i < 50; i++) {
      final sp = 25 + _rand(i, 8) * 40;
      final x = (_rand(i, 9) * size.width + math.sin(t * 1.3 + i) * 12) % size.width;
      final y = size.height - (_rand(i, 10) * size.height + t * sp) % (size.height + 10);
      final life = 1 - y / size.height;
      canvas.drawCircle(
          Offset(x, y),
          1.5 + _rand(i, 11) * 2,
          Paint()
            ..color = Color.lerp(const Color(0xFFFFEB3B), const Color(0xFFFF3D00), life)!.withValues(alpha: 0.7 * (1 - life * 0.6))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    }
  }

  void _petals(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFFF48FB1).withValues(alpha: 0.75);
    for (var i = 0; i < 40; i++) {
      final sp = 20 + _rand(i, 12) * 30;
      final x = (_rand(i, 13) * size.width + t * 15 + math.sin(t + i) * 25) % size.width;
      final y = (_rand(i, 14) * size.height + t * sp) % (size.height + 10) - 5;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * (0.5 + _rand(i, 15)) + i);
      canvas.drawOval(const Rect.fromLTWH(-4, -2.2, 8, 4.4), p);
      canvas.restore();
    }
  }

  // Digital rain: glyphs are rendered once into a small atlas image, then the
  // whole rain is drawn with a single drawAtlas call per frame (instead of
  // laying out hundreds of TextPainters every frame).
  static ui.Image? _glyphAtlas;
  static const _gw = 14.0, _gh = 18.0;

  static ui.Image _atlas() {
    final cached = _glyphAtlas;
    if (cached != null) return cached;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    for (var i = 0; i < 10; i++) {
      final tp = TextPainter(
        text: TextSpan(text: String.fromCharCode(0x30 + i), style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace')),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(i * _gw + (_gw - tp.width) / 2, (_gh - tp.height) / 2));
    }
    return _glyphAtlas = rec.endRecording().toImageSync((_gw * 10).toInt(), _gh.toInt());
  }

  void _digital(Canvas canvas, Size size) {
    const col = 18.0;
    final cols = (size.width / col).ceil();
    final transforms = <RSTransform>[];
    final rects = <Rect>[];
    final colors = <Color>[];
    for (var c = 0; c < cols; c++) {
      final speed = 80 + _rand(c, 16) * 160;
      final len = 6 + (_rand(c, 17) * 12).floor();
      final head = (_rand(c, 18) * size.height + t * speed) % (size.height + len * col);
      for (var k = 0; k < len; k++) {
        final y = head - k * col;
        if (y < 0 || y > size.height) continue;
        final a = (1 - k / len) * (k == 0 ? 0.7 : 0.3);
        final glyph = (_rand(c * 31 + k, (t * 6).floor()) * 10).floor().clamp(0, 9);
        transforms.add(RSTransform.fromComponents(rotation: 0, scale: 1, anchorX: 0, anchorY: 0, translateX: c * col, translateY: y));
        rects.add(Rect.fromLTWH(glyph * _gw, 0, _gw, _gh));
        colors.add((k == 0 ? const Color(0xFFCCFFDD) : const Color(0xFF00FF66)).withValues(alpha: a));
      }
    }
    if (transforms.isEmpty) return;
    canvas.drawAtlas(_atlas(), transforms, rects, colors, BlendMode.modulate, null, Paint());
  }

  void _aurora(Canvas canvas, Size size) {
    for (var band = 0; band < 3; band++) {
      final path = Path();
      final baseY = size.height * (0.02 + band * 0.04);
      path.moveTo(0, baseY);
      for (var x = 0.0; x <= size.width; x += 12) {
        path.lineTo(x, baseY + math.sin(x / 90 + t * (0.4 + band * 0.15) + band) * 18 + math.sin(x / 37 + t) * 6);
      }
      path
        ..lineTo(size.width, baseY + 120)
        ..lineTo(0, baseY + 120)
        ..close();
      final colors = [const Color(0xFF69F0AE), const Color(0xFF40C4FF), const Color(0xFFB388FF)];
      canvas.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colors[band].withValues(alpha: 0.25), colors[band].withValues(alpha: 0)])
                .createShader(Rect.fromLTWH(0, baseY - 30, size.width, 150))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    }
  }

  void _stars(Canvas canvas, Size size) {
    for (var i = 0; i < 45; i++) {
      final tw = (math.sin(t * (1 + _rand(i, 19) * 2) + i) + 1) / 2;
      canvas.drawCircle(Offset(_rand(i, 20) * size.width, _rand(i, 21) * size.height * 0.12), 1.1, Paint()..color = Colors.white.withValues(alpha: 0.15 + tw * 0.5));
    }
  }

  @override
  bool shouldRepaint(MapEffectPainter old) => old.t != t || old.theme.id != theme.id;
}
