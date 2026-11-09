import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/collection.dart';
import '../../data/samples.dart';
import '../../game/audio_service.dart';
import '../../game/game.dart';
import '../../game/spawns.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'card_detail_screen.dart';
import 'listing_composer.dart';

enum _Hit { perfect, great, good, miss }

/// Catch minigame: tap when the shrinking beat ring lines up with the
/// target ring. Rarer songs pulse faster and are harder to catch.
class EncounterScreen extends StatefulWidget {
  const EncounterScreen({super.key, required this.spawn});
  final Spawn spawn;
  @override
  State<EncounterScreen> createState() => _EncounterScreenState();
}

class _EncounterScreenState extends State<EncounterScreen> with TickerProviderStateMixin {
  late final AnimationController _ring;
  late final AnimationController _fx = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
  final _rand = math.Random();
  int _attempts = 0;
  String? _feedback;
  Color _feedbackColor = Colors.white;
  bool _caught = false;
  bool _fled = false;
  OwnedCard? _card;

  /// Coins credited when the caught variant was already owned.
  int _dupCoins = 0;
  String? _catchNote;
  bool _busy = false;
  bool _playing = false;
  bool _perfect = false;
  int? _accuracy;

  /// Precise beat clock: taps are judged against real elapsed time rather
  /// than the last rendered frame, so the 100% window can be very tight.
  /// In synced mode the clock is locked to the song's playback position.
  final Stopwatch _beat = Stopwatch();
  Game? _game;
  int _periodUs = 1;

  /// Waiting for the music to start (the ring appears once it does).
  bool _waiting = true;
  bool _synced = false;
  double? _bpm;

  /// Song seconds = stopwatch seconds + [_clockOffset] (synced mode).
  double _clockOffset = 0;

