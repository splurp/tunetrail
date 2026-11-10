import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../data/samples.dart';
import '../app.dart';
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

/// A card shown big, with its own play button ([actions]: buttons under
/// it, such as making an offer).
Future<void> showCardFullView(BuildContext context, CardPayload card, {Widget Function(BuildContext ctx)? actions}) {
  final size = MediaQuery.sizeOf(context);
  final w = math.min(size.width * 0.82, math.min(420.0, (size.height - 160) / 1.5));
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.8),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SongCardView(song: Song.fromPayload(card), rarity: card.rarity, shiny: card.shiny, edition: card.edition, serial: card.serial, width: w),
        const SizedBox(height: 16),
        Row(mainAxisSize: MainAxisSize.min, children: [
          CardPlayButton(card: card, size: 30),
          const SizedBox(width: 16),
          Material(
            color: Colors.white.withValues(alpha: 0.12),
            shape: const CircleBorder(),
            child: IconButton(tooltip: 'Report this song', icon: const Icon(Icons.flag_outlined, color: Colors.white), onPressed: () => showSongReport(ctx, card)),
          ),
          const SizedBox(width: 16),
          Material(
            color: Colors.white.withValues(alpha: 0.12),
            shape: const CircleBorder(),
            child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(ctx)),
          ),
        ]),
        if (actions != null) ...[const SizedBox(height: 14), actions(ctx)],
      ]),
    ),
  );
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
    final h = cardWidth * 1.5;
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
