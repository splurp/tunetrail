import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/game/minigames.dart';

void main() {
  test('guesses ignore accents, case, punctuation and "the"', () {
    expect(guessMatches('Motorhead', 'Motörhead'), isTrue);
    expect(guessMatches('guns n roses', "Guns N' Roses"), isTrue);
    expect(guessMatches('beyonce', 'Beyoncé'), isTrue);
    expect(guessMatches('Weeknd', 'The Weeknd'), isTrue);
    expect(guessMatches('ac dc', 'AC/DC'), isTrue);
    expect(guessMatches('Simon and Garfunkel', 'Simon & Garfunkel'), isTrue);
    expect(guessMatches('Metallica', 'Megadeth'), isFalse);
    expect(guessMatches('', 'Queen'), isFalse);
  });

  test('song titles match without features and edition suffixes', () {
    expect(guessMatches('Stronger', 'Stronger (feat. Daft Punk)'), isTrue);
    expect(guessMatches('bohemian rhapsody', 'Bohemian Rhapsody - Remastered 2011'), isTrue);
    expect(guessMatches('Runaway', 'Stronger'), isFalse);
  });

  test('hangman pattern and rewards', () {
    expect(namePattern('Daft Punk'), 'D _ _ _    _ _ _ _');
    expect(namePattern('Daft Punk', everyOther: true), 'D _ f _    P _ n _');
    expect(letterCount("Guns N' Roses"), 10);
    expect([for (var w = 0; w < 6; w++) artistGuessBits(w)], [5, 4, 3, 2, 1, 1]);
    expect(kSnippetSeconds, [1, 2, 3, 5, 10]);
    expect(kSnippetBits, [5, 4, 3, 2, 1]);
  });

  test('filter round trip', () {
    final f = MinigameFilter(languages: {MiniLanguage.french}, genres: {MiniGenre.rock, MiniGenre.pop});
    final g = MinigameFilter.fromJson(f.toJson());
    expect(g.languages, {MiniLanguage.french});
    expect(g.genres, {MiniGenre.rock, MiniGenre.pop});
    expect(MinigameFilter.fromJson(null).genres.length, MiniGenre.values.length);
  });
}
