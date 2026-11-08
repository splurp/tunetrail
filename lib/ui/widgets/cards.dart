import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import 'net_image.dart';

Color rarityColor(Rarity r) => Color(r.argb);

/// One app-wide animation clock (0→1 every 2.4 s) shared by every shiny
/// glint, so thousands of shiny cards cost one ticker, not one each.
final ValueNotifier<double> glintClock = ValueNotifier(0);

/// Diagonal light sweep painted over a child (the "shiny" glint).
class Glint extends StatelessWidget {
  const Glint({super.key, required this.child, this.enabled = true, this.strength = 0.65});
  final Widget child;
  final bool enabled;
  final double strength;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Stack(fit: StackFit.passthrough, children: [
      child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: ValueListenableBuilder<double>(
              valueListenable: glintClock,
              builder: (context, t, _) => CustomPaint(painter: _GlintPainter(t, strength)),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _GlintPainter extends CustomPainter {
  _GlintPainter(this.t, this.strength);
  final double t;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width + size.height;
    final x = -size.height + w * ((t * 1.6) % 1.6 - 0.3);
    final rect = Offset.zero & size;
    final shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: strength * 0.55),
        const Color(0xFFB3E5FC).withValues(alpha: strength * 0.8),
        const Color(0xFFF8BBD0).withValues(alpha: strength * 0.55),
        Colors.white.withValues(alpha: 0),
      ],
      stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
    ).createShader(Rect.fromLTWH(x, 0, size.height * 0.9, size.height));
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(rect, Paint()..shader = shader..blendMode = BlendMode.plus);
    // Sparkles.
    final sp = Paint()..color = Colors.white.withValues(alpha: strength);
    final rnd = math.Random(size.width.toInt() * 31 + size.height.toInt());
    for (var i = 0; i < 5; i++) {
      final px = rnd.nextDouble() * size.width;
      final py = rnd.nextDouble() * size.height;
      final phase = (t * 2 + i / 5) % 1;
      final r = math.sin(phase * math.pi) * 2.6;
      if (r > 0.3) _star(canvas, Offset(px, py), r, sp);
    }
    canvas.restore();
  }

  void _star(Canvas c, Offset o, double r, Paint p) {
    final path = Path()
      ..moveTo(o.dx, o.dy - r * 2)
      ..lineTo(o.dx + r * 0.5, o.dy - r * 0.5)
      ..lineTo(o.dx + r * 2, o.dy)
      ..lineTo(o.dx + r * 0.5, o.dy + r * 0.5)
      ..lineTo(o.dx, o.dy + r * 2)
      ..lineTo(o.dx - r * 0.5, o.dy + r * 0.5)
      ..lineTo(o.dx - r * 2, o.dy)
      ..lineTo(o.dx - r * 0.5, o.dy - r * 0.5)
      ..close();
    c.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_GlintPainter old) => old.t != t;
}

/// Rarity name; shiny cards get an animated glint across the text.
class RarityLabel extends StatelessWidget {
  const RarityLabel(this.rarity, {super.key, this.shiny = false, this.fontSize = 12, this.showStar = true});
  final Rarity rarity;
  final bool shiny;
  final double fontSize;
  final bool showStar;

  @override
  Widget build(BuildContext context) {
    final color = rarityColor(rarity);
    final text = Text(
      shiny && showStar ? '✦ Shiny ${rarity.label}' : rarity.label,
      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: fontSize, letterSpacing: 0.3),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (!shiny) return text;
    return ValueListenableBuilder<double>(
      valueListenable: glintClock,
      builder: (context, t, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          final x = rect.width * (t * 2.2 - 0.6);
          return LinearGradient(
            colors: [color, color, Colors.white, const Color(0xFFE1F5FE), color, color],
            stops: const [0, 0.3, 0.45, 0.55, 0.7, 1],
          ).createShader(Rect.fromLTWH(x - rect.width * 0.5, 0, rect.width, rect.height));
        },
        child: child,
      ),
      child: text,
    );
  }
}

/// Small rarity pip.
class RarityDot extends StatelessWidget {
  const RarityDot(this.rarity, {super.key, this.size = 10});
  final Rarity rarity;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: rarityColor(rarity), shape: BoxShape.circle),
      );
}

