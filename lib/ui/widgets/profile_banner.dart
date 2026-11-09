import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../game/profile_themes.dart';
import '../app.dart';
import 'cards.dart';

/// Draws a profile theme's background: its gradient plus pattern.
class ProfileThemeBackground extends StatelessWidget {
  const ProfileThemeBackground({super.key, required this.theme, this.child, this.radius = 20});
  final ProfileTheme theme;
  final Widget? child;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CustomPaint(
          painter: _PatternPainter(theme),
          child: child,
        ),
      );
}

class _PatternPainter extends CustomPainter {
  _PatternPainter(this.t);
  final ProfileTheme t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: t.colors).createShader(rect));
    final p = Paint()
      ..color = t.accent.withValues(alpha: 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final fill = Paint()..color = t.accent.withValues(alpha: 0.18);
    final r = math.Random(t.id.hashCode);
    switch (t.pattern) {
      case ProfilePattern.none:
        break;
      case ProfilePattern.dots:
        for (var y = 8.0; y < size.height; y += 16) {
          for (var x = (y ~/ 16).isEven ? 8.0 : 16.0; x < size.width; x += 16) {
            canvas.drawCircle(Offset(x, y), 1.8, fill);
          }
        }
      case ProfilePattern.stripes:
        p.strokeWidth = 10;
        for (var x = -size.height; x < size.width; x += 28) {
          canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
        }
      case ProfilePattern.grid:
        // A neon floor grid in perspective.
        final horizon = size.height * 0.35;
        for (var i = 0; i < 9; i++) {
          final y = horizon + (size.height - horizon) * math.pow(i / 8, 1.8);
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p..color = t.accent.withValues(alpha: 0.12 + 0.2 * i / 8));
        }
        for (var i = -10; i <= 10; i++) {
          canvas.drawLine(Offset(size.width / 2 + i * 14, horizon), Offset(size.width / 2 + i * 90, size.height), p..color = t.accent.withValues(alpha: 0.2));
        }
      case ProfilePattern.grooves:
        final c = Offset(size.width * 0.85, size.height * 0.5);
        for (var rad = 12.0; rad < size.width; rad += 6) {
          canvas.drawCircle(c, rad, p..color = t.accent.withValues(alpha: 0.05 + (rad % 18 == 0 ? 0.08 : 0)));
        }
        canvas.drawCircle(c, 10, fill);
      case ProfilePattern.stars:
        for (var i = 0; i < 70; i++) {
          final o = Offset(r.nextDouble() * size.width, r.nextDouble() * size.height);
          canvas.drawCircle(o, r.nextDouble() * 1.4 + 0.3, Paint()..color = t.accent.withValues(alpha: 0.25 + r.nextDouble() * 0.5));
        }
      case ProfilePattern.waves:
        for (var k = 0; k < 6; k++) {
          final path = Path();
          final base = size.height * (0.25 + k * 0.13);
          for (var x = 0.0; x <= size.width; x += 6) {
            final y = base + math.sin(x / 26 + k) * (6 + k * 1.5);
            x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
          }
          canvas.drawPath(path, p..color = t.accent.withValues(alpha: 0.1 + k * 0.03));
        }
      case ProfilePattern.rays:
        final c = Offset(size.width * 0.5, size.height * 1.1);
        for (var i = 0; i < 18; i++) {
          final a = math.pi + i * math.pi / 17;
          final path = Path()
            ..moveTo(c.dx, c.dy)
            ..lineTo(c.dx + math.cos(a - 0.04) * size.width * 2, c.dy + math.sin(a - 0.04) * size.width * 2)
            ..lineTo(c.dx + math.cos(a + 0.04) * size.width * 2, c.dy + math.sin(a + 0.04) * size.width * 2)
            ..close();
          if (i.isEven) canvas.drawPath(path, Paint()..color = t.accent.withValues(alpha: 0.09));
        }
      case ProfilePattern.confetti:
        const colors = [Color(0xFFFF5252), Color(0xFFFFEB3B), Color(0xFF69F0AE), Color(0xFF40C4FF), Color(0xFFE040FB)];
        for (var i = 0; i < 60; i++) {
          canvas.save();
          canvas.translate(r.nextDouble() * size.width, r.nextDouble() * size.height);
          canvas.rotate(r.nextDouble() * math.pi);
          canvas.drawRect(const Rect.fromLTWH(-3, -1.5, 6, 3), Paint()..color = colors[i % colors.length].withValues(alpha: 0.55));
          canvas.restore();
        }
      case ProfilePattern.hearts:
        for (var i = 0; i < 24; i++) {
          final o = Offset(r.nextDouble() * size.width, r.nextDouble() * size.height);
          final s = 4 + r.nextDouble() * 6;
          final h = Path()
            ..moveTo(o.dx, o.dy + s * 0.9)
            ..cubicTo(o.dx - s * 1.3, o.dy, o.dx - s * 0.6, o.dy - s, o.dx, o.dy - s * 0.3)
            ..cubicTo(o.dx + s * 0.6, o.dy - s, o.dx + s * 1.3, o.dy, o.dx, o.dy + s * 0.9);
          canvas.drawPath(h, fill);
        }
    }
    // Keep text readable on every theme.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: 0.35)])
            .createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_PatternPainter old) => old.t.id != t.id;
}

