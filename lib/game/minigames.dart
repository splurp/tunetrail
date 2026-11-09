import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../data/deezer_api.dart';
import '../data/models.dart';

/// Genres the guessing games use. Artists outside these aren't included.
enum MiniGenre {
  rock('Rock'),
  metal('Metal'),
  hiphop('Hip-Hop'),
  kpop('K-Pop'),
  rnb('R&B'),
  country('Country'),
  electronic('Electronic'),
  pop('Pop'),
  indie('Indie');

  const MiniGenre(this.label);
  final String label;
}

/// Major languages artists perform in (for the minigame filter).
enum MiniLanguage {
  english('English'),
  spanish('Spanish'),
  french('French'),
  portuguese('Portuguese'),
  korean('Korean'),
  german('German'),
  italian('Italian'),
  japanese('Japanese'),
  other('Other');

  const MiniLanguage(this.label);
  final String label;
}

/// A well-known artist for the guessing games (curated offline from Deezer
/// popularity + MusicBrainz origins; see tool/build_minigame_artists.py).
class MiniArtist {
  const MiniArtist({
    required this.id,
    required this.name,
    required this.picMd5,
    required this.genre,
    required this.language,
    this.city,
    this.country,
    this.firstYear,
    this.fans = 0,
  });

  final int fans;

  final int id;
  final String name;
  final String picMd5;
  final MiniGenre genre;
  final MiniLanguage language;
  final String? city;
  final String? country;

  /// Year of their earliest release.
  final int? firstYear;

  String get origin => [?city, if (country != null && country != city) country].join(', ');

  factory MiniArtist.fromJson(Map<String, dynamic> j) => MiniArtist(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String,
        picMd5: j['pic'] as String? ?? '',
        genre: MiniGenre.values.byName(j['genre'] as String),
        language: MiniLanguage.values.byName(j['lang'] as String),
        city: j['city'] as String?,
        country: j['country'] as String?,
        firstYear: (j['year'] as num?)?.toInt(),
        fans: (j['fans'] as num?)?.toInt() ?? 0,
      );
}

/// What the player wants the games to draw from.
class MinigameFilter {
  MinigameFilter({Set<MiniLanguage>? languages, Set<MiniGenre>? genres})
      : languages = languages ?? {...MiniLanguage.values},
        genres = genres ?? {...MiniGenre.values};
  final Set<MiniLanguage> languages;
  final Set<MiniGenre> genres;

  bool allows(MiniArtist a) => languages.contains(a.language) && genres.contains(a.genre);

  Map<String, dynamic> toJson() => {
        'lang': [for (final l in languages) l.name],
        'genres': [for (final g in genres) g.name],
      };

  factory MinigameFilter.fromJson(Map<String, dynamic>? j) {
    if (j == null) return MinigameFilter();
    Set<T> names<T extends Enum>(List<T> values, Object? list) =>
        {for (final n in (list as List? ?? const [])) ...values.where((v) => v.name == n)};
    final l = names(MiniLanguage.values, j['lang']), g = names(MiniGenre.values, j['genres']);
    return MinigameFilter(languages: l.isEmpty ? null : l, genres: g.isEmpty ? null : g);
  }
}

class MinigameData {
  MinigameData._(this.artists);
  final List<MiniArtist> artists;

  static MinigameData? _cached;

  /// From the JSON of assets/minigames/artists.json.
  static MinigameData parse(String raw) => MinigameData._([for (final j in jsonDecode(raw) as List) MiniArtist.fromJson(j as Map<String, dynamic>)]);
  static Future<MinigameData> load() async {
    final c = _cached;
    if (c != null) return c;
    final raw = await rootBundle.loadString('assets/minigames/artists.json');
    final list = [for (final j in jsonDecode(raw) as List) MiniArtist.fromJson(j as Map<String, dynamic>)];
    return _cached = MinigameData._(list);
  }

  /// Deezer fan count recorded for an artist in the data set.
  int fansOf(MiniArtist a) => a.fans;

  List<MiniArtist> pool(MinigameFilter f) => [for (final a in artists) if (f.allows(a)) a];

  MiniArtist? pick(MinigameFilter f, math.Random r, {Set<int> avoid = const {}}) {
    final p = pool(f);
    if (p.isEmpty) return null;
    final fresh = [for (final a in p) if (!avoid.contains(a.id)) a];
    final from = fresh.isEmpty ? p : fresh;
    return from[r.nextInt(from.length)];
  }
}

