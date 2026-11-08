import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

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
  });

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
  static Future<MinigameData> load() async {
    final c = _cached;
    if (c != null) return c;
    final raw = await rootBundle.loadString('assets/minigames/artists.json');
    final list = [for (final j in jsonDecode(raw) as List) MiniArtist.fromJson(j as Map<String, dynamic>)];
    return _cached = MinigameData._(list);
  }

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
