import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;

import '../data/catalog.dart';
import '../data/models.dart';

/// Short UI sound effects (bundled original WAVs in assets/sfx).
enum Sfx { catchSong, list, quicksell, offer, tradeAccepted, sold, cardFlip }

/// Tempo and beat grid of a preview clip.
class BeatInfo {
  const BeatInfo(this.bpm, this.phase, {this.estimated = false});
  final double bpm;

  /// Seconds into the clip of the first beat (subsequent beats every
  /// 60/bpm seconds).
  final double phase;
  final bool estimated;
  double get period => 60 / bpm;
}

/// Plays 30-second Deezer previews (singly, as a queue, or as staged
/// sample breakdowns) with precise timing, using SoLoud.
class AudioService extends ChangeNotifier {
  AudioService(this.catalog) {
    instance = this;
  }

  /// The running game's audio (for things drawn in time with the music).
  static AudioService? instance;
  final Set<int> _beatRequested = {};

  /// Where the music is within the current beat (0 = on the beat, rising
  /// to 1 just before the next), or null when nothing is playing or the
  /// beat isn't known yet.
  double? beatPhase() {
    final s = current;
    if (!playing || s == null) return null;
    final b = _beats[s.id];
    if (b == null) {
      if (_beatRequested.add(s.id)) beatInfo(s.id).catchError((_) => null);
      return null;
    }
    final pos = heardPosition();
    if (pos == null || pos < b.phase) return null;
    return ((pos - b.phase) / b.period) % 1.0;
  }

  final Catalog catalog;
  final SoLoud _sl = SoLoud.instance;
  final http.Client _client = http.Client();
  Future<void>? _init;
  final Map<int, (String, DateTime)> _urlCache = {};
  final Map<int, Uint8List> _bytes = {};
  final Map<int, int> _bpmHint = {};
  final Map<int, BeatInfo> _beats = {};

  AudioSource? _source;
  SoundHandle? _handle;
  Timer? _poll;
  double _volume = 0.8;

  List<int> queue = [];
  int index = -1;
  bool playing = false;
  bool loading = false;
  String? error;
  Duration position = Duration.zero;
  Duration duration = const Duration(seconds: 30);
  String? queueName;

  Song? get current => index >= 0 && index < queue.length ? catalog.songs[queue[index]] : null;

  /// Incremented by every play/stop request; work that finishes after a
  /// newer request (or a stop) is discarded instead of starting late.
  int _request = 0;

  Future<void> _ensureInit() => _init ??= _sl.init().catchError((Object e) {
        _init = null;
        throw e;
      });

  Future<String?> _url(int songId) async {
    final c = _urlCache[songId];
    if (c != null && DateTime.now().difference(c.$2) < const Duration(minutes: 10)) return c.$1;
    final t = await catalog.api.getJson('/track/$songId');
    final p = t['preview'] as String?;
    final bpm = (t['bpm'] as num?)?.toDouble() ?? 0;
    if (bpm > 0) _bpmHint[songId] = bpm.round();
    if (p == null || p.isEmpty) return null;
    _urlCache[songId] = (p, DateTime.now());
    return p;
  }

  /// Downloads (and caches) a song's preview audio.
  Future<Uint8List?> previewBytes(int songId) async {
    final cached = _bytes[songId];
    if (cached != null) return cached;
    final url = await _url(songId);
    if (url == null) return null;
    final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    if (_bytes.length > 24) _bytes.remove(_bytes.keys.first);
    return _bytes[songId] = res.bodyBytes;
  }

  Future<void> setVolume(double v) async {
    _volume = v;
    final h = _handle;
    if (h != null && _sl.isInitialized && _sl.getIsValidVoiceHandle(h)) _sl.setVolume(h, v);
  }

  /// Playback position as the audio engine reports it (seconds), or null.
  /// It only advances once per mixed audio buffer (every ~20–90 ms), so
  /// anything animated from it steps; use [smoothPosition] for that.
  double? get exactPosition {
    final h = _handle;
    if (h == null || !_sl.isInitialized || !_sl.getIsValidVoiceHandle(h)) return null;
    return _sl.getPosition(h).inMicroseconds / 1e6;
  }

