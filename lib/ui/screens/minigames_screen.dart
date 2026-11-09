import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models.dart';
import 'package:tunetrail_core/tunetrail_core.dart' show FavoriteArtist;
import '../../game/game.dart';
import '../../game/audio_service.dart';
import '../../game/minigames.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';

/// The Minigames tab: music guessing games that pay out bits.
class MinigamesScreen extends StatefulWidget {
  const MinigamesScreen({super.key});
  @override
  State<MinigamesScreen> createState() => _MinigamesScreenState();
}

class _MinigamesScreenState extends State<MinigamesScreen> {
  MinigameData? _data;

  @override
  void initState() {
    super.initState();
    MinigameData.load().then((d) {
      if (mounted) setState(() => _data = d);
    });
  }

  MinigameFilter _filter(BuildContext context) => MinigameFilter.fromJson(GameScope.read(context).profile.minigameFilter);

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final data = _data;
    final filter = _filter(context);
    final pool = data?.pool(filter).length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Minigames'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: CurrencyChip(icon: Icons.diamond_outlined, value: g.profile.bits, color: const Color(0xFFB39DDB)),
        ),
      ]),
      body: ContentWidth(
        maxWidth: 900,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Earn bits by guessing songs and artists. ${formatNumber(g.profile.minigameBits)} bits earned so far.',
              style: const TextStyle(color: kTextSecondary)),
          const SizedBox(height: 14),
          _GameCard(
            id: 'song',
            icon: Icons.hearing,
            title: 'Song Guesser',
            body: 'Name the song from a tiny snippet. Each miss (or skip) plays a longer one: 1 s → 2 → 3 → 5 → 10 s.',
            rewards: '5 · 4 · 3 · 2 · 1 bits',
            open: data == null || pool == 0 ? null : () => SongGuesserScreen(data: data),
            onReturn: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _GameCard(
            id: 'artist',
            icon: Icons.person_search,
            title: 'Artist Guesser',
            body: 'Guess the artist from their genre, hometown, debut year and first letter. Each miss (or skip) reveals another clue.',
            rewards: '5 · 4 · 3 · 2 bits',
            open: data == null || pool == 0 ? null : () => ArtistGuesserScreen(data: data),
            onReturn: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _GameCard(
            id: 'album',
            icon: Icons.album,
            title: 'Album Cover Guesser',
            body: 'Name the album from its cover.',
            rewards: '3 · 2 · 1 bits',
            open: data == null || pool == 0 ? null : () => AlbumGuesserScreen(data: data),
            onReturn: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _GameCard(
            id: 'trivia',
            icon: Icons.quiz_outlined,
            title: 'Favourite Artist Trivia',
            body: g.profile.favoriteArtists.isEmpty
                ? '5 questions about famous artists\' hits, albums, debut and hometown. Add favourite artists on your profile to be asked about them instead.'
                : '5 multiple-choice questions about your favourite artists.',
            rewards: '1 bit per correct answer',
            open: data == null ? null : () => TriviaScreen(data: data),
            onReturn: () => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text('Each game can be played ${Game.kMinigamePlaysPerDay} times a day; plays reset at midnight.',
              style: const TextStyle(color: kTextTertiary, fontSize: 12)),
          const SizedBox(height: 18),
          Row(children: [
            const SectionLabel('Filter'),
            const Spacer(),
            Text(data == null ? 'Loading…' : '$pool artists match', style: const TextStyle(color: kTextTertiary, fontSize: 12)),
          ]),
          MinigameFilterEditor(
            filter: filter,
            onChanged: (f) {
              g.profile.minigameFilter = f.toJson();
              g.profile.changed();
              setState(() {});
            },
          ),
          if (data != null && pool == 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No artists match this filter — select more languages or genres.', style: TextStyle(color: Color(0xFFE5737A))),
            ),
        ]),
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.id, required this.icon, required this.title, required this.body, required this.rewards, required this.open, required this.onReturn});
  final String id;
  final IconData icon;
  final String title, body, rewards;
  final Widget Function()? open;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(18), border: Border.all(color: kOutline)),
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: kAccentDim, borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: kAccent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(height: 4),
            Text(body, style: const TextStyle(color: kTextSecondary, fontSize: 13)),
            const SizedBox(height: 6),
            Text(rewards, style: const TextStyle(color: kAccent, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(width: 10),
        FutureBuilder<MinigameQuota?>(
          future: g.minigameQuota(id),
          builder: (context, snap) {
            final q = snap.data;
            final left = q?.left ?? 0;
            final resume = g.pendingMinigame(id) != null;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton(
                onPressed: open == null || (!resume && (q == null || left <= 0))
                    ? null
                    : () async {
                        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => open!()));
                        onReturn();
                      },
                child: Text(resume ? 'Resume' : 'Play'),
              ),
              const SizedBox(height: 4),
              Text(
                snap.connectionState != ConnectionState.done
                    ? '…'
                    : q == null
                    ? 'Needs internet'
                    : left > 0
                    ? '$left/${Game.kMinigamePlaysPerDay} left'
                    : 'Resets in ${q.resetIn.inHours}h ${q.resetIn.inMinutes % 60}m',
                style: const TextStyle(fontSize: 11, color: kTextTertiary),
              ),
            ]);
          },
        ),
      ]),
    );
  }
}

