import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../data/samples.dart';
import 'audio_service.dart';

/// One stage of a sample breakdown.
class SampleStage {
  const SampleStage(this.label, this.start, this.end);
  final String label;
  final double start, end; // seconds on the breakdown timeline
}

/// Live state of a breakdown, for drawing playheads.
class SamplePlayback {
  const SamplePlayback({this.songId = 0, this.stage = -1, this.sourcePos, this.songPos, this.stages = const [], this.loading = false});
  final int songId;
  final int stage;

  /// Current position in the source / modern previews (seconds), or null
  /// when that track is silent.
  final double? sourcePos, songPos;
  final List<SampleStage> stages;
  final bool loading;
  bool get active => stage >= 0 || loading;
}

/// Plays a Tracklib-style breakdown for a Sample-edition card:
///  1. the original record, leading into the sampled passage;
///  2. if the producer chopped or re-pitched it, that transformation;
///  3. the passage again, crossfading into the modern song at the exact
///     point it is used.
class SamplePlayer extends ValueNotifier<SamplePlayback> {
  SamplePlayer(this.audio) : super(const SamplePlayback()) {
    // Any other playback (mini player, encounters…) ends the breakdown.
    audio.onTakeover = () {
      if (!_claiming) stop();
    };
  }
  final AudioService audio;
  bool _claiming = false;

  int _token = -1;
  final List<Timer> _timers = [];
  Timer? _poll;
  SoundHandle? _src, _mod;
  AudioSource? _srcSource, _modSource;
  double _srcSpeed = 1;

  SoLoud get _sl => audio.engine;

  static const double _lead = 6; // seconds of the original before the passage
  static const double _fade = 2.4;

  /// Builds the stage plan for [s].
  static (List<SampleStage>, double passage) plan(SampleInfo s) {
    final beat = 60 / (s.bpm > 0 ? s.bpm : 95);
    final passage = 8 * beat * s.rate; // source seconds in an 8-beat phrase
    final lead = math.min(_lead, s.sourceAt);
    final a = lead + passage;
    final stages = <SampleStage>[SampleStage('Original · ${s.source.artistName}', 0, a)];
    var t = a;
    switch (s.transform) {
      case SampleTransform.none:
        break;
      case SampleTransform.speed:
        final d = passage / s.rate;
        stages.add(SampleStage(s.rate > 1 ? 'Sped up ×${s.rate.toStringAsFixed(2)}' : 'Slowed ×${s.rate.toStringAsFixed(2)}', t, t + d));
        t += d;
      case SampleTransform.chopped:
        final d = s.chopBeats.length * 2 * beat;
        stages.add(SampleStage('Chopped', t, t + d));
        t += d;
    }
    stages.add(SampleStage('${s.song.artistName} · ${s.song.title}', t, t + math.min(22, 29.5 - s.songAt)));
    return (stages, passage);
  }

  Future<void> play(SampleInfo s) async {
    await stop();
    final token = ++_token;
    _claiming = true;
    final claim = await audio.claim();
    _claiming = false;
    final (stages, passage) = plan(s);
    value = SamplePlayback(songId: s.song.id, stages: stages, loading: true);
    final srcSource = await audio.loadSource(s.source.id);
    final modSource = await audio.loadSource(s.song.id);
    if (token != _token || !audio.isCurrentRequest(claim) || srcSource == null || modSource == null) {
      if (srcSource != null) await _sl.disposeSource(srcSource);
      if (modSource != null) await _sl.disposeSource(modSource);
      if (token == _token) value = const SamplePlayback();
      return;
    }
    _srcSource = srcSource;
    _modSource = modSource;
    final beat = 60 / (s.bpm > 0 ? s.bpm : 95);
    final lead = math.min(_lead, s.sourceAt);
    final t0 = DateTime.now();

    // Stage 1: the original.
    final src = _src = _sl.play(srcSource, volume: 0.9, paused: true);
    _sl.seek(src, Duration(microseconds: ((s.sourceAt - lead) * 1e6).round()));
    _srcSpeed = 1;
    _sl.setPause(src, false);

    void at(double secs, void Function() f) => _timers.add(Timer(Duration(microseconds: (secs * 1e6).round()), () {
          if (token == _token) f();
        }));

    // Stage 2: transformation.
    final stage2 = stages.length == 3 ? stages[1] : null;
    if (stage2 != null) {
      if (s.transform == SampleTransform.speed) {
        at(stage2.start, () {
          _sl.seek(src, Duration(microseconds: (s.sourceAt * 1e6).round()));
          _sl.setRelativePlaySpeed(src, s.rate);
          _srcSpeed = s.rate;
        });
      } else {
        // Re-sequence 2-beat slices of the passage (in modern tempo).
        final slice = 2 * beat * s.rate;
        for (var k = 0; k < s.chopBeats.length; k++) {
          final from = s.sourceAt + s.chopBeats[k] * slice;
          at(stage2.start + k * 2 * beat, () {
            _sl.seek(src, Duration(microseconds: (from * 1e6).round()));
            if (s.rate != 1) _sl.setRelativePlaySpeed(src, s.rate);
            _srcSpeed = s.rate;
          });
        }
      }
    }

    // Stage 3: passage again, crossfading into the modern song in sync.
    final last = stages.last;
    at(last.start, () {
      _sl.seek(src, Duration(microseconds: (s.sourceAt * 1e6).round()));
      if (s.rate != 1) _sl.setRelativePlaySpeed(src, s.rate);
      _srcSpeed = s.rate;
      final mod = _mod = _sl.play(modSource, volume: 0, paused: true);
      _sl.seek(mod, Duration(microseconds: (s.songAt * 1e6).round()));
      _sl.setPause(mod, false);
      _sl.fadeVolume(mod, 0.9, Duration(milliseconds: (_fade * 1000).round()));
      _sl.fadeVolume(src, 0, Duration(milliseconds: (_fade * 1000).round()));
      _sl.scheduleStop(src, Duration(milliseconds: (_fade * 1000).round() + 100));
    });
    at(last.end, () => stop());

    _poll = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (token != _token) return;
      final t = DateTime.now().difference(t0).inMicroseconds / 1e6;
      var stage = 0;
      for (var i = 0; i < stages.length; i++) {
        if (t >= stages[i].start) stage = i;
      }
      double? pos(SoundHandle? h) => h != null && _sl.getIsValidVoiceHandle(h) ? _sl.getPosition(h).inMicroseconds / 1e6 : null;
      value = SamplePlayback(songId: s.song.id, stage: stage, stages: stages, sourcePos: pos(_src), songPos: pos(_mod));
    });
  }

  /// Seconds played through the current stage (for the UI's speed label).
  double get sourceSpeed => _srcSpeed;

  Future<void> stop() async {
    _token++;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _poll?.cancel();
    final hs = [_src, _mod];
    final ss = [_srcSource, _modSource];
    _src = _mod = null;
    _srcSource = _modSource = null;
    if (_sl.isInitialized) {
      for (final h in hs) {
        if (h != null && _sl.getIsValidVoiceHandle(h)) await _sl.stop(h);
      }
      for (final s in ss) {
        if (s != null) await _sl.disposeSource(s);
      }
    }
    if (value.active) value = const SamplePlayback();
  }
}
