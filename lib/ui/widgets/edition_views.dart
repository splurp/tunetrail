import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';
import 'package:video_player/video_player.dart';

import '../../data/models.dart';
import '../../data/samples.dart';
import '../../game/movie_service.dart';
import '../../game/sample_player.dart';
import '../app.dart';
import 'cards.dart' show RarityLabel;
import 'net_image.dart';
import 'ui_kit.dart';

Color editionColor(Edition e) => switch (e) {
      Edition.canvas => const Color(0xFFFF8A65),
      Edition.sample => const Color(0xFF4DD0E1),
      Edition.standard => kTextSecondary,
    };

IconData editionIcon(Edition e) => switch (e) {
      Edition.canvas => Icons.movie_outlined,
      Edition.sample => Icons.graphic_eq,
      Edition.standard => Icons.music_note,
    };

/// The card's variant name: an edition's name ("Canvas", "Sample") or, for
/// standard cards, the rarity (with the shiny glint).
class VariantLabel extends StatelessWidget {
  const VariantLabel({super.key, required this.rarity, required this.shiny, required this.edition, this.serial = 0, this.fontSize = 12});
  final Rarity rarity;
  final bool shiny;
  final Edition edition;
  final int serial;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    if (edition == Edition.standard) return RarityLabel(rarity, shiny: shiny, fontSize: fontSize);
    return Text(serial > 0 ? '${edition.label} #$serial' : edition.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: editionColor(edition), fontWeight: FontWeight.w700, fontSize: fontSize, letterSpacing: 0.3));
  }
}

/// "#3/10" serial number chip for edition cards.
class SerialBadge extends StatelessWidget {
  const SerialBadge(this.serial, this.edition, {super.key, this.size = 10});
  final int serial;
  final Edition edition;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: size * 0.55, vertical: size * 0.2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(size),
          border: Border.all(color: editionColor(edition).withValues(alpha: 0.9)),
        ),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '#$serial', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white, fontSize: size)),
            TextSpan(text: '/${edition.maxSerials}', style: TextStyle(color: Colors.white60, fontSize: size * 0.8)),
          ]),
        ),
      );
}

/// Small "CANVAS" / "SAMPLE" tag.
class EditionBadge extends StatelessWidget {
  const EditionBadge(this.edition, {super.key, this.size = 10});
  final Edition edition;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (edition == Edition.standard) return const SizedBox.shrink();
    final icon = editionIcon(edition), color = editionColor(edition);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: size * 0.5, vertical: size * 0.15),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(size),
        border: Border.all(color: color.withValues(alpha: 0.8), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: size * 1.2, color: color),
        SizedBox(width: size * 0.3),
        Text(edition.label.toUpperCase(), style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: color)),
      ]),
    );
  }
}

// ----------------------------------------------------------------- canvas
/// Full-bleed backdrop for Canvas-edition cards: the (muted, looping)
/// music-video clip when one exists and [live], otherwise a still or the
/// song's cover art filling the card.
class CanvasBackdrop extends StatefulWidget {
  const CanvasBackdrop({super.key, required this.song, this.live = true});
  final Song song;
  final bool live;
  @override
  State<CanvasBackdrop> createState() => _CanvasBackdropState();
}

