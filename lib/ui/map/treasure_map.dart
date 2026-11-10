import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/spawns.dart' show metersBetween;
import '../../map3d/map_data.dart';
import '../../map3d/tile_data.dart';
import '../app.dart';

/// Shows the treasure map: a little scrap of paper with the area around
/// the sand castle seen from above, an X where the chest is buried and the
/// player's head where they are now.
Future<void> showTreasureMap(BuildContext context) => showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (ctx) => const _TreasureMapDialog(),
    );

class _TreasureMapDialog extends StatelessWidget {
  const _TreasureMapDialog();

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final spot = g.world.treasureSpot, castle = g.world.treasureCastle;
    if (spot == null || castle == null) {
      // The map was used up or lost while it was open.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    final d = metersBetween(g.location.position, spot).round();
    final side = math.min(MediaQuery.sizeOf(context).shortestSide * 0.62, 250.0);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Transform.rotate(
          angle: -0.045,
          child: SizedBox(
            width: side,
            height: side,
            child: CustomPaint(
              painter: _PaperPainter(
                map: g.mapData,
                castle: castle,
                spot: spot,
                player: g.location.position,
                headColor: Color(g.profile.figureColor),
                heading: g.location.heading,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          d <= kTreasureDigMeters ? 'You\'re at the X — close this and tap the map icon to dig!' : 'X marks the spot · $d m away',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
        ),
        const SizedBox(height: 4),
        Text(
          'Stay within ${kTreasureMaxMeters.round()} m of where you found the map, or it crumbles away.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        const SizedBox(height: 10),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ]),
    );
  }
}

class _PaperPainter extends CustomPainter {
  _PaperPainter({required this.map, required this.castle, required this.spot, required this.player, required this.headColor, required this.heading});
  final MapData map;
  final LatLng castle, spot, player;
  final Color headColor;
  final double heading;

  static const _paper = Color(0xFFE9D8AE), _paperDark = Color(0xFFCDB682), _ink = Color(0xFF5B4326), _water = Color(0xFF9DB7B0), _red = Color(0xFFB3261E);

  /// The torn outline of the scrap.
  Path _outline(Size s) {
    final r = math.Random(7);
    final path = Path();
    const n = 44;
    for (var i = 0; i < n; i++) {
      final t = i / n;
      // Around the rectangle, with ragged edges and a bitten corner.
      final Offset p;
      final j = (r.nextDouble() - 0.5) * s.width * 0.035;
      if (t < 0.25) {
        p = Offset(s.width * (0.03 + 0.94 * t / 0.25), s.height * 0.035 + j);
      } else if (t < 0.5) {
        p = Offset(s.width * 0.965 + j, s.height * (0.03 + 0.94 * (t - 0.25) / 0.25));
      } else if (t < 0.75) {
        p = Offset(s.width * (0.97 - 0.94 * (t - 0.5) / 0.25), s.height * 0.965 + j);
      } else {
        p = Offset(s.width * 0.035 + j, s.height * (0.97 - 0.94 * (t - 0.75) / 0.25));
      }
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final outline = _outline(size);
    canvas.drawShadow(outline, Colors.black, 6, false);
    canvas.drawPath(outline, Paint()..color = _paper);
    canvas.save();
    canvas.clipPath(outline);
    // Aged paper: darker towards the edges, a few stains.
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = RadialGradient(colors: [_paper.withValues(alpha: 0), _paperDark.withValues(alpha: 0.75)], stops: const [0.55, 1], radius: 0.75).createShader(rect));
    final rnd = math.Random(3);
    for (var i = 0; i < 5; i++) {
      canvas.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height), size.width * (0.04 + rnd.nextDouble() * 0.07),
          Paint()..color = _paperDark.withValues(alpha: 0.22));
    }

    // The area: kTreasureMaxMeters around the sand castle, north up.
    final (cx, cy) = map.toWorld(castle.latitude, castle.longitude);
    const reach = kTreasureMaxMeters;
    final k = size.width / (reach * 2);
    Offset at(double wx, double wy) => Offset(size.width / 2 + (wx - cx) * k, size.height / 2 - (wy - cy) * k);
    Offset ll(LatLng p) {
      final (x, y) = map.toWorld(p.latitude, p.longitude);
      return at(x, y);
    }

    final ink = Paint()
      ..color = _ink.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final t in map.tiles.values) {
      if (t.maxX < cx - reach || t.minX > cx + reach || t.maxY < cy - reach || t.minY > cy + reach) continue;
      // Water, as a wash.
      final w = t.layers[GroundLayer.water];
      if (w != null && w.isNotEmpty) {
        final pts = <Offset>[];
        for (var i = 0; i + 5 < w.length; i += 6) {
          final ax = w[i], ay = w[i + 1], bx = w[i + 2], by = w[i + 3], dx = w[i + 4], dy = w[i + 5];
          if (math.max(ax, math.max(bx, dx)) < cx - reach || math.min(ax, math.min(bx, dx)) > cx + reach) continue;
          if (math.max(ay, math.max(by, dy)) < cy - reach || math.min(ay, math.min(by, dy)) > cy + reach) continue;
          pts
            ..add(at(ax, ay))
            ..add(at(bx, by))
            ..add(at(dx, dy));
        }
        if (pts.isNotEmpty) canvas.drawVertices(ui.Vertices(VertexMode.triangles, pts), BlendMode.srcOver, Paint()..color = _water.withValues(alpha: 0.8));
      }
      // Roads, as pen lines.
      for (final line in t.roads) {
        final path = Path();
        var any = false;
        for (var i = 0; i + 1 < line.length; i += 2) {
          final x = line[i], y = line[i + 1];
          final o = at(x, y);
          i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
          if ((x - cx).abs() < reach && (y - cy).abs() < reach) any = true;
        }
        if (any) canvas.drawPath(path, ink..strokeWidth = 1.1);
      }
    }

    // The sand castle the map came from.
    final c = ll(castle);
    final castlePaint = Paint()..color = _ink;
    canvas.drawRect(Rect.fromCenter(center: c.translate(0, 2), width: 12, height: 7), castlePaint);
    for (final dx in const [-5.0, 0.0, 5.0]) {
      canvas.drawRect(Rect.fromCenter(center: c.translate(dx, -3.5), width: 3, height: 4), castlePaint);
    }

    // X marks the spot.
    final x = ll(spot);
    final cross = Paint()
      ..color = _red
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(x.translate(-7, -7), x.translate(7, 7), cross);
    canvas.drawLine(x.translate(-7, 7), x.translate(7, -7), cross);
    // A dashed trail from the castle to the X.
    final v = x - c;
    final len = v.distance;
    if (len > 24) {
      final u = v / len;
      for (var s = 12.0; s < len - 14; s += 9) {
        canvas.drawLine(c + u * s, c + u * (s + 4), ink..strokeWidth = 1.4);
      }
    }

    // The player's head, where they are now (kept on the paper's edge if
    // they've walked off it).
    final raw = ll(player);
    final me = Offset(raw.dx.clamp(14.0, size.width - 14), raw.dy.clamp(14.0, size.height - 14));
    canvas.drawCircle(me, 8.5, Paint()..color = const Color(0xFF0E0E12));
    canvas.drawCircle(
        me,
        8.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..color = headColor);
    for (final sx in const [-3.0, 3.0]) {
      canvas.drawOval(Rect.fromCenter(center: me.translate(sx, -0.5), width: 2.4, height: 3.4), Paint()..color = headColor);
    }

    // A little compass rose.
    final n = Offset(size.width - 26, 28);
    canvas.drawLine(n.translate(0, 9), n.translate(0, -9), ink..strokeWidth = 1.4);
    canvas.drawLine(n.translate(-6, 0), n.translate(6, 0), ink..strokeWidth = 1.4);
    final tp = TextPainter(text: const TextSpan(text: 'N', style: TextStyle(color: _ink, fontSize: 10, fontWeight: FontWeight.w800)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, n.translate(-tp.width / 2, -22));
    canvas.restore();
    canvas.drawPath(
        outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _ink.withValues(alpha: 0.5));
  }

  @override
  bool shouldRepaint(_PaperPainter old) => old.player != player || old.spot != spot || old.heading != heading;
}
