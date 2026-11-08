import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;

import '../data/catalog.dart';
import '../data/models.dart';

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
  AudioService(this.catalog);

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

  /// Current exact playback position of the playing clip (seconds), or null.
  double? get exactPosition {
    final h = _handle;
    if (h == null || !_sl.isInitialized || !_sl.getIsValidVoiceHandle(h)) return null;
    return _sl.getPosition(h).inMicroseconds / 1e6;
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
