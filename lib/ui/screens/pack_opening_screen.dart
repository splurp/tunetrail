import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/audio_service.dart';
import '../../game/game.dart';
import '../app.dart';
import '../../game/store_catalog.dart';
import '../widgets/cards.dart';

/// Tap each face-down card to flip it and reveal the song.
class PackOpeningScreen extends StatefulWidget {
  const PackOpeningScreen({super.key, required this.pack, required this.cards});
  final PackDef pack;
  final List<PackPull> cards;
  @override
  State<PackOpeningScreen> createState() => _PackOpeningScreenState();
}

class _PackOpeningScreenState extends State<PackOpeningScreen> with TickerProviderStateMixin {
  late final List<AnimationController> _flip = [for (final _ in widget.cards) AnimationController(vsync: this, duration: const Duration(milliseconds: 650))];

  @override
  void dispose() {
    for (final c in _flip) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _allRevealed => _flip.every((c) => c.value == 1);

  /// Flips card [i] with a soft card sound.
  Future<void> _reveal(int i) {
    if (_flip[i].value > 0 || _flip[i].isAnimating) return Future.value();
    GameScope.read(context).audio.playSfx(Sfx.cardFlip);
    return _flip[i].forward();
  }

  Future<void> _revealAll() async {
    for (final c in _flip) {
      if (c.value < 1) {
        _reveal(_flip.indexOf(c));
        await Future<void>.delayed(const Duration(milliseconds: 220));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final h = MediaQuery.sizeOf(context).height;
    final single = widget.cards.length == 1;
    // A single pull (e.g. the Artist Blind Box) gets a big, centred card.
    final cardW = single
        ? math.max(120.0, math.min(360.0, math.min(w - 64, (h - 260) / 1.5)))
        : math.min(w > 900 ? 260.0 : 170.0, math.min((w - 48) / (widget.cards.length > 3 ? (w > 900 ? 5.4 : 2.2) : 2), (h - 220) / (w > 900 ? 1.6 : 3.2)));
    final best = widget.cards.map((c) => c.card.rarity.index).reduce(math.max);
    // No back button: the songs are already in the collection, and leaving
    // early made it look like the pack had been lost. "Add to collection"
    // (after revealing) is the way out.
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.pack.name), automaticallyImplyLeading: false),
        body: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(colors: [rarityColor(Rarity.fromIndex(best)).withValues(alpha: 0.25), Colors.transparent], radius: 1.1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(16, single ? 24 : 16, 16, 16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < widget.cards.length; i++)
                        GestureDetector(
                          onTap: () => _reveal(i).then((_) => setState(() {})),
                          child: AnimatedBuilder(
                            animation: _flip[i],
                            builder: (context, _) {
                              final v = Curves.easeInOut.transform(_flip[i].value);
                              final showFront = v >= 0.5;
                              final angle = v * math.pi;
                              final pull = widget.cards[i];
                              final c = pull.card;
                              return Transform(
                                alignment: Alignment.center,
                                transform: Matrix4.identity()
                                  ..setEntry(3, 2, 0.0015)
                                  ..rotateY(angle),
                                child: showFront
                                    ? Transform(
                                        alignment: Alignment.center,
                                        transform: Matrix4.identity()..rotateY(math.pi),
                                        child: Stack(
                                          children: [
                                            SongCardView(song: c.song, rarity: c.rarity, shiny: c.shiny, edition: c.edition, serial: c.serial, width: cardW),
                                            if (pull.duplicate)
                                              Positioned.fill(
                                                child: Container(
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(cardW * 0.07)),
                                                  child: Text(
                                                    'Already owned\nScrapped +${pull.duplicateCoins}',
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      )
                                    : _Back(width: cardW, color: widget.pack.color),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Clear of the system navigation bar.
              SafeArea(
                top: false,
                minimum: const EdgeInsets.all(16),
                child: _allRevealed
                    ? FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Add to collection'))
                    : OutlinedButton(
                        onPressed: () =>
                            _revealAll().then((_) => Future<void>.delayed(const Duration(milliseconds: 700), () => mounted ? setState(() {}) : null)),
                        child: const Text('Reveal all'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Back extends StatelessWidget {
  const _Back({required this.width, required this.color});
  final double width;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width * 1.48,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(width * 0.07),
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, kSurface]),
      border: Border.all(color: Colors.white24, width: 2),
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 12)],
    ),
    child: Center(
      child: Icon(Icons.graphic_eq, size: width * 0.35, color: Colors.white70),
    ),
  );
}
