import 'dart:math' as math;

import 'package:flutter/material.dart';

enum MapEffect { none, grid, rain, snow, embers, petals, digitalRain, aurora, dust, stars }

/// A visual style for the world map: tile source + colour grading + an
/// animated overlay effect.
class MapThemeDef {
  const MapThemeDef({
    required this.id,
    required this.tiles,
    this.matrix,
    this.effect = MapEffect.none,
    this.vignette = const Color(0x66000000),
    this.accent = const Color(0xFF00E5FF),
    this.background = const Color(0xFF0B0D16),
  });
  final String id;
  final String tiles;
  final List<double>? matrix;
  final MapEffect effect;
  final Color vignette;
  final Color accent;
  final Color background;
}

/// Default street tiles: OpenStreetMap (no API key). Every theme is a
/// colour grade applied on top, so a single tile cache serves all themes.
/// A custom tile server (e.g. a MapTiler/Stadia URL with your own key) can
/// be set in Settings.
const kDefaultTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _voyager = kDefaultTileUrl;
const _dark = kDefaultTileUrl;
const _light = kDefaultTileUrl;

/// "Levels" grade: tile luminance in [lo, hi] is stretched onto a gradient
/// from [dark] to [light]. On OSM tiles roads are the brightest feature, so
/// dark themes get glowing streets on a dark background.
List<double> levels(Color dark, Color light, {double lo = 0.84, double hi = 1.0}) {
  final span = hi - lo;
  List<double> row(double d, double l) {
    final k = (l - d) / span;
    return [0.2126 * k, 0.7152 * k, 0.0722 * k, 0, d * 255 - lo * k * 255];
  }

  return [...row(dark.r, light.r), ...row(dark.g, light.g), ...row(dark.b, light.b), 0, 0, 0, 1, 0];
}

/// Maps tile luminance onto a gradient from [dark] to [light].
List<double> duotone(Color dark, Color light, {double contrast = 1.0}) {
  double ch(double v) => v * 255;
  final dr = ch(dark.r), dg = ch(dark.g), db = ch(dark.b);
  final lr = ch(light.r), lg = ch(light.g), lb = ch(light.b);
  List<double> row(double d, double l) {
    final k = (l - d) / 255 * contrast;
    final off = d - (contrast - 1) * (l - d) / 2;
    return [0.2126 * k, 0.7152 * k, 0.0722 * k, 0, off];
  }

  return [...row(dr, lr), ...row(dg, lg), ...row(db, lb), 0, 0, 0, 1, 0];
}

const List<double> _sepia = [
  0.393, 0.769, 0.189, 0, 0,
  0.349, 0.686, 0.168, 0, 0,
  0.272, 0.534, 0.131, 0, 0,
  0, 0, 0, 1, 0,
];

final Map<String, MapThemeDef> kMapThemes = {
  'theme_classic': const MapThemeDef(id: 'theme_classic', tiles: _voyager, vignette: Color(0x33000000), accent: Color(0xFF00B8D4), background: Color(0xFFEDEBE6)),
  'theme_midnight': MapThemeDef(
      id: 'theme_midnight', tiles: _dark, matrix: levels(const Color(0xFF02040F), const Color(0xFF8FB4FF)), effect: MapEffect.stars, accent: const Color(0xFF536DFE)),
  'theme_synthwave': MapThemeDef(
      id: 'theme_synthwave', tiles: _dark, matrix: levels(const Color(0xFF0D0020), const Color(0xFFFF5CE1)), effect: MapEffect.grid, vignette: const Color(0x88320050), accent: const Color(0xFFFF00C8)),
  'theme_vaporwave': MapThemeDef(
      id: 'theme_vaporwave', tiles: _light, matrix: duotone(const Color(0xFF3A1C71), const Color(0xFFFFC6EC)), effect: MapEffect.dust, vignette: const Color(0x5500D2D3), accent: const Color(0xFF48DBFB)),
  'theme_noir': MapThemeDef(
      id: 'theme_noir', tiles: _light, matrix: duotone(const Color(0xFF000000), const Color(0xFFE0E0E0), contrast: 1.6), effect: MapEffect.rain, vignette: const Color(0xAA000000), accent: Colors.white),
  'theme_vinyl': const MapThemeDef(id: 'theme_vinyl', tiles: _voyager, matrix: _sepia, effect: MapEffect.dust, vignette: Color(0x884E342E), accent: Color(0xFFD7A86E)),
  'theme_matrix': MapThemeDef(
      id: 'theme_matrix', tiles: _dark, matrix: levels(const Color(0xFF000500), const Color(0xFF33FF88)), effect: MapEffect.digitalRain, vignette: const Color(0x99000000), accent: const Color(0xFF00FF66)),
  'theme_arctic': MapThemeDef(
      id: 'theme_arctic', tiles: _light, matrix: duotone(const Color(0xFF0D47A1), const Color(0xFFF1FBFF)), effect: MapEffect.snow, vignette: const Color(0x4400B8D4), accent: const Color(0xFF80DEEA)),
  'theme_lava': MapThemeDef(
      id: 'theme_lava', tiles: _dark, matrix: levels(const Color(0xFF120000), const Color(0xFFFF7A1A)), effect: MapEffect.embers, vignette: const Color(0x99400000), accent: const Color(0xFFFF5722)),
  'theme_aurora': MapThemeDef(
      id: 'theme_aurora', tiles: _dark, matrix: levels(const Color(0xFF00080F), const Color(0xFF8CFFDA)), effect: MapEffect.aurora, accent: const Color(0xFF69F0AE)),
  'theme_sakura': MapThemeDef(
      id: 'theme_sakura', tiles: _light, matrix: duotone(const Color(0xFF6D2140), const Color(0xFFFFF0F5)), effect: MapEffect.petals, vignette: const Color(0x44F06292), accent: const Color(0xFFF48FB1)),
};