class _CanvasBackdropState extends State<CanvasBackdrop> {
  VideoPlayerController? _video;
  MovieClip? _clip;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_clip == null && !_failed) _load();
  }

  Future<void> _load() async {
    final movies = GameScope.read(context).movies;
    final clip = movies.cached(widget.song.id) ?? await movies.clipFor(widget.song);
    if (!mounted) return;
    if (clip == null) {
      setState(() => _failed = true);
      return;
    }
    setState(() => _clip = clip);
    if (!widget.live) return;
    final file = await movies.videoFile(widget.song.id, clip);
    if (!mounted || file == null) return;
    final v = VideoPlayerController.file(file, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
    _video = v;
    try {
      await v.initialize();
      await v.setVolume(0);
      await v.setLooping(true);
      await v.play();
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return LayoutBuilder(builder: (context, box) {
      final side = math.max(box.maxWidth, box.maxHeight);
      final poster = _clip?.posterUrl ?? '';
      // Album art underneath; the video still (if it loads) on top.
      Widget child = Stack(fit: StackFit.expand, children: [
        Art(widget.song.cover(500), size: side, radius: 0, decodeSize: 600),
        if (poster.isNotEmpty)
          Image(
            image: NetImage(poster),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
      ]);
      if (v != null && v.value.isInitialized && !_failed) {
        child = FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(width: v.value.size.width, height: v.value.size.height, child: VideoPlayer(v)),
        );
      }
      return SizedBox(width: box.maxWidth, height: box.maxHeight, child: ClipRect(child: OverflowBox(maxWidth: double.infinity, maxHeight: double.infinity, child: SizedBox(width: box.maxWidth, height: box.maxHeight, child: child))));
    });
  }
}

// ----------------------------------------------------------------- sample
/// Tracklib-style breakdown: the sampled record's waveform above the
/// modern song's, aligned so the sampled passage lines up, with covers,
/// stage labels and live playheads.
class SampleBreakdownPanel extends StatefulWidget {
  const SampleBreakdownPanel({super.key, required this.info, this.compact = false});
  final SampleInfo info;
  final bool compact;
  @override
  State<SampleBreakdownPanel> createState() => _SampleBreakdownPanelState();
}

class _SampleBreakdownPanelState extends State<SampleBreakdownPanel> {
  Float32List? _src, _mod;
  static final Map<int, Float32List> _cache = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final audio = GameScope.read(context).audio;
    Future<Float32List?> get(int id) async => _cache[id] ??= (await audio.waveform(id)) ?? Float32List(0);
    try {
      final a = widget.info.decodedSourceEnvelope() ?? await get(widget.info.source.id);
      final b = await get(widget.info.song.id);
      if (mounted) {
        setState(() {
          _src = a;
          _mod = b;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.info;
    final player = GameScope.read(context).samples;
    return ValueListenableBuilder<SamplePlayback>(
      valueListenable: player,
      builder: (context, pb, _) {
        final mine = pb.songId == s.song.id && pb.active;
        return LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final rowH = (box.maxHeight.isFinite ? box.maxHeight : w) / 2;
          Widget row(Song song, String sub, Float32List? wave, bool top) => SizedBox(
                height: rowH,
                child: Stack(children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WavePainter(
                        wave: wave,
                        info: s,
                        isSource: top,
                        playhead: mine ? (top ? pb.sourcePos : pb.songPos) : null,
                        color: top ? const Color(0xFFFFB74D) : const Color(0xFF4DD0E1),
                      ),
                    ),
                  ),
                  Positioned(
                    left: w * 0.03,
                    top: top ? w * 0.03 : null,
                    bottom: top ? null : w * 0.03,
                    child: Row(children: [
                      Art(song.cover(120), size: w * 0.13, radius: w * 0.015),
                      SizedBox(width: w * 0.025),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(song.title, style: TextStyle(fontSize: w * 0.045, fontWeight: FontWeight.w700, color: Colors.white)),
                        Text(sub, style: TextStyle(fontSize: w * 0.034, color: Colors.white70)),
                      ]),
                    ]),
                  ),
                ]),
              );
          final stage = mine && pb.stage >= 0 ? pb.stages[pb.stage].label : null;
          return Container(
            color: const Color(0xFF0B0B0F),
            child: Stack(children: [
              Column(children: [
                row(s.source, '${s.source.artistName} · ${s.sourceYear}', _src, true),
                row(s.song, s.song.artistName, _mod, false),
              ]),
              Positioned(
                right: w * 0.03,
                top: rowH - w * 0.04,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: w * 0.02, vertical: w * 0.005),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(w * 0.03)),
                  child: Text(
                    stage ?? (pb.loading && mine ? 'Loading…' : (pb.error != null && pb.songId == s.song.id ? pb.error! : 'Sampled ${s.sourceYear}')),
                    style: TextStyle(fontSize: w * 0.034, color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ]),
          );
        });
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.wave, required this.info, required this.isSource, required this.playhead, required this.color});
  final Float32List? wave;
  final SampleInfo info;
  final bool isSource;
  final double? playhead;
  final Color color;

  // Shared x axis: source-preview time; the song row is shifted so the
  // sampled audio lines up vertically (Tracklib-style).
  static const span = 17.0;
  double get _x0 => info.alignSource - span * 0.62;
  double get _songOffset => info.alignSong - info.alignSource;

  /// Track time → axis time.
  double _toAxis(double t) => isSource ? t : t - _songOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final w = wave;
    final mid = size.height * (isSource ? 0.62 : 0.38);
    final amp = size.height * 0.3;
    double xOf(double axisT) => (axisT - _x0) / span * size.width;
    // Mark where the sampled audio sits.
    final passA = xOf(info.alignSource), passB = xOf(info.alignSource + 1.45);
    canvas.drawRect(Rect.fromLTRB(passA, 0, passB, size.height), Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawLine(Offset(passA, 0), Offset(passA, size.height), Paint()..color = color.withValues(alpha: 0.5));
    if (w != null && w.isNotEmpty) {
      const perSec = 40.0;
      final path = Path();
      final bars = (size.width / 2.5).floor();
      for (var i = 0; i < bars; i++) {
        final axisT = _x0 + i / bars * span;
        final t = isSource ? axisT : axisT + _songOffset;
        final k = (t * perSec).round();
        if (k < 0 || k >= w.length) continue;
        final h = math.max(1.0, w[k] * amp);
        path.addRect(Rect.fromLTWH(i / bars * size.width, mid - h, 1.6, h * 2));
      }
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.85));
    }
    final p = playhead;
    if (p != null) {
      final x = xOf(_toAxis(p));
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(
            Offset(x, 0),
            Offset(x, size.height),
            Paint()
              ..color = Colors.white
              ..strokeWidth = 2);
      }
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.wave != wave || old.playhead != playhead || old.info != info;
}
