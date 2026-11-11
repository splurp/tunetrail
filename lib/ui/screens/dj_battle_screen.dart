import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../game/audio_service.dart';
import '../../game/game.dart';
import '../../map3d/camera.dart';
import '../../map3d/figure3d.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/edition_views.dart' show editionColor;
import '../widgets/net_image.dart';
import '../widgets/showcase_strip.dart';
import '../widgets/stick_figure.dart';
import 'encounter_screen.dart' show EncounterScreen;

/// An accuracy number that pops out of the DJ (or the player), drifts
/// sideways, then rises and fades.
class _Pop {
  _Pop(this.text, this.born, this.side, this.color, {this.fromDj = true});
  final String text;
  final double born;
  final double side;
  final Color color;
  final bool fromDj;
}

/// A DJ battle: the DJ scratches a turntable on every beat of its song
/// with 90–100% accuracy; the players tap the ring on the beat, and after
/// thirty seconds the team's combined accuracy has to beat the DJ's.
class DjBattleScreen extends StatefulWidget {
  const DjBattleScreen({super.key, required this.battle});

  /// The battle as the server returned it (challenge or join).
  final Map<String, dynamic> battle;

  @override
  State<DjBattleScreen> createState() => _DjBattleScreenState();
}

class _DjBattleScreenState extends State<DjBattleScreen> with SingleTickerProviderStateMixin {
  late final DjNpc dj = DjNpc.fromJson(widget.battle['dj'] as Map<String, dynamic>);
  late final String id = widget.battle['id'] as String;
  late final int startAt = (widget.battle['startAt'] as num).toInt(), endAt = (widget.battle['endAt'] as num).toInt();
  late final Song song = Song.fromInfo(dj.song);

  late final Ticker _ticker;
  final ValueNotifier<double> _time = ValueNotifier(0);
  final IdleDirector _idle = IdleDirector(7, false);
  final Stopwatch _beat = Stopwatch();
  Game? _g;

  // Beat clock (as in the catch minigame): song seconds = stopwatch +
  // offset; rings land on the target on every beat.
  bool _synced = false, _ringOn = false, _ticking = false;
  double _clockOffset = 0, _period = 0.6, _phase = 0;

  // Scoring: the best tap of each beat while the battle is live; beats
  // let go by count as zero.
  final Map<int, int> _taps = {};
  int? _firstBeat, _lastBeat;
  int _lastSeenBeat = -1 << 30;
  double _djSum = 0;
  int _djBeats = 0;
  final List<_Pop> _pops = [];

  String _phaseName = 'intro'; // intro → live → scoring → done
  Map<String, dynamic> _state = const {};
  String? _error;
  int _players = 1;
  Timer? _poll;

  /// Everyone's running accuracy while the battle is on (from the server;
  /// this player's own is always the one worked out here).
  Map<String, double> _live = {};
  Timer? _livePoll;

  static const _blue = Color(0xFF3D7BFF), _red = Color(0xFFFF4D5E);

  /// The team's accuracy so far, with the bonus for extra players already
  /// applied (+50% for a second player, +25% for a third…).
  double get _teamAccuracy {
    final me = _g?.profile.playerId;
    final values = <double>[
      for (final e in _live.entries)
        if (e.key != me) e.value,
      _myAccuracy,
    ];
    return teamAccuracy(values);
  }

  double get _djAverage => _djBeats == 0 ? dj.accuracy : _djSum / _djBeats;