  /// Song time (seconds) at which the ring is at the outer edge.
  double _ringZero = 0;
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));

  static const _baseCatch = [0.92, 0.78, 0.62, 0.48, 0.34];
  static const _fleeChance = [0.02, 0.03, 0.05, 0.07, 0.1];

  /// Catch chance for a throw with [acc]% timing: 90%+ always catches,
  /// 50–89% climbs from the rarity's base chance towards certain, and an
  /// off-beat throw keeps a small chance.
  static double catchChance(Rarity r, int acc) {
    final base = _baseCatch[r.index];
    if (acc >= 90) return 1;
    if (acc >= 50) return (base + (1 - base) * 0.75 * (acc - 50) / 40).clamp(0.0, 1.0);
    return base * 0.3;
  }
  static const _maxAttempts = 5;

  Rarity get r => widget.spawn.rarity;

  /// A Canvas spawn stays a Canvas even without a music video — its
  /// canvas falls back to the cover art.
  Edition get _edition => widget.spawn.edition;

  bool get _alreadyOwned => _game?.collection.ownsVariant(widget.spawn.song.id, r, widget.spawn.shiny, _edition) ?? false;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(vsync: this, duration: const Duration(seconds: 1))..addListener(_tick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final g = GameScope.read(context);
      _game = g;
      final sample = widget.spawn.edition == Edition.sample ? SampleLibrary.of(widget.spawn.song.id) : null;
      if (g.profile.playOnEncounter && sample != null) {
        _playing = true;
        _startWithSample(g, sample);
      } else if (g.profile.playOnEncounter) {
        _playing = true;
        _startSynced(g);
      } else {
        _startUnsynced();
      }
    });
  }

  /// Plays the song, works out its beat grid and starts the ring on the
  /// beat once the music is audible. Falls back to a free-running ring if
  /// that hasn't happened within 5 seconds.
  Future<void> _startSynced(Game g) async {
    final id = widget.spawn.song.id;
    final req = ++_startReq;
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (mounted && _waiting && req == _startReq) _startUnsynced();
    });
    final beatsF = g.audio.beatInfo(id).catchError((Object _) => null);
    await g.audio.playOne(id);
    _pos = () async => g.audio.exactPosition;
    await _syncTo(g, beatsF, req, const Duration(seconds: 4));
  }

  /// Sample editions: the breakdown plays (and animates on the card) while
  /// the ring waits; the minigame starts on the beat once the song itself
  /// comes in. "Skip" jumps straight to the song.
  Future<void> _startWithSample(Game g, SampleInfo info) async {
    final req = ++_startReq;
    setState(() => _inBreakdown = true);
    final beatsF = g.audio.beatInfo(info.song.id).catchError((Object _) => null);
    unawaited(g.samples.play(info));
    _pos = g.samples.songPosition;
    // Fallback if the previews never load.
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (mounted && _waiting && req == _startReq && (g.samples.value.error != null || g.samples.elapsed == null)) _skipBreakdown();
    });
    await _syncTo(g, beatsF, req, Duration(milliseconds: ((info.length + 10) * 1000).round()));
  }

  void _skipBreakdown() {
    final g = _game;
    if (g == null || !_waiting) return;
    g.samples.stop();
    setState(() => _inBreakdown = false);
    _startSynced(g);
  }

  int _startReq = 0;
  bool _inBreakdown = false;
  Future<double?> Function() _pos = () async => null;

  /// Seconds of output latency between the engine's reported position and
  /// what's actually heard (plus the player's calibration from Settings).
  double get _latency => 0.045 + (_game?.profile.beatOffsetMs ?? 0) / 1000;

  /// Waits for the song to be audibly playing, then locks the ring to its
  /// beat grid so the ring meets the target on every beat.
  Future<void> _syncTo(Game g, Future<BeatInfo?> beatsF, int req, Duration timeout) async {
    final beats = await beatsF;
    if (!mounted || !_waiting || beats == null || req != _startReq) return;
    final until = DateTime.now().add(timeout);
    while (mounted && _waiting && req == _startReq && DateTime.now().isBefore(until)) {
      final p = await _pos();
      if (p != null && p > 0.02) {
        _inBreakdown = false;
        var period = beats.period;
        // Very fast songs: one ring per two beats keeps it playable.
        while (period < 0.42) {
          period *= 2;
        }
        _beat
          ..reset()
          ..start();
        _clockOffset = p - _latency;
        _beatPeriod = beats.period;
        _beatPhase = beats.phase;
        _periodUs = (period * 1e6).round();
        // Ring reaches the target exactly on a beat.
        _ringZero = beats.phase; // ring cycles end exactly on beats
        setState(() {
          _waiting = false;
          _synced = true;
          _bpm = beats.bpm;
        });
        _ring.repeat();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  void _startUnsynced() {
    final ms = [1700, 1500, 1300, 1100, 900][r.index];
    _periodUs = ms * 1000;
    _clockOffset = 0;
    _ringZero = 0;
    _beat
      ..reset()
      ..start();
    setState(() {
      _waiting = false;
      _synced = false;
    });
    _ring.repeat();
  }

  /// Keeps the beat clock locked to the audio clock (which only advances in
  /// buffer-sized steps, so it is smoothed rather than read directly).
  void _tick() {
    if (!_synced || _ticking) return;
    _ticking = true;
    _pos().then((raw) {
      _ticking = false;
      if (raw == null || !_synced) return; // clip ended: keep extrapolating
      final p = raw - _latency;
      final err = p - (_beat.elapsedMicroseconds / 1e6 + _clockOffset);
      if (err.abs() > 0.08) {
        _clockOffset += err; // seek / stall: snap
      } else {
        _clockOffset += err * 0.04;
      }
    });
  }

  bool _ticking = false;
  double _beatPeriod = 0, _beatPhase = 0;

  /// 1 right on a heard beat, decaying to 0 — drives the beat pulse.
  double get _beatPulse {
    if (!_synced || _beatPeriod <= 0) return 0;
    final t = _beat.elapsedMicroseconds / 1e6 + _clockOffset - _beatPhase;
    final u = (t % _beatPeriod) / _beatPeriod;
    return math.pow(1 - u, 6).toDouble();
  }

  @override
  void dispose() {
    // However the screen is dismissed (close button, back gesture…), make
    // sure a preview that's still loading or playing doesn't outlive it.
    final g = _game;
    if (g != null && _playing && (!_caught || !g.profile.keepPlayingAfterCatch)) {
      g.audio.stop();
      g.samples.stop();
    }
    _ring.dispose();
    _fx.dispose();
    _spin.dispose();
    super.dispose();
  }

  /// Target ring sits at 0.72 of the outer radius (just outside the card so
  /// it is always visible).
  static const _target = 0.72;

  /// Timing accuracy for a tap, 0–100. Exactly 100 only when the ring is
  /// dead-on the target — within ±0.25% of a beat (≈ ±2–4 ms) — so perfect
  /// (shiny) catches are rare. Everything else tops out at 99.
  static const perfectWindow = 0.0025;
  static int accuracyFor(double diff) {
    if (diff <= perfectWindow) return 100;
    return (99 * (1 - (diff - perfectWindow) / 0.29)).floor().clamp(0, 99);
  }

  /// Progress through the current ring cycle (0 just after a beat, → 1 at
  /// the next beat).
  double get _cycleNow {
    final t = _beat.elapsedMicroseconds / 1e6 + _clockOffset - _ringZero;
    final period = _periodUs / 1e6;
    return (t % period) / period;
  }

  /// Each ring starts at the outer edge right after a beat and lands on the
  /// target exactly on the next beat.
  double get _ringFracNow => _target + (1 - _target) * (1 - _cycleNow);

  void _tap() {
    if (_busy || _caught || _fled || _waiting) return;
    // Timing error as a fraction of a beat (to the nearest beat).
    final u = _cycleNow;
    final diff = math.min(u, 1 - u);
    final acc = accuracyFor(diff);
    final hit = acc == 100
        ? _Hit.perfect
        : acc >= 80
        ? _Hit.great
        : acc >= 50
        ? _Hit.good
        : _Hit.miss;
    HapticFeedback.mediumImpact();
    _attempts++;
    // A 100% perfect beat always catches — and turns the song shiny.
    final success = hit == _Hit.perfect || _rand.nextDouble() < catchChance(r, acc);
    setState(() {
      _accuracy = acc;
      _perfect = hit == _Hit.perfect;
      _feedback = switch (hit) {
        _Hit.perfect => '100% · PERFECT! It turned shiny!',
        _Hit.great => '$acc% · Great',
        _Hit.good => '$acc% · Good',
        _Hit.miss => '$acc% · Off beat',
      };
      _feedbackColor = switch (hit) {
        _Hit.perfect => kAccent,
        _Hit.great => const Color(0xFFE6E6EB),
        _Hit.good => Colors.white70,
        _Hit.miss => const Color(0xFFE5737A),
      };
      _busy = true;
    });
    Future<void>.delayed(Duration(milliseconds: hit == _Hit.perfect ? 900 : 650), () async {
      if (!mounted) return;
      final g = GameScope.read(context);
      if (success) {
        _card = await g.catchSpawn(widget.spawn, perfect: _perfect);
        if (!mounted) return;
        _dupCoins = _card == null ? g.lastDuplicateCoins : 0;
        _catchNote = g.lastCatchNote;
        if (!g.profile.keepPlayingAfterCatch && _playing) g.audio.stop();
        HapticFeedback.heavyImpact();
        _fx.forward(from: 0);
        _spin.forward(from: 0);
        setState(() {
          _caught = true;
          _busy = false;
        });
      } else if (_attempts >= _maxAttempts || _rand.nextDouble() < _fleeChance[r.index]) {
        g.fleeSpawn(widget.spawn);
        setState(() {
          _fled = true;
          _busy = false;
        });
      } else {
        setState(() {
          _feedback = hit == _Hit.miss ? '$acc% · Missed — try again' : '$acc% · It slipped away! Try again';
          _busy = false;
        });
      }
    });
  }

  /// Catch animation: a fast spin while pumping towards the viewer, then a
  /// slow settle back to the head-on view.
  static Matrix4 _spinMatrix(double t) {
    if (t <= 0 || t >= 1) return Matrix4.identity();
    const spinEnd = 0.32;
    double angle, scale;
    if (t < spinEnd) {
      final u = Curves.easeInOutCubic.transform(t / spinEnd);
      angle = u * math.pi * 2;
      scale = 1 + 0.45 * math.sin(u * math.pi * 0.5);
    } else {
      final u = Curves.easeOutCubic.transform((t - spinEnd) / (1 - spinEnd));
      angle = math.sin(u * math.pi * 2) * 0.12 * (1 - u);
      scale = 1 + 0.45 * (1 - u);
    }
    return Matrix4.identity()
      ..setEntry(3, 2, 0.0014)
      ..scaleByDouble(scale, scale, scale, 1)
      ..rotateY(angle);
  }

  Future<void> _quicksell() async {
    final card = _card, g = _game;
    if (card == null || g == null) return;
    final value = g.scrapValueOf(card);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quicksell?'),
        content: Text('Send ${card.song.title} to the scrapyard for $value coins.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quicksell')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final coins = g.scrap([card.uid]);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scrapped for $coins coins')));
    Navigator.of(context).pop();
  }

  void _close() {
    final g = GameScope.read(context);
    if (_playing && !_caught) g.audio.stop();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spawn;
    final c = rarityColor(r);
    final size = MediaQuery.sizeOf(context);
    // Scale with the window: small on phones, much larger on PC screens.
    final cardW = math.min(size.width * 0.5, (size.height - 300) / 1.55).clamp(190.0, 440.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.88),
      body: Container(
        decoration: BoxDecoration(gradient: RadialGradient(colors: [c.withValues(alpha: 0.35), Colors.transparent], radius: 0.9)),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(icon: const Icon(Icons.close), onPressed: _close),
                  const Spacer(),
                  if (!_caught && !_fled)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text('Attempts ${_maxAttempts - _attempts}', style: const TextStyle(color: Colors.white70)),
                    ),
                ],
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _tap(),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedScale(
                        scale: _fled ? 0.2 : (_caught ? 1.05 : 0.82),
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOutBack,
                        child: AnimatedOpacity(
                          opacity: _fled ? 0 : 1,
                          duration: const Duration(milliseconds: 600),
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_spin, _ring]),
                            // The card thumps gently on every beat while catching.
                            builder: (context, child) => Transform(
                              alignment: Alignment.center,
                              transform: _spinMatrix(_spin.value)..scaleByDouble(1 + (_caught ? 0 : 0.035 * _beatPulse), 1 + (_caught ? 0 : 0.035 * _beatPulse), 1, 1),
                              child: child,
                            ),
                            child: SongCardView(song: s.song, rarity: s.rarity, shiny: s.shiny || _perfect, edition: _edition, width: cardW),
                          ),
                        ),
                      ),
                      if (!_caught && !_fled && !_waiting)
                        IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _ring,
                            builder: (context, _) => CustomPaint(
                              size: Size.square(math.min(size.width, size.height * 0.6) * 1.05),
                              painter: _BeatRingPainter(_ringFracNow, _target, c, _cycleNow),
                            ),
                          ),
                        ),
                      if (_caught)
                        IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _fx,
                            builder: (context, _) => CustomPaint(size: size, painter: _ConfettiPainter(_fx.value, c)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: _caught
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.shiny || _perfect ? (_perfect ? '✦ PERFECT SHINY CATCH ✦' : '✦ SHINY CATCH ✦') : 'Caught',
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: c),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${_accuracy == null ? '' : '$_accuracy% timing  ·  '}+${s.rarity.catchCoins * (s.shiny || _perfect ? 3 : 1)} coins  ·  +${s.rarity.catchXp * (s.shiny || _perfect ? 3 : 1)} XP',
                            style: const TextStyle(color: kTextSecondary, fontWeight: FontWeight.w500),
                          ),
                          if (_catchNote != null) ...[
                            const SizedBox(height: 6),
                            Text(_catchNote!, textAlign: TextAlign.center, style: const TextStyle(color: kTextSecondary, fontSize: 13)),
                          ],
                          if (_dupCoins > 0) ...[

                            const SizedBox(height: 6),
                            Text(
                              'You already own this variant — sent to the scrapyard for $_dupCoins coins',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: kTextSecondary, fontSize: 13),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              if (_card != null)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.sell_outlined, size: 18),
                                  label: const Text('List for sale'),
                                  onPressed: _card == null
                                      ? null
                                      : () async {
                                          final listed = await showQuickListSheet(context, _card!.uid);
                                          if (listed && context.mounted) Navigator.of(context).pop();
                                        },
                                ),
                              if (_card != null && _card!.edition == Edition.standard && !_card!.shiny)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.recycling, size: 18),
                                  label: Text(_card == null ? 'Quicksell' : 'Quicksell · ${_game?.scrapValueOf(_card!) ?? 0}c'),
                                  onPressed: _card == null ? null : _quicksell,
                                ),
                              if (_card != null)
                                OutlinedButton(
                                  onPressed: () {
                                    final card = _card;
                                    Navigator.of(context).pop();
                                    if (card != null) {
                                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: card.uid)));
                                    }
                                  },
                                  child: const Text('View card'),
                                ),
                              const SizedBox(width: 12),
                              FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back to map')),
                            ],
                          ),
                        ],
                      )
                    : _fled
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('The song faded away…', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _close, child: const Text('Back to map')),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            child: Text(
                              _waiting
                                  ? (_inBreakdown ? 'Listen to the sample…' : 'Waiting for the music…')
                                  : (_feedback ?? 'Tap on the beat as the ring lands!'),
                              key: ValueKey('$_feedback$_attempts'),
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _feedback == null ? Colors.white : _feedbackColor),
                            ),
                          ),
                          if (_waiting && _inBreakdown)
                            TextButton.icon(onPressed: _skipBreakdown, icon: const Icon(Icons.skip_next), label: const Text('Skip to the song')),
                          const SizedBox(height: 6),
                          Text(
                            '${_synced ? '${_bpm!.round()} BPM · ' : (_waiting ? '' : 'Not synced · ')}Base catch ${(_baseCatch[r.index] * 100).round()}% · 90%+ timing always catches · a flawless 100% beat makes it shiny${_alreadyOwned ? '\nYou already own this variant — a catch is auto-scrapped unless it turns shiny' : ''}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BeatRingPainter extends CustomPainter {
  _BeatRingPainter(this.frac, this.target, this.color, this.cycle);
  final double frac;
  final double target;
  final Color color;

  /// 0 right after a beat → 1 at the next beat.
  final double cycle;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.width / 2;
    // The target flashes on every beat (when the ring lands on it).
    final flash = math.pow(1 - cycle, 8).toDouble();
    final targetPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10 + flash * 8
      ..color = color.withValues(alpha: 0.35 + flash * 0.55)
      ..maskFilter = MaskFilter.blur(BlurStyle.solid, 1 + flash * 10);
    canvas.drawCircle(c, maxR * target, targetPaint);
    // The ring that just landed bursts outward as it fades.
    if (cycle < 0.25) {
      final k = cycle / 0.25;
      canvas.drawCircle(
          c,
          maxR * target * (1 + k * 0.12),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4 * (1 - k)
            ..color = Colors.white.withValues(alpha: 0.8 * (1 - k)));
    }
    canvas.drawCircle(
      c,
      maxR * target,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white70,
    );
    final near = 1 - ((frac - target).abs() / 0.3).clamp(0.0, 1.0);
    canvas.drawCircle(
      c,
      maxR * frac,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 + near * 6
        // Fade the new ring in from the edge so the jump back isn't a "hit".
        ..color = Color.lerp(Colors.white, color, near)!.withValues(alpha: (cycle / 0.15).clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, 2 + near * 8),
    );
  }

  @override
  bool shouldRepaint(_BeatRingPainter old) => old.frac != frac || old.cycle != cycle;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t, this.color);
  final double t;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final r = math.Random(3);
    final c = size.center(Offset.zero);
    final colors = [color, Colors.white, Colors.white70, kAccent, const Color(0xFFD9D9E0)];
    for (var i = 0; i < 90; i++) {
      final a = r.nextDouble() * math.pi * 2;
      final v = 200 + r.nextDouble() * 350;
      final d = v * Curves.easeOut.transform(t);
      final p = c + Offset(math.cos(a) * d, math.sin(a) * d + t * t * 250);
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(t * 10 + i);
      canvas.drawRect(const Rect.fromLTWH(-4, -2, 8, 4), Paint()..color = colors[i % colors.length].withValues(alpha: 1 - t));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