/// Spends a daily play when a round starts; shows why if it can't.
Future<bool> _startRound(BuildContext context, String game) async {
  final g = GameScope.read(context);
  final ok = await g.useMinigamePlay(game);
  if (!ok && context.mounted) {
    final q = await g.minigameQuota(game);
    g.toast(q == null ? 'Minigames need an internet connection' : 'No plays left today — resets in ${q.resetIn.inHours}h ${q.resetIn.inMinutes % 60}m');
  }
  return ok;
}

class MinigameFilterEditor extends StatelessWidget {
  const MinigameFilterEditor({super.key, required this.filter, required this.onChanged});
  final MinigameFilter filter;
  final ValueChanged<MinigameFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chips<T extends Enum>(List<T> values, Set<T> selected, String Function(T) label, MinigameFilter Function(Set<T>) apply) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in values)
              FilterChip(
                label: Text(label(v)),
                selected: selected.contains(v),
                onSelected: (on) {
                  final s = {...selected};
                  on ? s.add(v) : s.remove(v);
                  onChanged(apply(s));
                },
              ),
          ],
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Languages', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      chips(MiniLanguage.values, filter.languages, (l) => l.label, (s) => MinigameFilter(languages: s, genres: filter.genres)),
      const SizedBox(height: 12),
      const Text('Genres', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      chips(MiniGenre.values, filter.genres, (gn) => gn.label, (s) => MinigameFilter(languages: filter.languages, genres: s)),
    ]);
  }
}

// ======================================================================
/// Previous guesses, newest first.
class _GuessList extends StatelessWidget {
  const _GuessList(this.guesses);
  final List<String> guesses;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (guesses.isNotEmpty) const SectionLabel('Your guesses'),
        for (final g in guesses.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              const Icon(Icons.close, size: 16, color: Color(0xFFE5737A)),
              const SizedBox(width: 8),
              Expanded(child: Text(g, style: const TextStyle(color: kTextSecondary, decoration: TextDecoration.lineThrough))),
            ]),
          ),
      ]);
}

/// Text field with suggestions.
class _GuessField extends StatefulWidget {
  const _GuessField({required this.hint, required this.suggest, required this.onSubmit});
  final String hint;
  final Future<List<String>> Function(String q) suggest;
  final ValueChanged<String> onSubmit;
  @override
  State<_GuessField> createState() => _GuessFieldState();
}

class _GuessFieldState extends State<_GuessField> {
  final _c = TextEditingController();
  List<String> _options = [];
  Timer? _debounce;
  int _req = 0;