/// Large song card: art, title, artist, album, rarity. Used in detail
/// views, encounters and pack openings.
class SongCardView extends StatelessWidget {
  const SongCardView({
    super.key,
    required this.song,
    required this.rarity,
    required this.shiny,
    this.width = 260,
    this.footer,
  });
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final double width;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = rarityColor(rarity);
    final card = Container(
      width: width,
      padding: EdgeInsets.all(width * 0.045),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(width * 0.07),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(c, Colors.black, 0.55)!, const Color(0xFF12141F), Color.lerp(c, Colors.black, 0.7)!],
        ),
        border: Border.all(color: c, width: width * 0.014),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.55), blurRadius: width * 0.12, spreadRadius: 1)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: RarityLabel(rarity, shiny: shiny, fontSize: width * 0.055)),
          Text(genreName(song.genreId), style: TextStyle(color: Colors.white54, fontSize: width * 0.045)),
        ]),
        SizedBox(height: width * 0.03),
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(
            builder: (context, box) => Art(song.cover(500), size: box.maxWidth, radius: width * 0.04, decodeSize: 500),
          ),
        ),
        SizedBox(height: width * 0.04),
        Text(song.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: width * 0.075, fontWeight: FontWeight.w800, color: Colors.white, height: 1.1)),
        SizedBox(height: width * 0.015),
        Row(children: [
          if (song.artistPicMd5.isNotEmpty) ...[
            Art(artistPicUrl(song.artistPicMd5, size: 56), size: width * 0.08, circle: true),
            SizedBox(width: width * 0.025),
          ],
          Expanded(
            child: Text(song.artistName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: width * 0.055, color: Colors.white70, fontWeight: FontWeight.w600)),
          ),
        ]),
        Text(song.albumTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: width * 0.045, color: Colors.white38)),
        ?footer,
      ]),
    );
    return Glint(enabled: shiny, child: card);
  }
}

/// Compact tile used in the 100k-item collection grid. Deliberately cheap:
/// one decoration, one image, two text lines.
class CardTile extends StatelessWidget {
  const CardTile({
    super.key,
    required this.song,
    required this.rarity,
    required this.shiny,
    this.favorite = false,
    this.selected = false,
    this.badge,
    this.onTap,
    this.onLongPress,
  });
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final bool favorite;
  final bool selected;
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = rarityColor(rarity);
    Widget tile = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF171A28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: selected ? Colors.white : c, width: selected ? 3 : 2),
      ),
      padding: const EdgeInsets.all(5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => Stack(children: [
              Art(song.cover(250), size: box.maxWidth, radius: 6, decodeSize: 160),
              if (favorite)
                const Positioned(top: 2, right: 2, child: Icon(Icons.favorite, size: 16, color: Colors.pinkAccent)),
              if (badge != null)
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                    child: Text(badge!, style: const TextStyle(fontSize: 10, color: Colors.white)),
                  ),
                ),
              if (selected)
                const Positioned(top: 2, left: 2, child: Icon(Icons.check_circle, color: Colors.white, size: 20)),
            ]),
          ),
        ),
        const SizedBox(height: 4),
        Text(song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
        Text(song.artistName,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white60)),
        RarityLabel(rarity, shiny: shiny, fontSize: 10.5),
      ]),
    );
    if (shiny) tile = Glint(strength: 0.4, child: tile);
    return GestureDetector(onTap: onTap, onLongPress: onLongPress, child: tile);
  }
}

/// Compact row for list layout.
class CardRow extends StatelessWidget {
  const CardRow({super.key, required this.song, required this.rarity, required this.shiny, this.trailing, this.onTap, this.subtitle, this.selected = false});
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? subtitle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? Colors.white10 : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Container(width: 4, height: 44, color: rarityColor(rarity)),
          const SizedBox(width: 8),
          Glint(enabled: shiny, strength: 0.4, child: Art(song.cover(56), size: 44)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(subtitle ?? '${song.artistName} • ${song.albumTitle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 92, child: Align(alignment: Alignment.centerRight, child: RarityLabel(rarity, shiny: shiny, fontSize: 11))),
          ?trailing,
        ]),
      ),
    );
  }
}

class CurrencyChip extends StatelessWidget {
  const CurrencyChip({super.key, required this.icon, required this.value, required this.color, this.onTap});
  final IconData icon;
  final int value;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.7)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(formatNumber(value), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
      );
}

String formatNumber(int v) {
  if (v.abs() >= 10000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v.abs() >= 100000) return '${(v / 1000).toStringAsFixed(0)}k';
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0 && s[i - 1] != '-') b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

const kCoinColor = Color(0xFFFFD54F);
const kBitsColor = Color(0xFF40C4FF);
const kCoinIcon = Icons.monetization_on;
const kBitsIcon = Icons.memory;