  /// Sends this player's running accuracy every two seconds and picks up
  /// everyone else's.
  void _startLiveScores() {
    _livePoll ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      final g = _g;
      if (g == null || _phaseName != 'live' || _left) return;
      try {
        final b = await g.world.liveScore(id, _myAccuracy);
        if (!mounted) return;
        final live = b['live'];
        _live = {if (live is Map) for (final e in live.entries) '${e.key}': (e.value as num).toDouble()};
        _players = (b['players'] as List? ?? const []).length;
      } catch (_) {}
    });
  }
  bool _left = false;

  int get _now => _g?.world.serverNow ?? DateTime.now().millisecondsSinceEpoch;
  double get _latency => 0.045 + (_g?.profile.beatOffsetMs ?? 0) / 1000;

  @override
  void initState() {
    super.initState();
    _state = widget.battle;
    _players = (widget.battle['players'] as List? ?? const []).length;
    _idle.holdTurntable();
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start(GameScope.read(context)));
  }

  Future<void> _start(Game g) async {
    _g = g;
    g.catalog.addSongs([song]);
    // The preview is fetched (and its beat grid worked out) while the deck
    // rises; it starts playing as the battle does, so the song lasts the
    // whole battle.
    final beatsF = g.audio.beatInfo(song.id).catchError((Object _) => null);
    final wait = startAt - 250 - _now;
    if (wait > 0) await Future.any([beatsF, Future<void>.delayed(Duration(milliseconds: wait))]);
    final rest = startAt - 250 - _now;
    if (rest > 0) await Future<void>.delayed(Duration(milliseconds: rest));
    if (!mounted) return;
    unawaited(g.audio.playOne(song.id));
    // No beat grid within a few seconds: a steady ring instead.
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (mounted && !_ringOn) _startRing(null, 0);
    });
    final beats = await beatsF;
    while (mounted && !_ringOn && beats != null) {
      final p = g.audio.smoothPosition();
      if (p != null && p > 0.25) {
        _startRing(beats, p);
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  void _startRing(BeatInfo? beats, double position) {
    if (_ringOn) return;
    var period = beats?.period ?? 0.6;
    // Very fast songs: one ring per two beats keeps it playable.
    while (period < 0.42) {
      period *= 2;
    }
    _period = period;
    _phase = beats?.phase ?? 0;
    _clockOffset = beats == null ? 0 : position - _latency;
    _synced = beats != null;
    _beat
      ..reset()
      ..start();
    setState(() => _ringOn = true);
  }

  /// Song time now (seconds), and the beat it's nearest to.
  double get _songTime => _beat.elapsedMicroseconds / 1e6 + _clockOffset;
  double get _beatPos => (_songTime - _phase) / _period;

  /// 0 just after a beat → 1 at the next.
  double get _cycle => _beatPos - _beatPos.floorToDouble();

  void _onTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    final dt = (t - _time.value).clamp(0.0, 0.1);
    _idle.update(dt, false);
    _time.value = t;
    final g = _g;
    if (g == null) return;
    // Keep the ring locked to what's heard.
    if (_synced && !_ticking) {
      _ticking = true;
      final raw = g.audio.smoothPosition();
      _ticking = false;
      if (raw != null) {
        final err = raw - _latency - _songTime;
        // Small drift is smoothed, a stall snapped to; a jump of seconds
        // means the preview ended or restarted — the ring carries on.
        if (err.abs() < 1.5) _clockOffset += err.abs() > 0.08 ? err : err * 0.04;
      }
    }
    final now = _now;
    if (_phaseName == 'intro' && now >= startAt && _ringOn) {
      setState(() => _phaseName = 'live');
      _firstBeat = _beatPos.ceil();
      _startLiveScores();
    }
    if (_phaseName == 'live') {
      final b = _beatPos.floor();
      if (b != _lastSeenBeat) {
        _lastSeenBeat = b;
        _djBeat(b, t);
      }
      if (now >= endAt) _finish();
    }
    _pops.removeWhere((p) => t - p.born > 1.9);
  }

  /// The DJ scratches on the beat: its accuracy for this one pops out.
  void _djBeat(int beat, double t) {
    final spread = math.min(5.0, math.min(100 - dj.accuracy, dj.accuracy - 85)).clamp(0.0, 5.0);
    final r = Rng(hashInts([hashString(id), beat]));
    final acc = (dj.accuracy + (r.nextDouble() * 2 - 1) * spread).clamp(0.0, 100.0);
    _djSum += acc;
    _djBeats++;
    _pops.add(_Pop('${acc.round()}%', t, _djBeats.isEven ? 1 : -1, const Color(0xFF3DDC84)));
  }

  void _tap() {
    if (_phaseName != 'live' || !_ringOn) return;
    final pos = _beatPos;
    final beat = pos.round();
    final diff = (pos - beat).abs();
    final acc = _g?.profile.perfectRing == true ? 100 : EncounterScreen.accuracyOf(diff);
    HapticFeedback.lightImpact();
    // One tap per beat counts: the first.
    if (_taps.containsKey(beat)) return;
    _taps[beat] = acc;
    // Out of the ring, to alternate sides (as the DJ's come out of its head).
    _pops.add(_Pop('$acc%', _time.value, _taps.length.isEven ? 1 : -1, acc >= 90 ? kAccent : (acc >= 60 ? Colors.white : const Color(0xFFE5737A)),
        fromDj: false));
    setState(() {});
  }

  int get _beatsSoFar {
    final first = _firstBeat;
    if (first == null) return 0;
    final last = _lastBeat ?? _beatPos.floor();
    return math.max(0, last - first + 1);
  }

  double get _myAccuracy {
    final n = _beatsSoFar;
    if (n == 0) return 0;
    // Admin testing: perfect taps on every beat, tapped or not.
    if (_g?.profile.perfectRing == true) return 100;
    final first = _firstBeat!, last = _lastBeat ?? _beatPos.floor();
    var sum = 0;
    _taps.forEach((b, a) {
      if (b >= first && b <= last) sum += a;
    });
    return sum / n;
  }

  Future<void> _finish() async {
    if (_phaseName != 'live') return;
    _lastBeat = _beatPos.floor();
    final g = _g!;
    setState(() => _phaseName = 'scoring');
    unawaited(g.audio.stop());
    try {
      _apply(await g.world.score(id, _myAccuracy, _beatsSoFar));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    _poll = Timer.periodic(const Duration(milliseconds: 1300), (_) async {
      if (_phaseName == 'done' || _left) return _poll?.cancel();
      try {
        _apply(await g.world.battle(id));
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    });
  }

  void _apply(Map<String, dynamic> b) {
    if (!mounted) return;
    setState(() {
      _state = b;
      _players = (b['players'] as List? ?? const []).length;
      if (b['done'] == true) {
        _phaseName = 'done';
        _poll?.cancel();
        if (b['won'] == true) HapticFeedback.heavyImpact();
      }
    });
    if (b['done'] == true) _g?.world.removeDj(dj.id);
  }

  @override
  void dispose() {
    _left = true;
    _poll?.cancel();
    _livePoll?.cancel();
    _ticker.dispose();
    _time.dispose();
    _g?.audio.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final size = MediaQuery.sizeOf(context);
    final left = ((endAt - _now) / 1000).clamp(0, kBattleSeconds).ceil();
    final live = _phaseName == 'live';
    final ringSize = math.min(size.width * 0.62, size.height * 0.3);
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _tap(),
        child: Stack(fit: StackFit.expand, children: [
          // The DJ at the turntable.
          Positioned.fill(
            child: ValueListenableBuilder<double>(
              valueListenable: _time,
              builder: (_, t, _) => CustomPaint(
                painter: _ScenePainter(
                  look: FigureLook.fromJson(dj.look),
                  time: t,
                  idle: _idle,
                  beat: _ringOn && _phaseName != 'done' ? _cycle : null,
                  pops: _pops,
                  ringTop: size.height * 0.56,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(children: [
              Row(children: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('${dj.name} · DJ battle', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    Text('${song.title} — ${song.artistName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextSecondary, fontSize: 12)),
                  ]),
                ),
                if (live)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text('${left}s', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ValueListenableBuilder<double>(
                  valueListenable: _time,
                  builder: (_, _, _) {
                    final team = _teamAccuracy, djAvg = _djAverage;
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        _Score(label: _players > 1 ? 'Your team ($_players players)' : 'You', value: team, color: _blue),
                        const SizedBox(width: 10),
                        _Score(label: dj.name, value: djAvg, color: _red, alignEnd: true),
                      ]),
                      const SizedBox(height: 6),
                      // Battle meter: each side's share of the two
                      // accuracies added together.
                      _BattleMeter(blueShare: team + djAvg <= 0 ? 0.5 : team / (team + djAvg)),
                    ]);
                  },
                ),
              ),
              const Spacer(),
              if (_phaseName == 'done')
                _Result(state: _state, dj: dj, me: g.profile.playerId, onClose: () => Navigator.of(context).pop())
              else ...[
                SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                    ClipOval(child: Art(song.cover(250), size: ringSize * 0.62, radius: 0)),
                    if (_ringOn && _phaseName != 'scoring')
                      ValueListenableBuilder<double>(
                        valueListenable: _time,
                        builder: (_, _, _) => CustomPaint(size: Size.square(ringSize), painter: _RingPainter(_cycle, live)),
                      ),
                    IgnorePointer(
                      child: ValueListenableBuilder<double>(
                        valueListenable: _time,
                        builder: (_, t, _) => CustomPaint(size: Size.square(ringSize), painter: _RingPopsPainter(_pops, t)),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                Text(
                  switch (_phaseName) {
                    'intro' => _ringOn ? 'Get ready…' : 'Cueing up the record…',
                    'live' => 'Tap as each ring lands — every beat counts',
                    _ => _error ?? 'Counting the scores…',
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  _players > 1 ? '$_players players in this battle' : 'Players nearby can join in — every extra player lifts the team\'s accuracy',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: kTextSecondary),
                ),
                const SizedBox(height: 14),
                // Time left in the battle.
                if (live || _phaseName == 'intro')
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: ValueListenableBuilder<double>(
                        valueListenable: _time,
                        builder: (_, _, _) => LinearProgressIndicator(
                          value: (1 - (endAt - _now) / (kBattleSeconds * 1000)).clamp(0.0, 1.0),
                          minHeight: 5,
                          color: kAccent,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 17),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Blue (the players) on the left, red (the DJ) on the right, meeting where
/// the accuracies balance: each side's share of the two added together. It
/// slides smoothly whenever the scores change.
class _BattleMeter extends StatelessWidget {
  const _BattleMeter({required this.blueShare});
  final double blueShare;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: blueShare.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, share, _) => SizedBox(
        height: 16,
        child: LayoutBuilder(builder: (context, box) {
          final split = box.maxWidth * share;
          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Row(children: [
                  Container(
                    width: split,
                    decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF2756C9), _DjBattleScreenState._blue])),
                  ),
                  Expanded(
                    child: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [_DjBattleScreenState._red, Color(0xFFC92742)]))),
                  ),
                ]),
              ),
            ),
            // The middle: where the two are level.
            Positioned(left: box.maxWidth / 2 - 1, top: -3, bottom: -3, child: Container(width: 2, color: Colors.white38)),
            // Where they meet.
            Positioned(
              left: split - 2,
              top: -2,
              bottom: -2,
              child: Container(width: 4, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2), boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.white54)])),
            ),
          ]);
        }),
      ),
    );
  }
}