  void _changed(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _options = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final r = ++_req;
      final o = await widget.suggest(q.trim());
      if (mounted && r == _req) setState(() => _options = o.take(6).toList());
    });
  }

  void _submit(String v) {
    if (v.trim().isEmpty) return;
    widget.onSubmit(v.trim());
    _c.clear();
    setState(() => _options = []);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        TextField(
          controller: _c,
          textInputAction: TextInputAction.done,
          onChanged: _changed,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: () => _submit(_c.text)),
          ),
        ),
        for (final o in _options)
          ListTile(
            dense: true,
            leading: const Icon(Icons.subdirectory_arrow_right, size: 18),
            title: Text(o),
            onTap: () => _submit(o),
          ),
      ]);
}

// ======================================================================
class SongGuesserScreen extends StatefulWidget {
  const SongGuesserScreen({super.key, required this.data});
  final MinigameData data;
  @override
  State<SongGuesserScreen> createState() => _SongGuesserScreenState();
}

class _SongGuesserScreenState extends State<SongGuesserScreen> {
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _persist();
  }

  /// Keeps the unfinished round, so leaving and coming back resumes it.
  void _persist() {
    final s = _song;
    if (_loading || s == null) return;
    GameScope.read(context).savePendingMinigame(
        'song', _solved || _gaveUp ? null : {'song': s.toJson(), 'artist': _artist?.id, 'stage': _stage, 'guesses': [..._guesses]});
  }

  bool _resume() {
    final j = GameScope.read(context).pendingMinigame('song');
    if (j == null) return false;
    try {
      final song = Song.fromJson(j['song'] as Map<String, dynamic>);
      final aid = (j['artist'] as num?)?.toInt();
      setState(() {
        _song = song;
        _artist = widget.data.artists.where((a) => a.id == aid).firstOrNull;
        _stage = (j['stage'] as num).toInt().clamp(0, kSnippetSeconds.length - 1);
        _guesses
          ..clear()
          ..addAll((j['guesses'] as List).cast<String>());
        _loading = false;
      });
      _play();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _stopClip() async {
    _clipToken++;
    await GameScope.read(context).audio.stop();
    if (mounted) setState(() => _playing = false);
  }

  int _clipToken = 0;

  final _r = math.Random();
  final Set<int> _recent = {};
  MiniArtist? _artist;
  Song? _song;
  int _stage = 0;
  final List<String> _guesses = [];
  bool _solved = false, _gaveUp = false, _loading = true, _playing = false;
  int _won = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_resume()) _next();
    });
  }

  late final AudioService _audio = GameScope.read(context).audio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _audio;
  }

  @override
  void dispose() {
    _clipToken++;
    _audio.stop();
    super.dispose();
  }

  Future<void> _next() async {
    final g = GameScope.read(context);
    _clipToken++;
    await g.audio.stop();
    if (!mounted) return;
    if (!await _startRound(context, 'song')) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _solved = _gaveUp = false;
      _stage = 0;
      _guesses.clear();
      _song = null;
    });
    for (var tries = 0; tries < 6; tries++) {
      final a = widget.data.pick(MinigameFilter.fromJson(g.profile.minigameFilter), _r, avoid: _recent);
      if (a == null) break;
      try {
        // Only well-known songs: one of the artist's five most popular.
        final top = (await g.api.artistTop(a.id, limit: 10)).where((s) => s.rank > 0).take(5).toList();
        if (top.isEmpty) continue;
        _recent.add(a.id);
        if (_recent.length > 30) _recent.remove(_recent.first);
        setState(() {
          _artist = a;
          _song = top[_r.nextInt(top.length)];
          _loading = false;
        });
        await _play();
        return;
      } catch (_) {}
    }
    setState(() {
      _loading = false;
      _error = 'Couldn\'t load a song — check your connection.';
    });
  }

  Future<void> _play() async {
    final s = _song;
    if (s == null) return;
    final g = GameScope.read(context);
    final secs = _solved || _gaveUp ? 30.0 : kSnippetSeconds[_stage];
    final token = ++_clipToken;
    setState(() => _playing = true);
    await g.audio.playClip(s.id, seconds: secs);
    // Left the screen (or pressed stop) while the clip was loading.
    if (!mounted || token != _clipToken) {
      if (!mounted) _audio.stop();
      return;
    }
    await Future<void>.delayed(Duration(milliseconds: (secs * 1000).round()));
    if (mounted && token == _clipToken) setState(() => _playing = false);
  }

  void _guess(String text) {
    final s = _song;
    if (s == null || _solved || _gaveUp) return;
    // "Title — Artist" from the suggestions: the title must match, and the
    // artist too when given.
    final parts = text.split(' — ');
    final ok = guessMatches(parts.first, s.title) && (parts.length < 2 || guessMatches(parts[1], s.artistName));
    final g = GameScope.read(context);
    if (ok) {
      final bits = kSnippetBits[_stage];
      g.awardMinigameBits(bits);
      setState(() {
        _solved = true;
        _won = bits;
      });
      _play();
    } else {
      setState(() {
        _guesses.add(text);
        if (_stage < kSnippetSeconds.length - 1) _stage++;
      });
      _play();
    }
  }

  Future<List<String>> _suggest(String q) async {
    try {
      final r = await GameScope.read(context).api.searchTracks(q, limit: 12);
      final seen = <String>{};
      return [
        for (final s in r)
          if (seen.add('${coreTitle(s.title)} — ${s.artistName}')) '${coreTitle(s.title)} — ${s.artistName}'
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _song;
    final done = _solved || _gaveUp;
    return Scaffold(
      appBar: AppBar(title: const Text('Song Guesser')),
      body: ContentWidth(
        maxWidth: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null || s == null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error ?? 'No song'), TextButton(onPressed: _next, child: const Text('Try again'))]))
            : ListView(padding: const EdgeInsets.all(16), children: [
                // Snippet ladder.
                Row(children: [
                  for (var i = 0; i < kSnippetSeconds.length; i++)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: i == _stage && !done ? kAccentDim : kSurface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: i == _stage && !done ? kAccent : kOutline),
                        ),
                        child: Column(children: [
                          Text('${kSnippetSeconds[i].round()} s', style: TextStyle(fontWeight: FontWeight.w700, color: i <= _stage ? kTextPrimary : kTextTertiary)),
                          Text('${kSnippetBits[i]} bits', style: const TextStyle(fontSize: 11, color: kTextTertiary)),
                        ]),
                      ),
                    ),
                ]),
                const SizedBox(height: 20),
                Center(
                  child: done
                      ? Column(children: [
                          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Art(s.cover(250), size: 160, radius: 14),
                            if (_artist != null) ...[
                              const SizedBox(width: 12),
                              Art(artistPicUrl(_artist!.picMd5, size: 250), size: 84, circle: true),
                            ],
                          ]),
                          const SizedBox(height: 10),
                          Text(s.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                          Text(s.artistName, style: const TextStyle(color: kTextSecondary)),
                          const SizedBox(height: 8),
                          Text(_solved ? '+$_won bits' : 'No bits this time', style: TextStyle(color: _solved ? kAccent : kTextTertiary, fontWeight: FontWeight.w700, fontSize: 18)),
                          const SizedBox(height: 8),
                          IconButton.filledTonal(
                            iconSize: 32,
                            tooltip: _playing ? 'Stop' : 'Play the song',
                            onPressed: _playing ? _stopClip : _play,
                            icon: Icon(_playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
                          ),
                        ])
                      : IconButton.filled(
                          iconSize: 56,
                          onPressed: _playing ? null : _play,
                          icon: Icon(_playing ? Icons.graphic_eq : Icons.play_arrow),
                        ),
                ),
                if (!done)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _stage == kSnippetSeconds.length - 1 ? 'Last clue: unlimited guesses at 10 s' : 'Replay the ${kSnippetSeconds[_stage].round()} s snippet as often as you like',
                        style: const TextStyle(color: kTextTertiary, fontSize: 12),
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                if (!done) _GuessField(hint: 'Song title', suggest: _suggest, onSubmit: _guess),
                const SizedBox(height: 8),
                _GuessList(_guesses),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (!done && _stage < kSnippetSeconds.length - 1)
                    OutlinedButton.icon(
                      // Skip ahead without guessing (costs the same as a miss).
                      onPressed: () {
                        setState(() => _stage++);
                        _play();
                      },
                      icon: const Icon(Icons.fast_forward, size: 18),
                      label: Text('Longer snippet (${kSnippetSeconds[math.min(_stage + 1, kSnippetSeconds.length - 1)].round()} s)'),
                    ),
                  if (!done) const SizedBox(width: 8),
                  if (!done)
                    TextButton(
                      onPressed: () {
                        setState(() => _gaveUp = true);
                        _play();
                      },
                      child: const Text('Give up'),
                    ),
                  if (done) FilledButton.icon(onPressed: _next, icon: const Icon(Icons.skip_next), label: const Text('Next song')),
                ]),
                if (_artist != null && done)
                  Center(child: Text('${_artist!.genre.label} · ${_artist!.language.label}', style: const TextStyle(color: kTextTertiary, fontSize: 12))),
              ]),
      ),
    );
  }
}