/// The header of a profile page: the player's name over their theme.
class ProfileBanner extends StatelessWidget {
  const ProfileBanner({super.key, required this.themeId, required this.name, this.subtitle, this.actions = const [], this.height = 132});
  final String themeId;
  final String name;
  final String? subtitle;
  final List<Widget> actions;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = profileThemeById(themeId);
    final light = t.light;
    final fg = light ? Colors.black : Colors.white;
    return SizedBox(
      height: height,
      child: ProfileThemeBackground(
        theme: t,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            const Spacer(),
            // Plain Text: whatever a player names themselves is shown as
            // characters, never interpreted.
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: fg, shadows: [Shadow(color: Colors.black.withValues(alpha: light ? 0 : 0.5), blurRadius: 6)])),
            if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.75))),
          ]),
        ),
      ),
    );
  }
}

/// Every profile theme: equip owned ones, buy the rest with coins.
class ProfileThemePicker extends StatelessWidget {
  const ProfileThemePicker({super.key, this.embedded = false});

  /// Shown inside another page (the shop) rather than as its own page.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final grid = GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 260, mainAxisExtent: 150, crossAxisSpacing: 12, mainAxisSpacing: 12),
      itemCount: kProfileThemes.length,
      itemBuilder: (context, i) {
        final t = kProfileThemes[i];
        final owned = p.owned.contains(t.id);
        final on = p.profileTheme == t.id;
        final light = t.light;
        return GestureDetector(
          onTap: () async {
            if (owned) return g.setProfileTheme(t.id);
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text('Unlock ${t.name}?'),
                content: SizedBox(height: 90, child: ProfileThemeBackground(theme: t, radius: 14)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: p.bits < t.price ? null : () => Navigator.pop(ctx, true), child: Text('Buy · ${formatNumber(t.price)} bits')),
                ],
              ),
            );
            if (ok == true) {
              try {
                g.buyProfileTheme(t);
              } catch (e) {
                g.toast('$e');
              }
            }
          },
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: on ? kAccent : kOutline, width: on ? 2 : 1)),
            padding: const EdgeInsets.all(3),
            child: ProfileThemeBackground(
              theme: t,
              radius: 15,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Spacer(),
                    if (on)
                      const Icon(Icons.check_circle, color: Colors.white, size: 20)
                    else if (!owned)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(20)),
                        child: Text('${formatNumber(t.price)} bits', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                  ]),
                  const Spacer(),
                  Text(t.name, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: light ? Colors.black : Colors.white)),
                  Text(owned ? (on ? 'In use' : 'Tap to use') : (t.free ? 'Free' : 'Tap to unlock'),
                      style: TextStyle(fontSize: 11, color: (light ? Colors.black : Colors.white).withValues(alpha: 0.7))),
                ]),
              ),
            ),
          ),
        );
      },
    );
    if (embedded) return grid;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile theme'), actions: [
        Padding(padding: const EdgeInsets.only(right: 12), child: CurrencyChip(icon: kBitsIcon, value: p.bits, color: kBitsColor)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: ProfileBanner(themeId: p.profileTheme, name: p.name, subtitle: 'Level ${p.level}'),
        ),
        Expanded(child: grid),
      ]),
    );
  }
}

/// A whole page dressed in a profile theme: the theme's background behind
/// everything, dimmed so text stays readable.
class ProfileThemePage extends StatelessWidget {
  const ProfileThemePage({super.key, required this.themeId, required this.child});
  final String themeId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = profileThemeById(themeId);
    return Stack(children: [
      Positioned.fill(child: ProfileThemeBackground(theme: t, radius: 0)),
      Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: t.light ? 0.62 : 0.45))),
      child,
    ]);
  }
}
