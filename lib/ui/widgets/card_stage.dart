import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../screens/artist_screen.dart';
import '../screens/market_screen.dart';
import 'cards.dart';
import 'store_links.dart';

/// The card design's backdrop for a card on its own (market, collection,
/// someone's showcase): dark grey with a staggered grid of soft dots.
class DottedBackdrop extends StatelessWidget {
  const DottedBackdrop({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _Dots(), child: child ?? const SizedBox.expand());
}

class _Dots extends CustomPainter {
  // From the design: 56 px rows, 112 px apart in a row (alternate rows
  // offset by half), 28 px dots, on a 1440 px wide screen.
  static const _row = 16.0, _col = 32.0, _r = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF202020));
    final dot = Paint()..color = const Color(0xFF333333);
    var i = 0;
    for (var y = _row / 2; y < size.height + _r; y += _row, i++) {
      for (var x = (i.isOdd ? _col / 2 : 0.0) + _col / 4; x < size.width + _r; x += _col) {
        canvas.drawCircle(Offset(x, y), _r, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_Dots old) => false;
}

/// A card with the design's buttons under it: Spotify, the (i) info menu
/// (Canvas, Sample and Live editions only) and Apple Music.
class CardStage extends StatelessWidget {
  const CardStage({super.key, required this.card, required this.width, this.live = true});
  final CardPayload card;
  final double width;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final w = width;
    final song = Song.fromPayload(card);
    // Buttons: 155 px on the 1122 px card, centres 212 px apart, 124 px below it.
    final icon = w * 0.138;
    final gap = w * 0.189 - icon;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SongCardView(song: song, rarity: card.rarity, shiny: card.shiny, edition: card.edition, serial: card.serial, width: w, live: live),
      SizedBox(height: w * 0.11),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _ImageButton(
          asset: 'assets/brand/spotify.png',
          size: icon,
          tooltip: 'Listen on Spotify',
          onTap: () => StoreLinks.open(Future.value(StoreLinks.spotifyUrl(song))),
        ),
        if (card.edition != Edition.standard) ...[
          SizedBox(width: gap),
          _InfoButton(size: icon, onTap: () => showCardInfo(context, card)),
        ],
        SizedBox(width: gap),
        _ImageButton(
          asset: 'assets/brand/apple.png',
          size: icon,
          tooltip: 'Listen on Apple Music',
          onTap: () => StoreLinks.open(StoreLinks.appleMusicUrl(song)),
        ),
      ]),
    ]);
  }
}

class _ImageButton extends StatelessWidget {
  const _ImageButton({required this.asset, required this.size, required this.tooltip, required this.onTap});
  final String asset;
  final double size;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox.square(dimension: size, child: Image.asset(asset, fit: BoxFit.contain, filterQuality: FilterQuality.medium)),
          ),
        ),
      );
}

/// The design's (i): a grey ring with a bold "i".
class _InfoButton extends StatelessWidget {
  const _InfoButton({required this.size, required this.onTap});
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A 144 px ring with a 20 px stroke, beside 155 px logos.
    final d = size * 144 / 155;
    return Tooltip(
      message: 'Card info',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: Container(
                width: d,
                height: d,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8D8D8D), width: d * 20 / 144)),
                child: Text('i',
                    style: TextStyle(fontFamily: kCardFont, fontWeight: FontWeight.w700, fontSize: d * 0.66, height: 1.0, color: const Color(0xFF7E7E7E))),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The info menu for a Canvas / Sample / Live card: when it was collected,
/// who pulled it, and links to the artist's discography and market.
Future<void> showCardInfo(BuildContext context, CardPayload card) {
  final g = GameScope.read(context);
  final pulled = card.serial > 0 ? g.market.pullerOf(card.songId, card.edition, card.serial).catchError((Object _) => null) : Future<Map<String, dynamic>?>.value(null);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    showDragHandle: true,
    builder: (ctx) {
      final loc = MaterialLocalizations.of(ctx);
      String date(int ms) => ms > 0 ? loc.formatCompactDate(DateTime.fromMillisecondsSinceEpoch(ms)) : 'Unknown';
      const label = TextStyle(fontFamily: kCardFont, fontWeight: FontWeight.w600, fontSize: 15, color: Color(0xFF8D8D8D));
      const value = TextStyle(fontFamily: kCardFont, fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white);
      Widget line(String k, String v) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text.rich(TextSpan(children: [TextSpan(text: '$k: ', style: label), TextSpan(text: v, style: value)])),
          );
      Widget link(String text, VoidCallback onTap) => InkWell(
            onTap: () {
              Navigator.pop(ctx);
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Expanded(child: Text(text, style: value)),
                const Icon(Icons.chevron_right, color: Color(0xFF8D8D8D)),
              ]),
            ),
          );
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, math.max(16.0, MediaQuery.paddingOf(ctx).bottom)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            line('Date collected', date(card.acquiredAt)),
            FutureBuilder<Map<String, dynamic>?>(
              future: pulled,
              builder: (context, snap) {
                final by = snap.data?['by'] as String?;
                final v = snap.connectionState != ConnectionState.done ? '…' : (by == null || by.isEmpty ? 'Unknown' : '@$by');
                return line('Pulled by', v);
              },
            ),
            const SizedBox(height: 14),
            link('View artist discography', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: card.artistId, name: card.artistName)))),
            link('View this artist\'s market', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistMarketScreen(artistName: card.artistName)))),
          ]),
        ),
      );
    },
  );
}
