
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

/// Card editions: alternate presentations of a song. An edition card is
/// *only* that edition — editions don't combine with shininess (and are
/// shown without a rarity). A player owns at most one card per variant.
enum Edition {
  standard('Regular', 1.0, 0),

  /// Full-card music-video clip (or full-bleed cover art) with the details
  /// overlaid. Serialized #1–#10 per song.
  canvas('Canvas', 6.0, 10),

  /// Waveform breakdown aligned with the song it samples; plays the sample
  /// first, then fades into the song. Serialized #1–#5 per song.
  sample('Sample', 12.0, 5),

  /// Full-card footage of the song performed live (a live music video),
  /// for songs that have one. Serialized #1–#5 per song.
  live('Live', 9.0, 5);

  const Edition(this.label, this.valueMultiplier, this.maxSerials);
  final String label;
  final double valueMultiplier;

  /// How many numbered copies can ever exist per song (0 = unlimited).
  final int maxSerials;
  bool get serialized => maxSerials > 0;

  /// The order editions are listed in (filters, menus).
  static const displayOrder = [Edition.standard, Edition.canvas, Edition.live, Edition.sample];

  static Edition fromIndex(int i) => Edition.values[i.clamp(0, Edition.values.length - 1)];
}

/// Chance a wild spawn is a Canvas edition.
const int kCanvasOdds = 500;

/// Chance a wild spawn is a Live edition (kept only for songs that have
/// live footage).
const int kLiveOdds = 1000;

/// Chance a wild spawn is a Sample edition (of a song with sample data).
const int kSampleOdds = 5000;

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

/// Coins to buy a regular drop on the map from just outside catching range
/// (low end) up to the far edge of the nearby area (high end).
(int, int) mapPriceRange(Rarity r) => switch (r) {
      Rarity.common => (50, 100),
      Rarity.uncommon => (100, 200),
      Rarity.rare => (200, 400),
      Rarity.epic => (400, 800),
      Rarity.legendary => (800, 2000),
    };

/// Canvas, Live and Sample editions can't be scrapped.
bool canScrap(Edition e) => e == Edition.standard;

/// Coins for scrapping a card: half of what the same drop costs to buy on
/// the map (from just out of range); Shinies ×10. Editions: 0 (they can't
/// be scrapped). [rank] is kept for callers but no longer matters.
int scrapValue(Rarity r, bool shiny, int rank, {Edition edition = Edition.standard}) {
  if (!canScrap(edition)) return 0;
  final base = mapPriceRange(r).$1 ~/ 2;
  return shiny ? base * 10 : base;
}