  /// Seconds between the engine's position and what's actually heard
  /// (output buffering), plus the player's calibration from Settings.
  double outputLatency = 0.045;

  final Stopwatch _clock = Stopwatch()..start();
  SoundHandle? _clockHandle;
  double _clockRaw = -1;
  final List<double> _clockOffsets = [];

  /// A smooth playback position (seconds) for animating in time with the
  /// music. The engine's own position only moves in buffer-sized steps and
  /// is read up to a buffer late, so this follows a steady clock anchored
  /// at the moments the reported position changes: the latest of those
  /// anchors is the one closest to the true position.
  double? smoothPosition() {
    final raw = exactPosition;
    final t = _clock.elapsedMicroseconds / 1e6;
    if (raw == null) {
      _clockHandle = null;
      return null;
    }
    if (_clockHandle != _handle || raw < _clockRaw - 0.05) {
      _clockHandle = _handle;
      _clockOffsets.clear();
      _clockRaw = -1;
    }
    if (raw != _clockRaw) {
      _clockRaw = raw;
      _clockOffsets.add(raw - t);
      if (_clockOffsets.length > 24) _clockOffsets.removeAt(0);
    }
    final est = t + _clockOffsets.reduce(math.max);
    // Never wander far from the engine (pauses, seeks).
    if ((est - raw).abs() > 0.2) {
      _clockOffsets
        ..clear()
        ..add(raw - t);
      return raw;
    }
    return est;
  }

  /// The music as heard: [smoothPosition] minus the output latency.
  double? heardPosition() {
    final p = smoothPosition();
    return p == null ? null : p - outputLatency;
  }

  Future<void> playQueue(List<int> songIds, {int start = 0, String? name}) async {
    if (songIds.isEmpty) return;
    queue = List.of(songIds);
    queueName = name;
    index = start.clamp(0, queue.length - 1);
    await _playCurrent();
  }

  Future<void> playOne(int songId) => playQueue([songId]);

  Future<void> _stopSound() async {
    _poll?.cancel();
    final h = _handle, s = _source;
    _handle = null;
    _source = null;
    if (h != null && _sl.isInitialized && _sl.getIsValidVoiceHandle(h)) await _sl.stop(h);
    if (s != null && _sl.isInitialized) await _sl.disposeSource(s);
  }

  /// Called whenever normal playback starts or stops, so external players
  /// (sample breakdowns) can step aside.
  VoidCallback? onTakeover;

  Future<void> _playCurrent() async {
    final req = ++_request;
    onTakeover?.call();
    final id = queue[index];
    loading = true;
    error = null;
    position = Duration.zero;
    notifyListeners();
    try {
      await _ensureInit();
      final bytes = await previewBytes(id);
      if (req != _request) return;
      if (bytes == null) {
        error = 'No preview available';
        loading = false;
        notifyListeners();
        if (queue.length > 1) unawaited(_next());
        return;
      }
      await _stopSound();
      final src = await _sl.loadMem('preview-$id-$req.mp3', bytes);
      if (req != _request) {
        await _sl.disposeSource(src);
        return;
      }
      _source = src;
      duration = _sl.getLength(src);
      _handle = _sl.play(src, volume: _volume);
      playing = true;
      _startPolling(req);
    } catch (e) {
      error = 'Playback failed';
      debugPrint('audio: $e');
    }
    loading = false;
    notifyListeners();
  }