// ======================================================================
class ArtistGuesserScreen extends StatefulWidget {
  const ArtistGuesserScreen({super.key, required this.data});
  final MinigameData data;
  @override
  State<ArtistGuesserScreen> createState() => _ArtistGuesserScreenState();
}

class _ArtistGuesserScreenState extends State<ArtistGuesserScreen> {
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    final a = _a;
    if (_loading || a == null) return;
    GameScope.read(context).savePendingMinigame(
        'artist', _solved || _gaveUp ? null : {'artist': a.id, 'song': _song?.toJson(), 'skips': _skips, 'guesses': [..._guesses]});
  }

  bool _resume() {
    final j = GameScope.read(context).pendingMinigame('artist');
    if (j == null) return false;
    final id = (j['artist'] as num?)?.toInt();
    final a = widget.data.artists.where((x) => x.id == id).firstOrNull;
    if (a == null) return false;
    try {
      setState(() {
        _a = a;
        _song = j['song'] == null ? null : Song.fromJson(j['song'] as Map<String, dynamic>);
        _skips = (j['skips'] as num?)?.toInt() ?? 0;
        _guesses
          ..clear()
          ..addAll((j['guesses'] as List).cast<String>());
        _loading = false;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  final _r = math.Random();
  final Set<int> _recent = {};
  MiniArtist? _a;
  Song? _song;
  final List<String> _guesses = [];
  bool _solved = false, _gaveUp = false, _loading = true;
  int _won = 0;

  /// Clues revealed without guessing (count like misses).
  int _skips = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_resume()) _next();
    });
  }

  Future<void> _next() async {
    final g = GameScope.read(context);
    if (!await _startRound(context, 'artist')) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _loading = true;
      _solved = _gaveUp = false;
      _skips = 0;
      _guesses.clear();
      _song = null;
    });
    final a = widget.data.pick(MinigameFilter.fromJson(g.profile.minigameFilter), _r, avoid: _recent);
    if (a == null) {
      setState(() => _loading = false);
      return;
    }
    _recent.add(a.id);
    if (_recent.length > 40) _recent.remove(_recent.first);
    Song? song;
    try {
      final top = (await g.api.artistTop(a.id, limit: 10)).take(6).toList();
      if (top.isNotEmpty) song = top[_r.nextInt(top.length)];
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _a = a;
      _song = song;
      _loading = false;
    });
  }

  void _guess(String text) {
    final a = _a;
    if (a == null || _solved || _gaveUp) return;
    if (guessMatches(text, a.name)) {
      final bits = artistGuessBits(_guesses.length + _skips);
      GameScope.read(context).awardMinigameBits(bits);
      setState(() {
        _solved = true;
        _won = bits;
      });
    } else {
      setState(() => _guesses.add(text));
    }
  }

  Future<List<String>> _suggest(String q) async {
    final n = normalizeGuess(q);
    return [for (final a in widget.data.artists) if (normalizeGuess(a.name).contains(n)) a.name];
  }

  Widget _clue(IconData icon, String label, String value, {bool locked = false}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: kOutline)),
        child: Row(children: [
          Icon(locked ? Icons.lock_outline : icon, size: 20, color: locked ? kTextTertiary : kAccent),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: kTextTertiary)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(locked ? '—' : value, textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, color: locked ? kTextTertiary : kTextPrimary)),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final wrong = _guesses.length + _skips;
    final done = _solved || _gaveUp;
    return Scaffold(
      appBar: AppBar(title: const Text('Artist Guesser')),
      body: ContentWidth(
        maxWidth: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : a == null
            ? const Center(child: Text('No artists match your filter.'))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Center(
                  child: Text(done ? a.name : namePattern(a.name, everyOther: wrong >= 4),
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                ),
                Center(child: Text('${letterCount(a.name)} letters', style: const TextStyle(color: kTextTertiary, fontSize: 12))),
                const SizedBox(height: 16),
                if (wrong >= 3 || done)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Art(artistPicUrl(a.picMd5, size: 250), size: 140, circle: true),
                        if (done && _song != null) ...[const SizedBox(width: 14), Art(_song!.cover(250), size: 110, radius: 12)],
                      ]),
                    ),
                  ),
                _clue(Icons.category, 'Genre', a.genre.label),
                _clue(Icons.place, 'From', a.origin.isEmpty ? 'Unknown' : a.origin),
                _clue(Icons.calendar_month, 'Releasing music since', a.firstYear?.toString() ?? 'Unknown'),
                _clue(Icons.music_note, 'A song', _song?.title ?? '—', locked: wrong < 1 && !done),
                _clue(Icons.album, 'From the album', _song?.albumTitle ?? '—', locked: wrong < 2 && !done),
                _clue(Icons.image, 'Picture', wrong >= 3 || done ? 'Revealed' : 'After 3 misses', locked: wrong < 3 && !done),
                _clue(Icons.abc, 'Every other letter', wrong >= 4 || done ? 'Revealed' : 'After 4 misses', locked: wrong < 4 && !done),
                const SizedBox(height: 10),
                if (done)
                  Center(
                    child: Text(_solved ? '+$_won bits' : 'It was ${a.name}',
                        style: TextStyle(color: _solved ? kAccent : kTextSecondary, fontWeight: FontWeight.w700, fontSize: 18)),
                  )
                else ...[
                  Center(
                    child: Text('Guess now for ${artistGuessBits(wrong)} bit${artistGuessBits(wrong) == 1 ? '' : 's'}',
                        style: const TextStyle(color: kTextTertiary, fontSize: 12)),
                  ),
                  const SizedBox(height: 8),
                  _GuessField(hint: 'Artist name', suggest: _suggest, onSubmit: _guess),
                ],
                const SizedBox(height: 8),
                _GuessList(_guesses),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (!done && wrong < 4)
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _skips++),
                      icon: const Icon(Icons.lightbulb_outline, size: 18),
                      label: const Text('Reveal next clue'),
                    ),
                  if (!done) const SizedBox(width: 8),
                  if (!done) TextButton(onPressed: () => setState(() => _gaveUp = true), child: const Text('Give up')),
                  if (done) FilledButton.icon(onPressed: _next, icon: const Icon(Icons.skip_next), label: const Text('Next artist')),
                ]),
              ]),
      ),
    );
  }
}

