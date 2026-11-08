import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../data/samples.dart';
import 'audio_service.dart';

/// Live state of a breakdown, for drawing playheads.
class SamplePlayback {
  const SamplePlayback({this.songId = 0, this.stage = -1, this.sourcePos, this.songPos, this.stages = const [], this.loading = false, this.error});
  final int songId;
  final int stage;

  /// Current position in the source / song previews (seconds), or null
  /// when that track is silent.
  final double? sourcePos, songPos;
  final List<SampleStage> stages;
  final bool loading;
  final String? error;
  bool get active => stage >= 0 || loading;
}

/// One playing clip.
abstract class _Voice {
  Future<void> prepare(double from);
  void start();
  Future<double?> position();
  void setVolume(double v);
  Future<void> seek(double secs);
  Future<void> dispose();
}

class _SoLoudVoice extends _Voice {
  _SoLoudVoice(this.sl, this.source);
  final SoLoud sl;
  final AudioSource source;
  SoundHandle? h;

  @override
  Future<void> prepare(double from) async {
    h = sl.play(source, volume: 0, paused: true);
    sl.seek(h!, Duration(microseconds: (from * 1e6).round()));
  }

  @override
  void start() => sl.setPause(h!, false);
  @override
  Future<double?> position() async => h != null && sl.getIsValidVoiceHandle(h!) ? sl.getPosition(h!).inMicroseconds / 1e6 : null;
  @override
  void setVolume(double v) {
    if (h != null && sl.getIsValidVoiceHandle(h!)) sl.setVolume(h!, v);
  }

  @override
  Future<void> seek(double secs) async {
    if (h != null && sl.getIsValidVoiceHandle(h!)) sl.seek(h!, Duration(microseconds: (secs * 1e6).round()));
  }

  @override
  Future<void> dispose() async {
    if (h != null && sl.getIsValidVoiceHandle(h!)) await sl.stop(h!);
  }
}

/// Source previews the audio engine can't decode (Apple AAC) play through
/// the platform media player instead.
class _MediaVoice extends _Voice {
  _MediaVoice(this.file);
  final File file;
  late final VideoPlayerController c = VideoPlayerController.file(file, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));

  @override
  Future<void> prepare(double from) async {
    await c.initialize();
    await c.setVolume(0);
    await c.seekTo(Duration(microseconds: (from * 1e6).round()));
  }

  @override
  void start() => c.play();
  @override
  Future<double?> position() async {
    final p = await c.position;
    return p == null ? null : p.inMicroseconds / 1e6;
  }
  @override
  void setVolume(double v) => c.setVolume(v);
  @override
  Future<void> seek(double secs) => c.seekTo(Duration(microseconds: (secs * 1e6).round()));
  @override
  Future<void> dispose() async {
    await c.pause();
    await c.dispose();
  }
}

/// Plays a scripted, Tracklib-style breakdown for a Sample-edition card
/// (see [SampleInfo]): clips of the original and the song on a timeline,
/// with the song entering in sync with the sampled audio.
class SamplePlayer extends ValueNotifier<SamplePlayback> {
  SamplePlayer(this.audio) : super(const SamplePlayback()) {
    // Any other playback (mini player, encounters…) ends the breakdown.
    audio.onTakeover = () {
      if (!_claiming) stop();
    };
  }
  final AudioService audio;
  bool _claiming = false;
  int _token = 0;
  final List<Timer> _timers = [];
  final List<_Voice> _voices = [];
  final List<AudioSource> _sources = [];
  Timer? _poll;
  _Voice? _songVoice;
  final Stopwatch _clock = Stopwatch();
  final http.Client _http = http.Client();

  SoLoud get _sl => audio.engine;

  /// Precise playback position of the song once it has entered (for
  /// beat-synced catching), else null.
  Future<double?> songPosition() async => _songVoice?.position();

  /// Seconds since the breakdown started, or null when idle.
  double? get elapsed => _clock.isRunning ? _clock.elapsedMicroseconds / 1e6 : null;

  // ------------------------------------------------------------- sources
  final Map<int, File> _itunesFiles = {};

  Future<File?> _itunesPreview(int trackId) async {
    final cached = _itunesFiles[trackId];
    if (cached != null && await cached.exists()) return cached;
    final dir = Directory('${Directory.systemTemp.path}/tunetrail_samples');
    await dir.create(recursive: true);
    final f = File('${dir.path}/itunes_$trackId.m4a');
    if (await f.exists() && await f.length() > 10000) return _itunesFiles[trackId] = f;
    final look = await _http.get(Uri.https('itunes.apple.com', '/lookup', {'id': '$trackId'})).timeout(const Duration(seconds: 12));
    final url = ((jsonDecode(look.body)['results'] as List).firstOrNull as Map?)?['previewUrl'] as String?;
    if (url == null) return null;
    final res = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return null;
    await f.writeAsBytes(res.bodyBytes, flush: true);
    return _itunesFiles[trackId] = f;
  }