MapThemeDef themeById(String id) => kMapThemes[id] ?? kMapThemes['theme_classic']!;

/// Animated overlay drawn above the map tiles.
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
          _fall(canvas, size, 70, Colors.white, 2.6, 28, wobble: 18);
        case MapEffect.embers:
          _rise(canvas, size);
        case MapEffect.petals:
          _petals(canvas, size);
        case MapEffect.digitalRain:
          _digital(canvas, size);
        case MapEffect.aurora:
          _aurora(canvas, size);
        case MapEffect.dust:
          _fall(canvas, size, 40, Colors.white.withValues(alpha: 0.5), 1.4, 8, wobble: 30);
        case MapEffect.stars:
          _stars(canvas, size);
      }
    }
    // Vignette.
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.transparent, theme.vignette],
            stops: const [0.55, 1.0],
            radius: 0.9,
          ).createShader(rect));
  }

  double _rand(int i, int salt) {
    final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  void _grid(Canvas canvas, Size size) {
    final horizon = size.height * 0.0;
    final p = Paint()
      ..color = const Color(0xFFFF00C8).withValues(alpha: 0.18)
      ..strokeWidth = 1.2;
    final offset = (t * 30) % 40;
    for (var y = horizon + offset; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    for (var x = -size.width; x < size.width * 2; x += 60) {
      canvas.drawLine(Offset(size.width / 2 + (x - size.width / 2) * 0.2, horizon), Offset(x, size.height), p);
    }
    final glow = Rect.fromLTWH(0, 0, size.width, size.height * 0.35);
    canvas.drawRect(
        glow,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x55FF6EC7), Color(0x00FF6EC7)],
          ).createShader(glow));
  }

  void _rain(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1.2;
    for (var i = 0; i < 110; i++) {
      final speed = 600 + _rand(i, 1) * 400;
      final x = _rand(i, 2) * size.width;
      final y = (_rand(i, 3) * size.height + t * speed) % (size.height + 40) - 20;
      canvas.drawLine(Offset(x, y), Offset(x - 3, y + 16), p);
    }
    // Film grain.
    final g = Paint()..color = Colors.white.withValues(alpha: 0.05);
    final frame = (t * 24).floor();
    for (var i = 0; i < 150; i++) {
      canvas.drawCircle(Offset(_rand(i, frame) * size.width, _rand(i + 500, frame) * size.height), 0.8, g);
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
    for (var i = 0; i < 60; i++) {
      final sp = 25 + _rand(i, 8) * 40;
      final x = (_rand(i, 9) * size.width + math.sin(t * 1.3 + i) * 12) % size.width;
      final y = size.height - (_rand(i, 10) * size.height + t * sp) % (size.height + 10);
      final life = 1 - y / size.height;
      final p = Paint()
        ..color = Color.lerp(const Color(0xFFFFEB3B), const Color(0xFFFF3D00), life)!.withValues(alpha: 0.75 * (1 - life * 0.6))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawCircle(Offset(x, y), 1.5 + _rand(i, 11) * 2, p);
    }
  }

  void _petals(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFFF8BBD0).withValues(alpha: 0.85);
    for (var i = 0; i < 45; i++) {
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

  void _digital(Canvas canvas, Size size) {
    const col = 18.0;
    final cols = (size.width / col).ceil();
    for (var c = 0; c < cols; c++) {
      final speed = 80 + _rand(c, 16) * 160;
      final len = 6 + (_rand(c, 17) * 14).floor();
      final head = (_rand(c, 18) * size.height + t * speed) % (size.height + len * col);
      for (var k = 0; k < len; k++) {
        final y = head - k * col;
        if (y < 0 || y > size.height) continue;
        final a = (1 - k / len) * (k == 0 ? 0.9 : 0.45);
        final glyph = (_rand(c * 31 + k, (t * 6).floor()) * 10).floor();
        final tp = TextPainter(
          text: TextSpan(
              text: String.fromCharCode(0x30 + glyph),
              style: TextStyle(color: (k == 0 ? const Color(0xFFCCFFDD) : const Color(0xFF00FF66)).withValues(alpha: a), fontSize: 13, fontFamily: 'monospace')),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(c * col, y));
      }
    }
  }

  void _aurora(Canvas canvas, Size size) {
    for (var band = 0; band < 3; band++) {
      final path = Path();
      final baseY = size.height * (0.12 + band * 0.08);
      path.moveTo(0, baseY);
      for (var x = 0.0; x <= size.width; x += 12) {
        path.lineTo(x, baseY + math.sin(x / 90 + t * (0.4 + band * 0.15) + band) * 26 + math.sin(x / 37 + t) * 8);
      }
      path.lineTo(size.width, baseY + 140);
      path.lineTo(0, baseY + 140);
      path.close();
      final colors = [const Color(0xFF69F0AE), const Color(0xFF40C4FF), const Color(0xFFB388FF)];
      canvas.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors[band].withValues(alpha: 0.28), colors[band].withValues(alpha: 0)],
            ).createShader(Rect.fromLTWH(0, baseY - 30, size.width, 170))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    }
  }

  void _stars(Canvas canvas, Size size) {
    for (var i = 0; i < 50; i++) {
      final tw = (math.sin(t * (1 + _rand(i, 19) * 2) + i) + 1) / 2;
      canvas.drawCircle(Offset(_rand(i, 20) * size.width, _rand(i, 21) * size.height), 1.2,
          Paint()..color = Colors.white.withValues(alpha: 0.15 + tw * 0.5));
    }
  }

  @override
  bool shouldRepaint(MapEffectPainter old) => old.t != t || old.theme.id != theme.id;
}
