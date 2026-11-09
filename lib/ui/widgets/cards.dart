import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../data/samples.dart';
import 'edition_views.dart';
import 'net_image.dart';
import 'ui_kit.dart';

export 'ui_kit.dart';

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
  const RarityLabel(this.rarity, {super.key, this.shiny = false, this.fontSize = 12});
  final Rarity rarity;
  final bool shiny;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final color = rarityColor(rarity);
    final text = Text(
      rarity.label,
      style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: fontSize, letterSpacing: 0.2),
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
    this.edition = Edition.standard,
    this.live = true,
    this.serial = 0,
  });
  final int serial;
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final double width;
  final Widget? footer;
  final Edition edition;

  /// Animate edition media (music video) — off for cheap previews.
  final bool live;

  @override
  Widget build(BuildContext context) {
    // Editions are exclusive of rarity and shininess: they use their own
    // colour and label.
    final isEd = edition != Edition.standard;
    final c = isEd ? editionColor(edition) : rarityColor(rarity);
    final glow = isEd || rarity.index >= Rarity.epic.index;
    final shiny = this.shiny && !isEd;
    if (edition == Edition.canvas) return _canvas(context, c);
    final sample = edition == Edition.sample ? SampleLibrary.of(song.id) : null;
    if (sample != null) return _canvas(context, c, sample: sample);
    final card = Container(
      width: width,
      padding: EdgeInsets.all(width * 0.045),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(width * 0.07),
        color: const Color(0xFF111114),
        border: Border.all(color: c.withValues(alpha: 0.85), width: 1.4),
        boxShadow: [
          if (glow) BoxShadow(color: c.withValues(alpha: 0.28), blurRadius: width * 0.14),
          const BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 1,
          child: sample != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(width * 0.045),
                  child: Stack(children: [
                    Positioned.fill(child: SampleBreakdownPanel(info: sample)),
                    if (serial > 0) Positioned(top: width * 0.02, right: width * 0.02, child: SerialBadge(serial, edition, size: width * 0.04)),
                  ]),
                )
              : LayoutBuilder(
                  builder: (context, box) => Art(song.cover(500), size: box.maxWidth, radius: width * 0.045, decodeSize: 500),
                ),
        ),
        SizedBox(height: width * 0.05),
        Row(children: [
          Expanded(child: VariantLabel(rarity: rarity, shiny: shiny, edition: edition, fontSize: width * 0.048)),
          Text(genreName(song.genreId).toUpperCase(), style: TextStyle(color: kTextTertiary, fontSize: width * 0.038, letterSpacing: 0.8)),
        ]),
        SizedBox(height: width * 0.02),
        Text(song.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: width * 0.072, fontWeight: FontWeight.w700, color: kTextPrimary, height: 1.15)),
        SizedBox(height: width * 0.015),
        Row(children: [
          if (song.artistPicMd5.isNotEmpty) ...[
            Art(artistPicUrl(song.artistPicMd5, size: 56), size: width * 0.075, circle: true),
            SizedBox(width: width * 0.025),
          ],
          Expanded(
            child: Text(song.artistName,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: width * 0.052, color: kTextSecondary, fontWeight: FontWeight.w500)),
          ),
        ]),
        Text(song.albumTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: width * 0.043, color: kTextTertiary)),
        ?footer,
      ]),
    );
    return Glint(enabled: shiny, child: card);
  }

  /// Canvas edition: the music video (or, without one, the cover art)
  /// fills the whole card; details float on top.
  ///
  /// Sample edition uses the same full-card layout: the cover art faintly
  /// behind, the two waveforms filling the card's height.
  Widget _canvas(BuildContext context, Color c, {SampleInfo? sample}) {
    const glow = true;
    final h = width * 1.48;
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(width * 0.07),
        color: Colors.black,
        border: Border.all(color: c.withValues(alpha: 0.9), width: 1.4),
        boxShadow: [
          if (glow) BoxShadow(color: c.withValues(alpha: 0.28), blurRadius: width * 0.14),
          const BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        if (sample == null)
          CanvasBackdrop(song: song, live: live)
        else ...[
          Opacity(opacity: 0.22, child: LayoutBuilder(builder: (context, box) => Art(song.cover(500), size: math.max(box.maxWidth, box.maxHeight), radius: 0, decodeSize: 600))),
          Positioned(left: 0, right: 0, top: 0, bottom: width * 0.3, child: SampleBreakdownPanel(info: sample, fullCard: true)),
        ],
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000), Color(0xF2000000)],
              stops: [0, 0.18, 0.45, 0.78, 1],
            ),
          ),
        ),
        Positioned(
          left: width * 0.05,
          right: width * 0.05,
          top: width * 0.05,
          child: Row(children: [
            Expanded(child: VariantLabel(rarity: rarity, shiny: false, edition: edition, fontSize: width * 0.048)),
            if (serial > 0) SerialBadge(serial, edition, size: width * 0.04),
          ]),
        ),
        Positioned(
          left: width * 0.05,
          right: width * 0.05,
          bottom: width * 0.05,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(genreName(song.genreId).toUpperCase(), style: TextStyle(color: Colors.white60, fontSize: width * 0.036, letterSpacing: 0.8)),
            SizedBox(height: width * 0.01),
            Text(song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: width * 0.078, fontWeight: FontWeight.w800, color: Colors.white, height: 1.1, shadows: const [Shadow(blurRadius: 8)])),
            SizedBox(height: width * 0.012),
            Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: width * 0.052, color: Colors.white, fontWeight: FontWeight.w500)),
            Text(song.albumTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: width * 0.042, color: Colors.white70)),
            ?footer,
          ]),
        ),
      ]),
    );
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
    this.edition = Edition.standard,
    this.serial = 0,
  });
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final Edition edition;
  final int serial;
  final bool favorite;
  final bool selected;
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = edition != Edition.standard ? editionColor(edition) : rarityColor(rarity);
    final shiny = this.shiny && edition == Edition.standard;
    Widget tile = Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? kAccent : kOutline, width: selected ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => Stack(children: [
              Art(song.cover(250), size: box.maxWidth, radius: 0, decodeSize: 160),
              if (edition != Edition.standard) Positioned(left: 5, bottom: 5, child: EditionBadge(edition, size: 8)),
              if (serial > 0) Positioned(right: 5, top: 5, child: SerialBadge(serial, edition, size: 9)),
              if (favorite) const Positioned(top: 5, right: 5, child: Icon(Icons.favorite, size: 14, color: Colors.white)),
              if (badge != null)
                Positioned(
                  bottom: 5,
                  right: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
                    child: Text(badge!, style: const TextStyle(fontSize: 10, color: Colors.white)),
                  ),
                ),
              if (selected) const Positioned(top: 5, left: 5, child: Icon(Icons.check_circle, color: kAccent, size: 20)),
            ]),
          ),
        ),
        Container(height: 2, color: c),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kTextPrimary)),
            Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: kTextSecondary)),
            const SizedBox(height: 2),
            VariantLabel(rarity: rarity, shiny: shiny, edition: edition, fontSize: 10),
          ]),
        ),
      ]),
    );
    if (shiny) tile = Glint(strength: 0.4, child: tile);
    return GestureDetector(onTap: onTap, onLongPress: onLongPress, child: tile);
  }
}

