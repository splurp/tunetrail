import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../data/samples.dart';
import '../app.dart';
import 'card_stage.dart';
import 'cards.dart';
import '../screens/report_dialogs.dart';

/// Round play / pause button for one card's song (Sample editions play
/// their sample breakdown).
class CardPlayButton extends StatelessWidget {
  const CardPlayButton({super.key, required this.card, this.size = 18});
  final CardPayload card;
  final double size;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final sample = card.edition == Edition.sample ? SampleLibrary.of(card.songId) : null;
    return ListenableBuilder(
      listenable: Listenable.merge([g.audio, g.samples]),
      builder: (context, _) {
        final playing = sample != null
            ? g.samples.value.songId == card.songId && g.samples.value.active
            : g.audio.playing && g.audio.current?.id == card.songId;
        return Material(
          color: Colors.black.withValues(alpha: 0.65),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              if (playing) {
                sample != null ? g.samples.stop() : g.audio.stop();
              } else if (sample != null) {
                g.samples.play(sample);
              } else {
                g.catalog.ensureFromPayload(card);
                g.audio.playOne(card.songId);
              }
            },
            child: Padding(
              padding: EdgeInsets.all(size * 0.35),
              child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: size, color: Colors.white),
            ),
          ),
        );
      },
    );
  }
}

/// A card shown big on the card design's dotted backdrop, with the
/// Spotify / info / Apple Music buttons under it; close, play and report
/// along the top ([actions]: buttons under it, such as making an offer).
Future<void> showCardFullView(BuildContext context, CardPayload card, {Widget Function(BuildContext ctx)? actions}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: child),
    pageBuilder: (ctx, _, _) => Scaffold(
      backgroundColor: Colors.transparent,
      body: DottedBackdrop(
        child: SafeArea(
          child: LayoutBuilder(builder: (ctx, box) {
            // The card and its buttons fill the height left by the top bar
            // (and any actions), never wider than the screen allows.
            final room = box.maxHeight - 64 - (actions != null ? 64 : 0);
            final w = math.min(box.maxWidth * 0.78, math.min(460.0, room / (kCardAspect + 0.25)));
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(children: [
                  IconButton(tooltip: 'Close', icon: const Icon(Icons.close, color: Colors.white70), onPressed: () => Navigator.pop(ctx)),
                  const Spacer(),
                  CardPlayButton(card: card, size: 24),
                  const SizedBox(width: 8),
                  IconButton(tooltip: 'Report this song', icon: const Icon(Icons.flag_outlined, color: Colors.white54), onPressed: () => showSongReport(ctx, card)),
                ]),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CardStage(card: card, width: w),
                      if (actions != null) ...[const SizedBox(height: 18), actions(ctx)],
                    ]),
                  ),
                ),
              ),
            ]);
          }),
        ),
      ),
    ),
  ));
}

/// A showcase: big cards (videos for Canvas/Live editions) in one
/// horizontally scrolling row. Tap a card for the full view; the round
/// button plays it.
class ShowcaseStrip extends StatelessWidget {
  const ShowcaseStrip({super.key, required this.cards, this.cardWidth = 170, this.live = true});
  final List<CardPayload> cards;
  final double cardWidth;

  /// Play Canvas/Live videos (off for long lists of showcases).
  final bool live;

  @override
  Widget build(BuildContext context) {
    final h = cardWidth * kCardAspect;
    return SizedBox(
      height: h + 8,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final c = cards[i];
          return SizedBox(
            width: cardWidth,
            height: h,
            child: Stack(children: [
              GestureDetector(
                onTap: () => showCardFullView(context, c),
                child: SongCardView(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny, edition: c.edition, serial: c.serial, width: cardWidth, live: live),
              ),
              Positioned(right: 6, bottom: 6, child: CardPlayButton(card: c)),
            ]),
          );
        },
      ),
    );
  }
}