// ======================================================================
/// Album Cover Guesser: name the album from its cover. 3 / 2 / 1 bits for
/// the first three tries, then unlimited tries without a reward.
class AlbumGuesserScreen extends StatefulWidget {
  const AlbumGuesserScreen({super.key, required this.data});
  final MinigameData data;
  @override
  State<AlbumGuesserScreen> createState() => _AlbumGuesserScreenState();
}

class _AlbumGuesserScreenState extends State<AlbumGuesserScreen> {
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    final p = _p;
    if (_loading || p == null) return;
    GameScope.read(context).savePendingMinigame('album', _solved || _gaveUp ? null : {'album': p.album.id, 'guesses': [..._guesses]});
  }

  bool _resume() {
    final j = GameScope.read(context).pendingMinigame('album');
    if (j == null) return false;
    final id = (j['album'] as num?)?.toInt();
    final c = widget.data.albums.where((x) => x.id == id).firstOrNull;
    if (c == null) return false;
    setState(() {
      _p = albumPuzzleFor(widget.data, c);
      _guesses
        ..clear()
        ..addAll((j['guesses'] as List? ?? const []).cast<String>());
      _loading = false;
    });
    return true;
  }

  final _r = math.Random();
  final Set<int> _recent = {};
  AlbumPuzzle? _p;
  final List<String> _guesses = [];
  bool _solved = false, _gaveUp = false, _loading = true;
  int _won = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_resume()) _next();
    });
  }

  Future<void> _next() async {
    final g = GameScope.read(context);
    if (!await _startRound(context, 'album')) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _loading = true;
      _solved = _gaveUp = false;
      _guesses.clear();
      _p = null;
    });
    final p = await pickAlbumPuzzle(g.api, widget.data, MinigameFilter.fromJson(g.profile.minigameFilter), _r, avoid: _recent);
    if (!mounted) return;
    if (p != null) {
      _recent.add(p.album.id);
      if (_recent.length > 30) _recent.remove(_recent.first);
    }
    setState(() {
      _p = p;
      _loading = false;
    });
  }

  void _guess(String text) {
    final p = _p;
    if (p == null || _solved || _gaveUp) return;
    final title = text.split(' — ').first;
    if (guessMatches(title, p.album.title)) {
      final bits = albumGuessBits(_guesses.length);
      GameScope.read(context).awardMinigameBits(bits);
      setState(() {
        _solved = true;
        _won = bits;
      });
    } else {
      setState(() => _guesses.add(text));
    }
  }

  Future<List<String>> _suggest(String q) async {
    try {
      final j = await GameScope.read(context).api.getJson('/search/album', query: {'q': q, 'limit': '12'});
      final seen = <String>{};
      return [
        for (final a in (j['data'] as List? ?? const []).cast<Map<String, dynamic>>())
          if (seen.add('${a['title']} — ${(a['artist'] as Map?)?['name'] ?? ''}')) '${a['title']} — ${(a['artist'] as Map?)?['name'] ?? ''}'
      ];
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final wrong = _guesses.length;
    final done = _solved || _gaveUp;
    return Scaffold(
      appBar: AppBar(title: const Text('Album Cover Guesser')),
      body: ContentWidth(
        maxWidth: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : p == null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('Couldn\'t find an album — check your connection.'), TextButton(onPressed: _next, child: const Text('Try again'))]))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Center(child: Art(p.album.cover(500), size: math.min(320.0, MediaQuery.sizeOf(context).width - 64), radius: 16, decodeSize: 500)),
                const SizedBox(height: 14),
                if (done) ...[
                  Center(child: Text(p.album.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
                  Center(child: Text('${p.artist.name}${p.album.releaseDate.length >= 4 ? ' · ${p.album.releaseDate.substring(0, 4)}' : ''}', style: const TextStyle(color: kTextSecondary))),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(_solved ? (_won > 0 ? '+$_won bits' : 'Got it — no bits after 3 tries') : 'No bits this time',
                        style: TextStyle(color: _solved && _won > 0 ? kAccent : kTextTertiary, fontWeight: FontWeight.w700, fontSize: 18)),
                  ),
                ] else ...[
                  Center(
                    child: Text(
                      wrong < 3 ? 'Guess now for ${albumGuessBits(wrong)} bit${albumGuessBits(wrong) == 1 ? '' : 's'} · try ${wrong + 1} of 3' : 'No bits left — keep guessing for fun',
                      style: const TextStyle(color: kTextTertiary, fontSize: 12),
                    ),
                  ),
                  if (wrong >= 3) Center(child: Text('Hint: it\'s by ${p.artist.name}', style: const TextStyle(color: kTextSecondary))),
                  const SizedBox(height: 8),
                  _GuessField(hint: 'Album title', suggest: _suggest, onSubmit: _guess),
                ],
                const SizedBox(height: 8),
                _GuessList(_guesses),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (!done) TextButton(onPressed: () => setState(() => _gaveUp = true), child: const Text('Give up')),
                  if (done) FilledButton.icon(onPressed: _next, icon: const Icon(Icons.skip_next), label: const Text('Next album')),
                ]),
              ]),
      ),
    );
  }
}

