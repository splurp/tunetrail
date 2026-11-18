import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

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

/// Height of a big card for its width (every edition): the card design's
/// 1122 × 1867.
const double kCardAspect = 1867 / 1122;

/// Diagonal light sweep painted over a child (the "shiny" glint).
class Glint extends StatelessWidget {
  const Glint({super.key, required this.child, this.enabled = true, this.strength = 0.65, this.radius = 0});
  final Widget child;
  final bool enabled;
  final double strength;

  /// Corner radius of the child: the sweep stays inside its rounded corners.
  final double radius;

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
              builder: (context, t, _) => ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: CustomPaint(painter: _GlintPainter(t, strength), size: Size.infinite),
              ),
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

/// Large song card, laid out from the card design (Tunetrail_card_design.psd,
/// a 1122 × 1867 card): the art fills the card — the music video for Canvas
/// and Live, the breakdown for Sample, the album cover at 80% width over a
/// blurred copy of it for the rest — with a darkened pane at the bottom
/// holding the title, artist, rarity pill and serial number. Used in detail
/// views, encounters, showcases and pack openings.
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

  /// Shown under the card.
  final Widget? footer;
  final Edition edition;

  /// Animate edition media (music video) — off for cheap previews.
  final bool live;

  // Measurements from the design, as fractions of the card's width.
  static const _radius = 120 / 1122;
  static const _stroke = 10 / 1122;
  static const _side = 108 / 1122; // text inset
  static const _titleSize = 80 / 1122;
  static const _artistSize = 42 / 1122;
  static const _pillH = 64 / 1122;
  static const _pillText = 38 / 1122;
  static const _pillPadX = 40 / 1122;
  static const _bottom = 66 / 1122; // pill to the card's bottom edge
  // The serial badge, smaller than in the design and sitting level with
  // the pill.
  static const _badgeRight = 76 / 1122;
  static const _badgeBottom = 66 / 1122;
  static const _badgeH = 66 / 1122;
  static const _badgePadX = 16 / 1122;
  static const _badgeRadius = 15 / 1122;
  static const _badgeText = 46 / 1122;

  /// The pane (80% black) covers the bottom 36.6% of the card, fading in
  /// over its top 35%.
  static const _paneFrac = 684 / 1867;

  @override
  Widget build(BuildContext context) {
    final w = width;
    final h = w * kCardAspect;
    // Editions are exclusive of rarity and shininess: their own colour and name.
    final isEd = edition != Edition.standard;
    final c = isEd ? editionColor(edition) : rarityColor(rarity);
    final shiny = this.shiny && !isEd;
    final sample = edition == Edition.sample ? SampleLibrary.of(song.id) : null;
    final radius = BorderRadius.circular(w * _radius);

    final Widget media;
    if (edition == Edition.canvas || edition == Edition.live) {
      media = CanvasBackdrop(song: song, live: live, liveFootage: edition == Edition.live);
    } else if (sample != null) {
      media = Stack(fit: StackFit.expand, children: [
        Opacity(opacity: 0.22, child: Art(song.cover(500), size: h, radius: 0, decodeSize: 600)),
        Positioned(left: 0, right: 0, top: 0, bottom: h * (_paneFrac - 0.06), child: SampleBreakdownPanel(info: sample, fullCard: true)),
      ]);
    } else {
      media = _CoverMedia(song: song, width: w);
    }

    final card = Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: const Color(0xFF151515),
        boxShadow: edition == Edition.canvas
            // Canvas editions glow in their rarity's colour.
            ? [
                BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: w * 0.05),
                BoxShadow(color: canvasGlowColor(rarity).withValues(alpha: 0.75), blurRadius: w * 0.13, spreadRadius: w * 0.008),
              ]
            : [BoxShadow(color: Colors.black.withValues(alpha: 0.8), blurRadius: w * 0.09)],
      ),
      // The edge stroke sits over everything, half outside the card.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: const Color(0xFF0E0E0E), width: w * _stroke, strokeAlign: BorderSide.strokeAlignCenter),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(fit: StackFit.expand, children: [
          media,
          // The pane: fades in, then 80% black to the bottom.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: h * _paneFrac,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x12000000), Color(0x38000000), Color(0x69000000), Color(0x96000000), Color(0xBD000000), Color(0xCC000000)],
                  stops: [0, 0.058, 0.117, 0.175, 0.234, 0.292, 0.351],
                ),
              ),
            ),
          ),
          // Inner shadow round the edge.
          IgnorePointer(child: CustomPaint(painter: _InnerShadow(radius: w * _radius, depth: w * 0.045))),
          // Title, artist and the rarity / edition pill.
          Positioned(
            left: w * _side,
            right: w * (_badgeRight + (serial > 0 ? 0.11 : 0.0)),
            bottom: w * _bottom,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _font(w * _titleSize, FontWeight.w600, Colors.white)),
              SizedBox(height: w * 0.024),
              Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: _font(w * _artistSize, FontWeight.w600, const Color(0xFF8D8D8D))),
              SizedBox(height: w * 0.036),
              _Pill(
                label: isEd ? edition.label : (shiny ? 'Shiny ${rarity.label}' : rarity.label),
                color: c,
                height: w * _pillH,
                padX: w * _pillPadX,
                fontSize: w * _pillText,
                shiny: shiny,
              ),
            ]),
          ),
          if (serial > 0)
            Positioned(
              right: w * _badgeRight,
              bottom: w * _badgeBottom,
              child: Container(
                height: w * _badgeH,
                padding: EdgeInsets.symmetric(horizontal: w * _badgePadX),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(w * _badgeRadius)),
                child: Text('#$serial', style: _font(w * _badgeText, FontWeight.w600, const Color(0xFF282828), letterSpacing: w * _badgeText * 0.04)),
              ),
            ),
        ]),
      ),
    );
    final out = Glint(enabled: shiny, radius: w * _radius, child: card);
    final f = footer;
    if (f == null) return out;
    return Column(mainAxisSize: MainAxisSize.min, children: [out, SizedBox(height: w * 0.04), f]);
  }

  static TextStyle _font(double size, FontWeight weight, Color color, {double letterSpacing = 0}) => TextStyle(
        fontFamily: kCardFont,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.0,
        letterSpacing: letterSpacing,
        leadingDistribution: TextLeadingDistribution.even,
      );
}