class _Score extends StatelessWidget {
  const _Score({required this.label, required this.value, required this.color, this.alignEnd = false});
  final String label;
  final double value;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: kTextSecondary)),
          Text('${value.toStringAsFixed(1)}%', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );
}

/// How it ended: who won, the accuracies, who took the Canvas home.
class _Result extends StatelessWidget {
  const _Result({required this.state, required this.dj, required this.me, required this.onClose});
  final Map<String, dynamic> state;
  final DjNpc dj;
  final String me;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final won = state['won'] == true;
    final team = (state['team'] as num?)?.toDouble() ?? 0, djAcc = (state['djAcc'] as num?)?.toDouble() ?? dj.accuracy;
    final players = (state['players'] as List? ?? const []).cast<Map<String, dynamic>>();
    final winner = state['winner'] as Map<String, dynamic>?;
    final prize = state['prize'] is Map<String, dynamic> ? CardPayload.fromJson(state['prize'] as Map<String, dynamic>) : null;
    final mine = winner != null && winner['id'] == me;
    final xp = (state['xp'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(18),
      constraints: const BoxConstraints(maxWidth: 520),
      decoration: BoxDecoration(color: const Color(0xF2141417), borderRadius: BorderRadius.circular(20), border: Border.all(color: won ? kAccent : kOutline)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(won ? 'You won the battle!' : '${dj.name} wins', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: won ? kAccent : Colors.white)),
        const SizedBox(height: 6),
        Text(
          '${players.length > 1 ? 'Team' : 'You'} ${team.toStringAsFixed(1)}%  ·  ${dj.name} ${djAcc.toStringAsFixed(1)}%',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        if (players.length > 1) ...[
          const SizedBox(height: 8),
          for (final p in players)
            Text(
              '${p['name']}${p['id'] == me ? ' (you)' : ''}: ${p['acc'] == null ? 'no score' : '${(p['acc'] as num).toStringAsFixed(1)}%'}',
              style: const TextStyle(fontSize: 12, color: kTextSecondary),
            ),
        ],
        const SizedBox(height: 10),
        if (won && prize != null) ...[
          GestureDetector(
            onTap: mine ? () => showCardFullView(context, prize) : null,
            child: _PrizeCard(card: prize, celebrate: mine),
          ),
          const SizedBox(height: 8),
          Text(
            mine
                ? 'The ${prize.edition == Edition.canvas ? 'Canvas #${prize.serial}' : 'Shiny'} of ${prize.title} is yours!'
                : '${winner?['name'] ?? 'A teammate'} took home the ${prize.edition == Edition.canvas ? 'Canvas' : 'Shiny'} of ${prize.title}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ] else if (!won)
          const Text('Bring more players, or tap closer to the beat — the DJ will be back after a short break.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: kTextSecondary)),
        if (xp > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('+$xp XP', style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700))),
        const SizedBox(height: 12),
        FilledButton(onPressed: onClose, child: const Text('Back to map')),
      ]),
    );
  }
}

/// The Canvas (or Shiny) the battle was won for: it lands with the same
/// spin, pump and confetti as a caught song for the player who won it.
class _PrizeCard extends StatefulWidget {
  const _PrizeCard({required this.card, required this.celebrate});
  final CardPayload card;
  final bool celebrate;