  void _startPolling(int req) {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final h = _handle;
      if (req != _request || h == null) return;
      if (!_sl.getIsValidVoiceHandle(h)) {
        _poll?.cancel();
        _next();
        return;
      }
      position = _sl.getPosition(h);
      notifyListeners();
    });
  }

  Future<void> _next() async {
    if (index + 1 < queue.length) {
      index++;
      await _playCurrent();
    } else {
      playing = false;
      notifyListeners();
    }
  }

  Future<void> next() => _next();

  Future<void> previous() async {
    if (index > 0) {
      index--;
      await _playCurrent();
    }
  }

  Future<void> toggle() async {
    final h = _handle;
    if (current == null || h == null || !_sl.getIsValidVoiceHandle(h)) return;
    playing = !playing;
    _sl.setPause(h, !playing);
    notifyListeners();
  }

  Future<void> stop() async {
    _request++;
    onTakeover?.call();
    loading = false;
    await _stopSound();
    playing = false;
    queue = [];
    index = -1;
    notifyListeners();
  }

  // -------------------------------------------------------------- beats
  /// Tempo + beat phase for a song's preview. Uses Deezer's BPM when known
  /// and finds where the beats fall by onset analysis of the decoded audio.
  Future<BeatInfo?> beatInfo(int songId) async {
    final cached = _beats[songId];
    if (cached != null) return cached;
    final bytes = await previewBytes(songId);
    if (bytes == null) return null;
    final secs = await clipSeconds(songId, bytes);
    // Samples are taken evenly across the whole clip, so request exactly
    // fs per second of real length to get a true time base.
    const fs = 8000;
    final samples = await _sl.readSamplesFromMem(bytes, (secs * fs).round());
    final info = await compute(analyzeBeats, (samples, fs, (_bpmHint[songId] ?? 0).toDouble()));
    if (info != null) _beats[songId] = info;
    return info;
  }

  final Map<int, double> _lengths = {};

  /// Exact length of a song's preview clip in seconds.
  Future<double> clipSeconds(int songId, [Uint8List? bytes]) async {
    final known = _lengths[songId];
    if (known != null) return known;
    bytes ??= await previewBytes(songId);
    if (bytes == null) return 30;
    try {
      await _ensureInit();
      final src = await _sl.loadMem('len-$songId.mp3', bytes);
      final secs = math.max(1.0, _sl.getLength(src).inMicroseconds / 1e6);
      await _sl.disposeSource(src);
      return _lengths[songId] = secs;
    } catch (_) {
      // No audio device (decoding still works): previews are 30 s clips.
      return 30;
    }
  }

  /// Amplitude envelope (0..1) of a song's preview, [perSecond] points per
  /// second — used to draw waveforms.
  Future<Float32List?> waveform(int songId, {int perSecond = 40}) async {
    final bytes = await previewBytes(songId);
    if (bytes == null) return null;
    const fs = 4000;
    final secs = await clipSeconds(songId, bytes);
    final samples = await _sl.readSamplesFromMem(bytes, (secs * fs).round());
    final n = samples.length ~/ (fs ~/ perSecond);
    final out = Float32List(n);
    var mx = 1e-6;
    for (var i = 0; i < n; i++) {
      var p = 0.0;
      for (var k = i * (fs ~/ perSecond); k < (i + 1) * (fs ~/ perSecond); k++) {
        p = math.max(p, samples[k].abs());
      }
      out[i] = p;
      mx = math.max(mx, p);
    }
    for (var i = 0; i < n; i++) {
      out[i] /= mx;
    }
    return out;
  }

  // ------------------------------------------------------- staged audio
  /// Low-level access for staged playback (Sample editions): load a song's
  /// preview as a source.
  Future<AudioSource?> loadSource(int songId) async {
    await _ensureInit();
    final bytes = await previewBytes(songId);
    if (bytes == null) return null;
    return _sl.loadMem('stage-$songId-${DateTime.now().microsecondsSinceEpoch}.mp3', bytes);
  }

  SoLoud get engine => _sl;

  /// Plays [seconds] of a song's preview starting at [from] (Song Guesser
  /// snippets). Stops any other playback.
  Future<bool> playClip(int songId, {double from = 0, required double seconds}) async {
    await stop();
    final req = _request;
    try {
      await _ensureInit();
      final bytes = await previewBytes(songId);
      if (bytes == null || req != _request) return false;
      final src = await _sl.loadMem('clip-$songId-${DateTime.now().microsecondsSinceEpoch}.mp3', bytes);
      if (req != _request) {
        await _sl.disposeSource(src);
        return false;
      }
      _source = src;
      final h = _handle = _sl.play(src, volume: _volume, paused: true);
      _sl.seek(h, Duration(microseconds: (from * 1e6).round()));
      _sl.setPause(h, false);
      // Short fade at the end so the cut isn't a click.
      Future<void>.delayed(Duration(microseconds: (math.max(0.0, seconds - 0.06) * 1e6).round()), () {
        if (_handle == h && _sl.getIsValidVoiceHandle(h)) _sl.fadeVolume(h, 0, const Duration(milliseconds: 60));
      });
      _sl.schedulePause(h, Duration(microseconds: (seconds * 1e6).round()));
      return true;
    } catch (e) {
      debugPrint('clip: $e');
      return false;
    }
  }

  final Map<int, Uint8List> _reversed = {};

  /// A song's preview played backwards, as WAV bytes (mono, 44.1 kHz:
  /// previews are 44.1 kHz, so every sample of the left channel is kept —
  /// the decoder's "average" option gives loudness, not audio).
  Future<Uint8List?> reversedPreview(int songId) async {
    final cached = _reversed[songId];
    if (cached != null) return cached;
    final bytes = await previewBytes(songId);
    if (bytes == null) return null;
    await _ensureInit();
    const fs = 44100;
    final secs = await clipSeconds(songId, bytes);
    final samples = await _sl.readSamplesFromMem(bytes, (secs * fs).round());
    final wav = await compute(_reversedWav, (samples, fs));
    if (_reversed.length > 3) _reversed.remove(_reversed.keys.first);
    return _reversed[songId] = wav;
  }

  /// Plays the first [seconds] of a song's preview played backwards (the
  /// Backwards minigame). Stops any other playback.
  Future<bool> playReversedClip(int songId, {required double seconds}) async {
    await stop();
    final req = _request;
    try {
      final wav = await reversedPreview(songId);
      if (wav == null || req != _request) return false;
      final src = await _sl.loadMem('rev-$songId-${DateTime.now().microsecondsSinceEpoch}.wav', wav);
      if (req != _request) {
        await _sl.disposeSource(src);
        return false;
      }
      _source = src;
      final h = _handle = _sl.play(src, volume: _volume);
      Future<void>.delayed(Duration(microseconds: (math.max(0.0, seconds - 0.06) * 1e6).round()), () {
        if (_handle == h && _sl.getIsValidVoiceHandle(h)) _sl.fadeVolume(h, 0, const Duration(milliseconds: 60));
      });
      _sl.schedulePause(h, Duration(microseconds: (seconds * 1e6).round()));
      return true;
    } catch (e) {
      debugPrint('reversed clip: $e');
      return false;
    }
  }

  // ------------------------------------------------------------- effects
  final Map<Sfx, AudioSource> _sfx = {};
  bool sfxEnabled = true;
  double sfxVolume = 0.7;

  static String _sfxAsset(Sfx s) => switch (s) {
        Sfx.catchSong => 'assets/sfx/catch.wav',
        Sfx.list => 'assets/sfx/list.wav',
        Sfx.quicksell => 'assets/sfx/quicksell.wav',
        Sfx.offer => 'assets/sfx/offer.wav',
        Sfx.tradeAccepted => 'assets/sfx/trade_accepted.wav',
        Sfx.sold => 'assets/sfx/sold.wav',
        Sfx.cardFlip => 'assets/sfx/card_flip.wav',
      };

  /// Plays a sound effect over whatever music is playing.
  Future<void> playSfx(Sfx s) async {
    if (!sfxEnabled) return;
    try {
      await _ensureInit();
      final src = _sfx[s] ??= await _sl.loadAsset(_sfxAsset(s));
      // Card flips repeat quickly in a pack: kept quieter than the rest.
      _sl.play(src, volume: sfxVolume * (s == Sfx.cardFlip ? 0.45 : 1));
    } catch (e) {
      debugPrint('sfx: $e');
    }
  }

  /// Claims playback for an external player (stops normal playback and
  /// returns a request token; check [isCurrentRequest] before acting).
  Future<int> claim() async {
    await stop();
    return _request;
  }

  bool isCurrentRequest(int token) => token == _request;

  @override
  void dispose() {
    _poll?.cancel();
    _client.close();
    super.dispose();
  }
}