/// Accent-, case- and punctuation-insensitive form used to check guesses
/// ("Motorhead" matches "Motörhead", "guns n roses" matches "Guns N' Roses").
String normalizeGuess(String s) {
  var t = s.toLowerCase().trim();
  const map = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'œ': 'oe',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss', 'ł': 'l', 'š': 's', 'ž': 'z', 'č': 'c', 'ř': 'r',
    '\$': 's', '&': 'and', '+': 'and',
  };
  final b = StringBuffer();
  for (final ch in t.split('')) {
    b.write(map[ch] ?? ch);
  }
  t = b.toString().replaceAll(RegExp(r'[^a-z0-9가-힣぀-ヿ一-鿿]+'), '');
  if (t.startsWith('the') && t.length > 5) t = t.substring(3);
  return t;
}

/// Song titles without "(feat. …)", "- Remastered 2011" and similar.
String coreTitle(String title) {
  var t = title.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '');
  t = t.replaceAll(RegExp(r'\s+-\s+.*$'), '');
  return t.trim();
}

bool guessMatches(String guess, String answer) {
  final g = normalizeGuess(guess);
  if (g.isEmpty) return false;
  return g == normalizeGuess(answer) || g == normalizeGuess(coreTitle(answer));
}

/// Hangman-style name pattern: the first letter (and, once revealed, every
/// other letter) shown; other letters as underscores; spaces kept.
String namePattern(String name, {bool everyOther = false}) {
  final b = StringBuffer();
  var letterIndex = 0;
  for (final ch in name.split('')) {
    if (ch == ' ') {
      b.write('   ');
      continue;
    }
    final isLetter = RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch);
    if (!isLetter) {
      b.write('$ch ');
      continue;
    }
    final show = letterIndex == 0 || (everyOther && letterIndex.isEven);
    b.write(show ? '$ch ' : '_ ');
    letterIndex++;
  }
  return b.toString().trimRight();
}

int letterCount(String name) => RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(name).length;

/// Song Guesser: snippet lengths and the bits each stage pays.
const kSnippetSeconds = [1.0, 2.0, 3.0, 5.0, 10.0];
const kSnippetBits = [5, 4, 3, 2, 1];

/// Artist Guesser: bits for a correct guess after N wrong guesses.
int artistGuessBits(int wrong) => wrong >= 4 ? 1 : 5 - wrong;

// =================================================================== albums
/// Album Cover Guesser: bits for a correct guess after N wrong guesses
/// (3, 2, 1, then nothing — guessing continues without a reward).
int albumGuessBits(int wrong) => wrong >= 3 ? 0 : 3 - wrong;

class AlbumPuzzle {
  const AlbumPuzzle(this.artist, this.album);
  final MiniArtist artist;
  final AlbumInfo album;
}

/// A popular studio album (by Deezer fans) by an artist matching the filter.
Future<AlbumPuzzle?> pickAlbumPuzzle(DeezerApi api, MinigameData data, MinigameFilter f, math.Random r, {Set<int> avoid = const {}}) async {
  // Favour bigger artists (more recognisable covers): best of two picks.
  for (var tries = 0; tries < 8; tries++) {
    final x = data.pick(f, r, avoid: avoid), y = data.pick(f, r, avoid: avoid);
    if (x == null || y == null) return null;
    final a = data.fansOf(x) >= data.fansOf(y) ? x : y;
    try {
      final albums = (await api.artistAlbums(a.id, a.name))
          .where((x) => x.recordType == 'album' && x.fans >= 20000 && !RegExp(r'\b(live|greatest hits|best of|remix|karaoke)\b', caseSensitive: false).hasMatch(x.title))
          .toList()
        ..sort((x, y) => y.fans.compareTo(x.fans));
      if (albums.isEmpty) continue;
      // One of their three most popular albums.
      return AlbumPuzzle(a, albums[r.nextInt(math.min(3, albums.length))]);
    } catch (_) {}
  }
  return null;
}

// =================================================================== trivia
class TriviaQuestion {
  const TriviaQuestion(this.prompt, this.options, this.answer, {this.image});
  final String prompt;
  final List<String> options; // always 5, no "all/none of the above"
  final int answer;
  final String? image;
}