  @override
  State<_PrizeCard> createState() => _PrizeCardState();
}

class _PrizeCardState extends State<_PrizeCard> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));
  late final AnimationController _fx = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    if (widget.celebrate) {
      HapticFeedback.heavyImpact();
      GameScope.read(context).audio.playSfx(Sfx.catchSong);
      _spin.forward(from: 0);
      _fx.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _fx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    const w = 150.0;
    final color = c.edition == Edition.standard ? rarityColor(c.rarity) : editionColor(c.edition);
    return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => Transform(alignment: Alignment.center, transform: EncounterScreen.spinMatrix(_spin.value), child: child),
        child: SongCardView(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny, edition: c.edition, serial: c.serial, width: w, live: true),
      ),
      if (widget.celebrate)
        Positioned(
          left: -240,
          right: -240,
          top: -240,
          bottom: -240,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _fx,
              builder: (context, _) => _fx.value <= 0 || _fx.value >= 1 ? const SizedBox.shrink() : CustomPaint(painter: EncounterScreen.confetti(_fx.value, color)),
            ),
          ),
        ),
    ]);
  }
}

/// The beat ring: shrinks onto the target, landing on every beat.
class _RingPainter extends CustomPainter {
  _RingPainter(this.cycle, this.live);
  final double cycle;
  final bool live;
  static const _target = 0.72;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.width / 2;
    final flash = math.pow(1 - cycle, 8).toDouble();
    final color = live ? kAccent : Colors.white54;
    canvas.drawCircle(
        c,
        maxR * _target,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7 + flash * 7
          ..color = color.withValues(alpha: 0.35 + flash * 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.solid, 1 + flash * 8));
    canvas.drawCircle(
        c,
        maxR * _target,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white70);
    final frac = _target + (1 - _target) * (1 - cycle);
    final near = 1 - ((frac - _target).abs() / 0.3).clamp(0.0, 1.0);
    canvas.drawCircle(
        c,
        maxR * frac,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 + near * 5
          ..color = Color.lerp(Colors.white, color, near)!.withValues(alpha: (cycle / 0.15).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.solid, 2 + near * 6));
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}

