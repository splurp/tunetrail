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

/// Chance (1 in N) that any card roll becomes a shiny variant.
const int kShinyOdds = 128;

/// Shiny multiplier applied to market value.
const int kShinyValueMultiplier = 5;

/// Quick-sell (sell to the game) price: a fraction of base value.
int quickSellValue(Rarity r, bool shiny) =>
    ((r.baseValue * (shiny ? kShinyValueMultiplier : 1)) * 0.25).round();

/// Estimated fair market value of a card.
int fairValue(Rarity r, bool shiny, {int popularity = 500000}) {
  // Deezer "rank" ranges roughly 0..1,000,000; popular songs are worth more.
  final popFactor = 0.75 + (popularity.clamp(0, 1000000) / 1000000) * 0.75;
  return (r.baseValue * (shiny ? kShinyValueMultiplier : 1) * popFactor)
      .round();
}