// ======================================================================
/// Favourite Artist Trivia: five multiple-choice questions (five answers
/// each) about the player's favourite artists. 1 bit per correct answer.
class TriviaScreen extends StatefulWidget {
  const TriviaScreen({super.key, required this.data});
  final MinigameData data;
  @override
  State<TriviaScreen> createState() => _TriviaScreenState();
}

class _TriviaScreenState extends State<TriviaScreen> {
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_loading || _qs.isEmpty) return;
    GameScope.read(context).savePendingMinigame(
        'trivia', _i >= _qs.length ? null : {'qs': [for (final q in _qs) q.toJson()], 'i': _i, 'correct': _correct, 'picked': _picked});
  }

  bool _resume() {
    final j = GameScope.read(context).pendingMinigame('trivia');
    if (j == null) return false;
    try {
      final qs = [for (final q in j['qs'] as List) TriviaQuestion.fromJson(q as Map<String, dynamic>)];
      setState(() {
        _qs = qs;
        _i = (j['i'] as num).toInt();
        _correct = (j['correct'] as num).toInt();
        _picked = (j['picked'] as num?)?.toInt();
        _loading = false;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  final _r = math.Random();
  List<TriviaQuestion> _qs = [];
  int _i = 0, _correct = 0;
  int? _picked;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_resume()) _start();
    });
  }

  Future<void> _start() async {
    final g = GameScope.read(context);
    if (!await _startRound(context, 'trivia')) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _loading = true;
      _i = 0;
      _correct = 0;
      _picked = null;
    });
    // No favourites yet: ask about well-known artists instead.
    var artists = g.profile.favoriteArtists;
    if (artists.isEmpty) {
      final pool = [...widget.data.artists]..sort((a, b) => b.fans.compareTo(a.fans));
      final top = pool.take(60).toList()..shuffle(_r);
      artists = [for (final a in top.take(8)) FavoriteArtist(id: a.id, name: a.name, picMd5: a.picMd5)];
    }
    final qs = await buildTrivia(g.api, widget.data, artists, _r);
    if (!mounted) return;
    setState(() {
      _qs = qs;
      _loading = false;
    });
  }

  void _pick(int k) {
    if (_picked != null) return;
    final right = k == _qs[_i].answer;
    if (right) GameScope.read(context).awardMinigameBits(1);
    setState(() {
      _picked = k;
      if (right) _correct++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final finished = !_loading && _i >= _qs.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Favourite Artist Trivia')),
      body: ContentWidth(
        maxWidth: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _qs.isEmpty
            ? const Center(child: Text('Couldn\'t build questions — check your connection.'))
            : finished
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$_correct / ${_qs.length}', style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800)),
                  Text('+$_correct bits', style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700, fontSize: 18)),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _start, child: const Text('Play again')),
                ]),
              )
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text('Question ${_i + 1} of ${_qs.length}', style: const TextStyle(color: kTextTertiary)),
                const SizedBox(height: 8),
                if (_qs[_i].image != null) Center(child: Padding(padding: const EdgeInsets.only(bottom: 12), child: Art(_qs[_i].image!, size: 140, radius: 12))),
                Text(_qs[_i].prompt, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                for (var k = 0; k < _qs[_i].options.length; k++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        backgroundColor: _picked == null
                            ? null
                            : k == _qs[_i].answer
                            ? const Color(0x3342C77A)
                            : k == _picked
                            ? const Color(0x33E5737A)
                            : null,
                      ),
                      onPressed: () => _pick(k),
                      child: Text(_qs[_i].options[k], style: const TextStyle(fontSize: 15)),
                    ),
                  ),
                if (_picked != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => setState(() {
                        _i++;
                        _picked = null;
                      }),
                      child: Text(_i + 1 < _qs.length ? 'Next question' : 'See results'),
                    ),
                  ),
              ]),
      ),
    );
  }
}