/// The stage: a dotted floor, the DJ at the deck that rose out of it, and
/// the accuracy numbers popping out.
class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.look, required this.time, required this.idle, required this.beat, required this.pops, required this.ringTop});
  final FigureLook look;
  final double time;
  final IdleDirector idle;
  final double? beat;
  final List<_Pop> pops;

  /// Screen y where the ring area begins (the scene sits above it).
  final double ringTop;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = Camera3D()
      ..distance = 150
      ..pitch = 34
      ..bearing = 0
      ..size = size
      ..update();
    const s = Figure3DPainter.s;
    final g = cam.project(cam.px, cam.py, 0), top = cam.project(cam.px, cam.py, 13.5 * s);
    if (g == null || top == null) return;
    // The DJ (and the deck in front of it) fills the upper part.
    final k = math.min((ringTop - 110) * 0.86, size.width * 0.9) / (g.dy - top.dy);
    canvas.save();
    canvas.translate(size.width / 2, ringTop - 20);
    canvas.scale(k);
    canvas.translate(-g.dx, -g.dy);
    const step = 2.4 * s;
    const n = 24;
    final dot = Paint();
    for (var i = -n; i <= n; i++) {
      for (var j = -n; j <= n; j++) {
        final x = cam.px + i * step, y = cam.py + j * step;
        final r = math.sqrt((i * i + j * j).toDouble()) / n;
        if (r > 1) continue;
        final p = cam.project(x, y, 0);
        if (p == null) continue;
        dot.color = Color.fromRGBO(170, 170, 190, (0.5 * (1 - r) * (1 - r)).clamp(0.0, 1.0));
        canvas.drawCircle(p, math.max(0.35, 0.11 * s * cam.scaleAt(x, y)), dot);
      }
    }
    // Facing the camera, across the deck.
    Figure3DPainter(
      camera: cam,
      look: look,
      time: time,
      idle: idle,
      facing: 180,
      accent: kAccent,
      contrast: Colors.white,
      disc: false,
      beat: beat,
    ).paint(canvas, size);
    final head = cam.project(cam.px, cam.py, 11.5 * s);
    canvas.restore();
    if (head == null) return;
    // Head position on screen after the scene transform.
    final hx = size.width / 2 + (head.dx - g.dx) * k, hy = ringTop - 20 + (head.dy - g.dy) * k;
    final spread = (size.width / 420).clamp(0.8, 1.6);
    for (final p in pops) {
      if (p.fromDj) _drawPop(canvas, p, time, Offset(hx, hy - 6), 26 * spread, 64 * spread, 70, 26);
    }
  }

  @override
  bool shouldRepaint(_ScenePainter old) => true;
}

