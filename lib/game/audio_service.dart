import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../data/catalog.dart';
import '../data/models.dart';

/// Plays 30-second Deezer previews, singly or as a playlist queue.
class AudioService extends ChangeNotifier {
  AudioService(this.catalog) {
    _player.onPlayerComplete.listen((_) => _next());
    _player.onPositionChanged.listen((p) {
      position = p;
      notifyListeners();
    });
    _player.onDurationChanged.listen((d) => duration = d);
  }

  final Catalog catalog;
  final AudioPlayer _player = AudioPlayer();
  final Map<int, (String, DateTime)> _urlCache = {};

  List<int> queue = [];
  int index = -1;
  bool playing = false;
  bool loading = false;
  String? error;
  Duration position = Duration.zero;
  Duration duration = const Duration(seconds: 30);
  String? queueName;

  Song? get current => index >= 0 && index < queue.length ? catalog.songs[queue[index]] : null;

  Future<String?> _url(int songId) async {
    final c = _urlCache[songId];
    if (c != null && DateTime.now().difference(c.$2) < const Duration(minutes: 10)) return c.$1;
    final u = await catalog.api.previewUrl(songId);
    if (u != null) _urlCache[songId] = (u, DateTime.now());
    return u;
  }

  Future<void> setVolume(double v) => _player.setVolume(v);

  Future<void> playQueue(List<int> songIds, {int start = 0, String? name}) async {
    if (songIds.isEmpty) return;
    queue = List.of(songIds);
    queueName = name;
    index = start.clamp(0, queue.length - 1);
    await _playCurrent();
  }

  Future<void> playOne(int songId) => playQueue([songId]);

  Future<void> _playCurrent() async {
    final id = queue[index];
    loading = true;
    error = null;
    position = Duration.zero;
    notifyListeners();
    try {
      final url = await _url(id);
      if (url == null) {
        error = 'No preview available';
        loading = false;
        notifyListeners();
        if (queue.length > 1) unawaited(_next());
        return;
      }
      await _player.stop();
      await _player.play(UrlSource(url));
      playing = true;
    } catch (e) {
      error = 'Playback failed';
      debugPrint('audio: $e');
    }
    loading = false;
    notifyListeners();
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
    if (current == null) return;
    if (playing) {
      await _player.pause();
      playing = false;
    } else {
      await _player.resume();
      playing = true;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _player.stop();
    playing = false;
    queue = [];
    index = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