/// Compact row for list layout.
class CardRow extends StatelessWidget {
  const CardRow(
      {super.key, required this.song, required this.rarity, required this.shiny, this.trailing, this.onTap, this.subtitle, this.selected = false, this.edition = Edition.standard, this.serial = 0});
  final Edition edition;
  final int serial;
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
        color: selected ? kAccentDim : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(children: [
          Glint(enabled: shiny && edition == Edition.standard, strength: 0.4, child: Art(song.cover(56), size: 44, radius: 8)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, color: kTextPrimary)),
              Text(subtitle ?? '${song.artistName} · ${song.albumTitle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: kTextSecondary)),
            ]),
          ),
          const SizedBox(width: 8),
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (edition == Edition.standard) RarityDot(rarity, size: 7) else Icon(editionIcon(edition), size: 12, color: editionColor(edition)),
            const SizedBox(width: 6),
            SizedBox(width: 84, child: VariantLabel(rarity: rarity, shiny: shiny, edition: edition, serial: serial, fontSize: 11)),
          ]),
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
        child: Glass(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(formatNumber(value), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: kTextPrimary)),
          ]),
        ),
      );
}

String formatNumber(int v) {
  String trim(String x) => x.contains('.') ? x.replaceFirst(RegExp(r'\.?0+$'), '') : x;
  if (v.abs() >= 1000000000) return '${trim((v / 1e9).toStringAsFixed(2))}b';
  if (v.abs() >= 1000000) return '${trim((v / 1e6).toStringAsFixed(2))}m';
  if (v.abs() >= 100000) return '${(v / 1000).toStringAsFixed(0)}k';
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0 && s[i - 1] != '-') b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

const kCoinColor = Color(0xFFD9B45A);
const kBitsColor = kAccent;
const kCoinIcon = Icons.toll_rounded;
const kBitsIcon = Icons.diamond_outlined;

/// A price with the coin icon.
class CoinPrice extends StatelessWidget {
  const CoinPrice(this.value, {super.key, this.style = const TextStyle(fontWeight: FontWeight.w700, color: kTextPrimary), this.iconSize = 15});
  final int value;
  final TextStyle style;
  final double iconSize;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(kCoinIcon, size: iconSize, color: kCoinColor),
        const SizedBox(width: 3),
        Text(formatNumber(value), style: style),
      ]);
}
