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
    final beatsF = g.audio.beatInfo(song.id).catchError((Object _) => null);
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
        _clockOffset += err.abs() > 0.08 ? err : err * 0.04;
      }
    }
    final now = _now;
    if (_phaseName == 'intro' && now >= startAt && _ringOn) {
      setState(() => _phaseName = 'live');
      _firstBeat = _beatPos.ceil();
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
    final acc = EncounterScreen.accuracyOf(diff);
    HapticFeedback.lightImpact();
    // One tap per beat counts: the first.
    if (_taps.containsKey(beat)) return;
    _taps[beat] = acc;
    _pops.add(_Pop('$acc%', _time.value, 0, acc >= 90 ? kAccent : (acc >= 60 ? Colors.white : const Color(0xFFE5737A)), fromDj: false));
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
                    final mine = _myAccuracy, djAvg = _djBeats == 0 ? dj.accuracy : _djSum / _djBeats;
                    final boost = 2 - math.pow(0.5, _players - 1);
                    return Row(children: [
                      _Score(label: _players > 1 ? 'You (team of $_players: ×${boost.toStringAsFixed(boost == boost.roundToDouble() ? 0 : 2)})' : 'You', value: mine, color: kAccent),
                      const SizedBox(width: 10),
                      _Score(label: dj.name, value: djAvg, color: const Color(0xFF3DDC84), alignEnd: true),
                    ]);
                  },
                ),
              ),
              if (live || _phaseName == 'intro')
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
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
                ),
              const Spacer(),
              if (_phaseName == 'done')
                _Result(state: _state, dj: dj, me: g.profile.playerId, onClose: () => Navigator.of(context).pop())
              else ...[
                SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: Stack(alignment: Alignment.center, children: [
                    ClipOval(child: Art(song.cover(250), size: ringSize * 0.62, radius: 0)),
                    if (_ringOn && _phaseName != 'scoring')
                      ValueListenableBuilder<double>(
                        valueListenable: _time,
                        builder: (_, _, _) => CustomPaint(size: Size.square(ringSize), painter: _RingPainter(_cycle, live)),
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
                const SizedBox(height: 22),
              ],
            ]),
          ),
        ]),
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
            child: SongCardView(song: Song.fromPayload(prize), rarity: prize.rarity, shiny: prize.shiny, edition: prize.edition, serial: prize.serial, width: 120, live: false),
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
      ..pitch = 18
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
    for (final p in pops) {
      final age = time - p.born;
      if (age < 0 || age > 1.9) continue;
      // Out sideways first, then slowly up, fading.
      final out = Curves.easeOutCubic.transform((age / 0.28).clamp(0.0, 1.0));
      final rise = ((age - 0.2) / 1.7).clamp(0.0, 1.0);
      final alpha = (1 - ((age - 0.9) / 1.0).clamp(0.0, 1.0)) * (age / 0.08).clamp(0.0, 1.0);
      final at = p.fromDj
          ? Offset(hx + p.side * (26 + 64 * out) * (size.width / 420).clamp(0.8, 1.6), hy - 6 - rise * 70)
          : Offset(size.width / 2, ringTop + 6 - rise * 46);
      final tp = TextPainter(
        text: TextSpan(
          text: p.text,
          style: TextStyle(
            fontSize: p.fromDj ? 26 : 20,
            fontWeight: FontWeight.w900,
            color: p.color.withValues(alpha: alpha),
            shadows: [Shadow(color: Colors.black.withValues(alpha: 0.55 * alpha), offset: const Offset(0, 2), blurRadius: 4)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ScenePainter old) => true;
}