/// Beat analysis on mono samples at [fs] Hz (runs in an isolate).
///
/// Onsets are the rises in log energy of three bands — kick/bass
/// (≈150 Hz low-pass), hi-hats/snare (≈1.5 kHz high-pass) and the full
/// signal — with a local-mean threshold so only sharp hits count. Bass
/// lines are often syncopated, so the high band anchors the grid: on test
/// tracks this lands within ~20 ms of the drum hits, where a bass-only
/// detector could sit a 16th note off.
BeatInfo? analyzeBeats((Float32List, int, double) args) {
  final (x, fs, hint) = args;
  if (x.length < fs * 4) return null;
  const hop = 0.005; // 5 ms frames
  final w = (fs * hop).round();
  final n = x.length ~/ w;
  final aLo = math.exp(-2 * math.pi * 150 / fs);
  final aHi = math.exp(-2 * math.pi * 1500 / fs);
  var lo = 0.0, hiLp = 0.0;
  final eFull = Float64List(n), eLo = Float64List(n), eHi = Float64List(n);
  for (var i = 0; i < n; i++) {
    var s = 0.0, sl = 0.0, sh = 0.0;
    for (var k = i * w; k < (i + 1) * w; k++) {
      final v = x[k];
      lo = aLo * lo + (1 - aLo) * v;
      hiLp = aHi * hiLp + (1 - aHi) * v;
      final hi = v - hiLp;
      s += v * v;
      sl += lo * lo;
      sh += hi * hi;
    }
    eFull[i] = math.log(1e-5 + math.sqrt(s / w));
    eLo[i] = math.log(1e-5 + math.sqrt(sl / w));
    eHi[i] = math.log(1e-5 + math.sqrt(sh / w));
  }
  final raw = Float64List(n);
  for (var i = 1; i < n; i++) {
    raw[i] = math.max(0, eLo[i] - eLo[i - 1]) + math.max(0, eHi[i] - eHi[i - 1]) + 0.5 * math.max(0, eFull[i] - eFull[i - 1]);
  }
  // Keep only peaks above the local (100 ms) mean.
  final k = (0.1 / hop).round();
  final on = Float64List(n);
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    acc += raw[i];
    if (i >= k) acc -= raw[i - k];
    final c = i - k ~/ 2;
    if (c >= 0) on[c] = math.max(0, raw[c] - acc / k);
  }
  double bpm = hint;
  var estimated = false;
  if (bpm <= 0) {
    // Autocorrelation over 70–180 BPM with a mild preference near 100.
    var best = -1.0;
    for (var b = 70.0; b <= 180; b += 0.5) {
      final lag = 60 / b / hop;
      var s = 0.0;
      for (var i = 0; i + lag.ceil() < n; i += 2) {
        final j = i + lag;
        final f = j - j.floor();
        s += on[i] * (on[j.floor()] * (1 - f) + on[math.min(n - 1, j.ceil())] * f);
      }
      s *= math.exp(-math.pow(math.log(b / 100) / 0.7, 2).toDouble() * 0.5);
      if (s > best) {
        best = s;
        bpm = b;
      }
    }
    estimated = true;
  }
  if (bpm <= 0) return null;
  // Phase: where a beat grid at this tempo best lines up with the onsets.
  final period = 60 / bpm / hop;
  var bestPhase = 0.0, bestScore = -1.0;
  for (var p = 0.0; p < period; p += 0.25) {
    var s = 0.0;
    for (var t = p; t < n - 1; t += period) {
      final i = t.floor();
      final f = t - i;
      s += on[i] * (1 - f) + on[i + 1] * f;
    }
    if (s > bestScore) {
      bestScore = s;
      bestPhase = p;
    }
  }
  // Energy rises peak slightly before the perceived hit (~15 ms measured).
  return BeatInfo(bpm, (bestPhase * hop + 0.015) % (60 / bpm), estimated: estimated);
}


/// Reverses decoded samples (-1..1) into a 16-bit mono WAV file.
Uint8List _reversedWav((Float32List, int) args) {
  final (samples, fs) = args;
  final n = samples.length;
  // Normalise a little so quiet decodes aren't too soft.
  var peak = 1e-6;
  for (final v in samples) {
    final a = v.abs();
    if (a > peak) peak = a;
  }
  final gain = peak < 0.5 ? 0.9 / peak : 1.0;
  final out = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  out.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, fs, Endian.little);
  out.setUint32(28, fs * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  str(36, 'data');
  out.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (samples[n - 1 - i] * gain).clamp(-1.0, 1.0);
    out.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}
