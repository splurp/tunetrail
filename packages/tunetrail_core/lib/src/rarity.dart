import 'dart:math' as math;

/// Song rarities, ordered from most to least common.
enum Rarity {
  common('Common', 0xFFA3A3AB, 5500, 10, 5, 10),
  uncommon('Uncommon', 0xFF5DBB7A, 2500, 30, 10, 25),
  rare('Rare', 0xFF4E8EF0, 1200, 100, 25, 60),
  epic('Epic', 0xFFA774E8, 600, 400, 60, 150),
  legendary('Legendary', 0xFFE3B341, 200, 1500, 150, 400);

  const Rarity(this.label, this.argb, this.spawnWeight, this.baseValue,
      this.catchCoins, this.catchXp);

  /// Display name.
  final String label;

  /// ARGB colour used for frames, glows and labels.
  final int argb;

  /// Relative weight when rolling a wild spawn (sums to 10000).
  final int spawnWeight;

  /// Baseline market value in coins (used for NPC pricing & quick-sell).
  final int baseValue;

  /// Coins awarded when this rarity is caught in the wild.
  final int catchCoins;

  /// XP awarded when caught.
  final int catchXp;

  static Rarity fromIndex(int i) => Rarity.values[i.clamp(0, 4)];
}

/// Card editions: alternate presentations of a song. Each edition (with
/// rarity and shininess) is a separate variant — a player owns at most one
/// copy of each variant.
enum Edition {
  standard('Standard', 1.0),

  /// Full-card music-video clip with the details overlaid.
  movie('Movie', 2.0),

  /// Waveform breakdown aligned with the song it samples; plays the sample
  /// first, then fades into the song.
  sample('Sample', 2.5);

  const Edition(this.label, this.valueMultiplier);
  final String label;
  final double valueMultiplier;

  static Edition fromIndex(int i) => Edition.values[i.clamp(0, Edition.values.length - 1)];
}

/// Chance (1 in N) that any card roll becomes a shiny variant.
const int kShinyOdds = 128;

/// Shiny multiplier applied to market value.
const int kShinyValueMultiplier = 5;

/// Quick-sell (sell to the game) price: a fraction of base value.
int quickSellValue(Rarity r, bool shiny) =>
    ((r.baseValue * (shiny ? kShinyValueMultiplier : 1)) * 0.25).round();

/// Estimated fair market value of a card.
int fairValue(Rarity r, bool shiny, {int popularity = 500000, Edition edition = Edition.standard}) {
  // Deezer "rank" ranges roughly 0..1,000,000; popular songs are worth more.
  final popFactor = 0.75 + (popularity.clamp(0, 1000000) / 1000000) * 0.75;
  return (r.baseValue * (shiny ? kShinyValueMultiplier : 1) * popFactor * edition.valueMultiplier)
      .round();
}

/// Coins for scrapping a card in the Scrapyard. Songs with more streams
/// (higher Deezer rank, 0..1,000,000) are worth more scrap.
int scrapValue(Rarity r, bool shiny, int rank, {Edition edition = Edition.standard}) {
  final streams = rank.clamp(0, 1000000) / 1000000;
  final base = r.baseValue * 0.2 * (0.35 + 1.65 * streams * streams) * edition.valueMultiplier;
  final v = math.max(1, base.round());
  return shiny ? v * 3 : v;
}