/// Builds [count] multiple-choice questions about the player's favourite
/// artists: most popular song, which album a song is on, debut year,
/// hometown, which song is theirs, and how big their following is.
Future<List<TriviaQuestion>> buildTrivia(DeezerApi api, MinigameData data, List<FavoriteArtist> favorites, math.Random r, {int count = 5}) async {
  final out = <TriviaQuestion>[];
  final top = <int, List<Song>>{};
  final albums = <int, List<AlbumInfo>>{};
  final infos = <int, ArtistInfo>{};
  Future<List<Song>> topOf(int id) async => top[id] ??= await api.artistTop(id, limit: 25);
  Future<List<AlbumInfo>> albumsOf(FavoriteArtist a) async =>
      albums[a.id] ??= (await api.artistAlbums(a.id, a.name)).where((x) => x.recordType == 'album').toList();
  // Songs by other well-known artists, for distractors.
  final others = <Song>[];
  for (final o in (data.artists.toList()..shuffle(r)).take(3)) {
    if (favorites.any((f) => f.id == o.id)) continue;
    try {
      others.addAll((await topOf(o.id)).take(8));
    } catch (_) {}
  }
  List<String> five(String correct, Iterable<String> pool) {
    final opts = <String>{correct};
    for (final p in pool.toList()..shuffle(r)) {
      if (opts.length >= 5) break;
      if (normalizeGuess(p) != normalizeGuess(correct)) opts.add(p);
    }
    return opts.toList();
  }

  TriviaQuestion? make(String prompt, String correct, Iterable<String> pool, {String? image}) {
    final o = five(correct, pool);
    if (o.length < 5) return null;
    o.shuffle(r);
    return TriviaQuestion(prompt, o, o.indexOf(correct), image: image);
  }

  var guard = 0;
  while (out.length < count && guard++ < count * 6 && favorites.isNotEmpty) {
    final fav = favorites[r.nextInt(favorites.length)];
    final known = data.artists.where((a) => a.id == fav.id).firstOrNull;
    try {
      final songs = await topOf(fav.id);
      if (songs.length < 6) continue;
      TriviaQuestion? q;
      switch (r.nextInt(6)) {
        case 0:
          q = make('What is ${fav.name}\'s most popular song?', coreTitle(songs.first.title), songs.skip(5).map((s) => coreTitle(s.title)));
        case 1:
          final al = await albumsOf(fav);
          final s = songs.firstWhere((s) => al.any((a) => a.id == s.albumId), orElse: () => songs.first);
          if (al.length < 3) break;
          q = make('Which album is "${coreTitle(s.title)}" by ${fav.name} on?', s.albumTitle,
              [...al.map((a) => a.title), ...others.map((o) => o.albumTitle)],
              image: s.cover(250));
        case 2:
          final al = await albumsOf(fav);
          final years = [for (final a in al) if (a.releaseDate.length >= 4) int.tryParse(a.releaseDate.substring(0, 4)) ?? 0]..removeWhere((y) => y < 1900);
          final debut = known?.firstYear ?? (years.isEmpty ? null : years.reduce(math.min));
          if (debut == null) break;
          final wrong = <int>{};
          while (wrong.length < 6) {
            final d = (r.nextInt(14) + 2) * (r.nextBool() ? 1 : -1);
            if (debut + d <= DateTime.now().year) wrong.add(debut + d);
          }
          q = make('In what year did ${fav.name} release their first music?', '$debut', wrong.map((y) => '$y'));
        case 3:
          final origin = known?.origin;
          if (origin == null || origin.isEmpty) break;
          q = make('Where is ${fav.name} from?', origin, data.artists.map((a) => a.origin).where((o) => o.isNotEmpty).toSet());
        case 4:
          q = make('Which of these songs is by ${fav.name}?', coreTitle(songs[r.nextInt(math.min(10, songs.length))].title),
              others.where((o) => o.artistId != fav.id).map((o) => coreTitle(o.title)));
        case 5:
          final info = infos[fav.id] ??= await api.artist(fav.id);
          if (info.fans < 1000) break;
          String band(int f) => f >= 1000000 ? '${(f / 1000000).toStringAsFixed(f >= 10000000 ? 0 : 1)} million' : '${(f / 1000).round()} thousand';
          final scale = [0.08, 0.25, 3.5, 9.0, 0.45, 2.2]..shuffle(r);
          q = make('About how many fans does ${fav.name} have on Deezer?', band(info.fans), scale.map((k) => band((info.fans * k).round())));
      }
      if (q != null && !out.any((x) => x.prompt == q!.prompt)) out.add(q);
    } catch (_) {}
  }
  return out;
}