  Future<_Voice?> _voiceFor(SampleInfo s, SampleTrack t) async {
    if (t == SampleTrack.source && s.sourceItunesId != null) {
      final f = await _itunesPreview(s.sourceItunesId!);
      return f == null ? null : _MediaVoice(f);
    }
    final src = await audio.loadSource(t == SampleTrack.source ? s.source.id : s.song.id);
    if (src == null) return null;
    _sources.add(src);
    return _SoLoudVoice(_sl, src);
  }

  // ---------------------------------------------------------------- play
  Future<void> play(SampleInfo s) async {
    await stop();
    final token = ++_token;
    _claiming = true;
    final claim = await audio.claim();
    _claiming = false;
    value = SamplePlayback(songId: s.song.id, stages: s.stages, loading: true);
    final prepared = <(SampleClip, _Voice)>[];
    try {
      for (final c in s.clips) {
        final v = await _voiceFor(s, c.track);
        if (v == null) throw StateError('preview unavailable');
        _voices.add(v);
        await v.prepare(c.from + (c.track == SampleTrack.source ? s.sourceShift : s.songShift));
        prepared.add((c, v));
      }
    } catch (e) {
      debugPrint('sample breakdown: $e');
      if (token == _token) {
        await _release();
        value = SamplePlayback(songId: s.song.id, stages: s.stages, error: 'Couldn\'t load the previews');
      }
      return;
    }
    if (token != _token || !audio.isCurrentRequest(claim)) {
      await _release();
      return;
    }
    _clock
      ..reset()
      ..start();

    void at(double secs, void Function() f) {
      final wait = secs - _clock.elapsedMicroseconds / 1e6;
      _timers.add(Timer(Duration(microseconds: math.max(0, (wait * 1e6).round())), () {
        if (token == _token) f();
      }));
    }

    for (final (c, v) in prepared) {
      final shift = c.track == SampleTrack.source ? s.sourceShift : s.songShift;
      at(c.at, () async {
        v.start();
        _fade(v, 0, 0.9, c.fadeIn);
        if (c.track == SampleTrack.song) _songVoice = v;
        // Sync check: once running, compare where the voice is with where
        // the script says it should be and correct a late start.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (token != _token) return;
        final p = await v.position();
        if (p == null) return;
        final ideal = c.from + shift + (_clock.elapsedMicroseconds / 1e6 - c.at);
        if ((p - ideal).abs() > 0.025) await v.seek(ideal + (v is _MediaVoice ? 0.02 : 0));
      });
      at(c.end - c.fadeOut, () => _fade(v, 0.9, 0, c.fadeOut));
      at(c.end + 0.05, () => v.setVolume(0));
    }
    at(s.length + 0.2, stop);

    _poll = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (token != _token) return;
      final t = _clock.elapsedMicroseconds / 1e6;
      var stage = 0;
      for (var i = 0; i < s.stages.length; i++) {
        if (t >= s.stages[i].start) stage = i;
      }
      // Playheads follow the script (smooth), including visible rewinds.
      double? srcPos, songPos;
      for (final c in s.clips) {
        if (t >= c.at && t <= c.end) {
          final p = c.from + (t - c.at);
          if (c.track == SampleTrack.source) {
            srcPos = p;
          } else {
            songPos = p;
          }
        }
      }
      for (final r in s.rewinds) {
        if (t >= r.at && t <= r.at + r.duration) {
          final u = Curves.easeInOutCubic.transform((t - r.at) / r.duration);
          srcPos = r.from + (r.to - r.from) * u;
        }
      }
      value = SamplePlayback(songId: s.song.id, stage: stage, stages: s.stages, sourcePos: srcPos, songPos: songPos);
    });
  }

  void _fade(_Voice v, double from, double to, double secs) {
    if (secs <= 0.01) {
      v.setVolume(to);
      return;
    }
    final steps = math.max(1, (secs / 0.03).round());
    var i = 0;
    final token = _token;
    _timers.add(Timer.periodic(Duration(microseconds: (secs * 1e6 / steps).round()), (t) {
      if (token != _token) {
        t.cancel();
        return;
      }
      i++;
      v.setVolume(from + (to - from) * math.min(1.0, i / steps));
      if (i >= steps) t.cancel();
    }));
  }

  Future<void> _release() async {
    final vs = List.of(_voices);
    final ss = List.of(_sources);
    _voices.clear();
    _sources.clear();
    _songVoice = null;
    for (final v in vs) {
      try {
        await v.dispose();
      } catch (_) {}
    }
    if (_sl.isInitialized) {
      for (final s in ss) {
        await _sl.disposeSource(s);
      }
    }
  }

  Future<void> stop() async {
    _token++;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _poll?.cancel();
    _clock
      ..stop()
      ..reset();
    await _release();
    if (value.active || value.error != null) value = const SamplePlayback();
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