/// Draws an accuracy number popping out of [from]: sideways first (from
/// [near] to [near] + [far] pixels out), then slowly rising [rise] pixels
/// as it fades.
void _drawPop(Canvas canvas, _Pop p, double time, Offset from, double near, double far, double rise, double fontSize) {
  final age = time - p.born;
  if (age < 0 || age > 1.9) return;
  final out = Curves.easeOutCubic.transform((age / 0.28).clamp(0.0, 1.0));
  final up = ((age - 0.2) / 1.7).clamp(0.0, 1.0);
  final alpha = (1 - ((age - 0.9) / 1.0).clamp(0.0, 1.0)) * (age / 0.08).clamp(0.0, 1.0);
  final at = Offset(from.dx + p.side * (near + far * out), from.dy - up * rise);
  final tp = TextPainter(
    text: TextSpan(
      text: p.text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        color: p.color.withValues(alpha: alpha),
        shadows: [Shadow(color: Colors.black.withValues(alpha: 0.55 * alpha), offset: const Offset(0, 2), blurRadius: 4)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
}

/// The player's own accuracy, popping out of the song ring.
class _RingPopsPainter extends CustomPainter {
  _RingPopsPainter(this.pops, this.time);
  final List<_Pop> pops;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    for (final p in pops) {
      if (!p.fromDj) _drawPop(canvas, p, time, size.center(Offset.zero), r * 0.35, r * 0.75 + 34, 70, 24);
    }
  }

  @override
  bool shouldRepaint(_RingPopsPainter old) => true;
}