/// A Canvas card's glow: its rarity's colour (Rare a lighter blue).
Color canvasGlowColor(Rarity r) => r == Rarity.rare ? Color.lerp(rarityColor(r), Colors.white, 0.3)! : rarityColor(r);

/// The card typeface (Inter Tight, bundled).
const String kCardFont = 'InterTight';

/// A standard card's art: the album cover at 80% of the card's width over
/// a blurred, darkened copy of itself.
class _CoverMedia extends StatelessWidget {
  const _CoverMedia({required this.song, required this.width});
  final Song song;
  final double width;

  @override
  Widget build(BuildContext context) {
    final w = width;
    final h = w * kCardAspect;
    return Stack(fit: StackFit.expand, children: [
      ClipRect(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: w * 0.06, sigmaY: w * 0.06, tileMode: TileMode.clamp),
          // Square, so centred to fill the taller card evenly.
          child: OverflowBox(maxWidth: h, maxHeight: h, child: Art(song.cover(250), size: h, radius: 0, decodeSize: 200)),
        ),
      ),
      const ColoredBox(color: Color(0xA6000000)),
      Positioned(
        left: w * 0.1,
        top: w * 0.1,
        width: w * 0.8,
        height: w * 0.8,
        child: DecoratedBox(
          decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: w * 0.06, offset: Offset(0, w * 0.015))]),
          child: Art(song.cover(500), size: w * 0.8, radius: 0, decodeSize: 500),
        ),
      ),
    ]);
  }
}

/// Rarity / edition name on a solid pill of its colour.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, required this.height, required this.padX, required this.fontSize, this.shiny = false});
  final String label;
  final Color color;
  final double height, padX, fontSize;
  final bool shiny;

  @override
  Widget build(BuildContext context) {
    // The text is a pale tint of the pill's own colour.
    final ink = Color.lerp(color, Colors.white, 0.86)!;
    Widget text = Text(label, maxLines: 1, style: SongCardView._font(fontSize, FontWeight.w600, ink));
    if (shiny) {
      text = ValueListenableBuilder<double>(
        valueListenable: glintClock,
        builder: (context, t, child) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            final x = rect.width * (t * 2.2 - 0.6);
            return LinearGradient(
              colors: [ink, ink, Colors.white, const Color(0xFFE1F5FE), ink, ink],
              stops: const [0, 0.3, 0.45, 0.55, 0.7, 1],
            ).createShader(Rect.fromLTWH(x - rect.width * 0.5, 0, rect.width, rect.height));
          },
          child: child,
        ),
        child: text,
      );
    }
    // Hugs its text (it sits in a left-aligned column).
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: padX),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height / 2)),
      child: Center(widthFactor: 1, child: text),
    );
  }
}

/// A soft dark shadow inside a rounded card's edge.
class _InnerShadow extends CustomPainter {
  _InnerShadow({required this.radius, required this.depth});
  final double radius, depth;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.clipRRect(rrect);
    final frame = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((Offset.zero & size).inflate(depth * 2))
      ..addRRect(rrect.deflate(depth * 0.3));
    canvas.drawPath(
      frame,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.9)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, depth * 0.3),
    );
  }

  @override
  bool shouldRepaint(_InnerShadow old) => old.radius != radius || old.depth != depth;
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
    // The card design in miniature: a dark rounded card, the cover, then
    // the title, artist and a rarity / edition pill in the card font.
    Widget tile = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? kAccent : const Color(0xFF2A2A2A), width: selected ? 2 : 1),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: SongCardView._font(12, FontWeight.w600, Colors.white)),
            const SizedBox(height: 3),
            Text(song.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: SongCardView._font(10.5, FontWeight.w600, const Color(0xFF8D8D8D))),
            const SizedBox(height: 5),
            _Pill(
              label: edition != Edition.standard ? edition.label : (shiny ? 'Shiny ${rarity.label}' : rarity.label),
              color: c,
              height: 15,
              padX: 7,
              fontSize: 9,
              shiny: shiny,
            ),
          ]),
        ),
      ]),
    );
    if (shiny) tile = Glint(strength: 0.4, radius: 12, child: tile);
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
          Glint(enabled: shiny && edition == Edition.standard, strength: 0.4, radius: 8, child: Art(song.cover(56), size: 44, radius: 8)),
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
  const CoinPrice(this.value, {super.key, this.style = const TextStyle(fontWeight: FontWeight.w600, color: kTextPrimary), this.iconSize = 15});
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
