import 'dart:math' as math;

import 'rarity.dart';
import 'rng.dart';
import 'song_catalog.dart';

// ===================================================================== catching
/// How close a player must be to catch a spawn.
const double kCatchRangeMeters = 100.0;

/// Extra distance the server allows for GPS jitter between the game's view
/// and the position it reports.
const double kCatchRangeSlackMeters = 35.0;

/// The far edge of the "nearby" area (out-of-range spawns can be bought up
/// to here).
const double kNearbyMeters = 500.0;

/// Throws before a spawn gets away for good.
const int kMaxThrows = 5;

const List<double> kBaseCatch = [0.92, 0.78, 0.62, 0.48, 0.34];
const List<double> kFleeChance = [0.02, 0.03, 0.05, 0.07, 0.1];

/// Catch chance for a throw with [acc]% timing: 90%+ always catches,
/// 50–89% climbs from the rarity's base chance towards certain, and an
/// off-beat throw keeps a small chance.
double catchChance(Rarity r, int acc) {
  final base = kBaseCatch[r.index];
  if (acc >= 90) return 1;
  if (acc >= 50) return (base + (1 - base) * 0.75 * (acc - 50) / 40).clamp(0.0, 1.0);
  return base * 0.3;
}

/// Coins to buy an out-of-range spawn [distance] metres away: more for rarer
/// songs and further away. Null when it can't be bought — in range (catch
/// it!), too far, or a Shiny / Canvas / Live / Sample, which you have to go
/// to in person.
int? spawnPrice(Rarity rarity, double distance, {bool shiny = false, Edition edition = Edition.standard, double maxDistance = kNearbyMeters + 150}) {
  if (shiny || edition != Edition.standard) return null;
  if (distance <= kCatchRangeMeters || distance > maxDistance) return null;
  final (lo, hi) = mapPriceRange(rarity);
  // Just outside the catch circle costs the low end; the far edge of the
  // nearby area the high end.
  final t = ((distance - kCatchRangeMeters) / (kNearbyMeters - kCatchRangeMeters)).clamp(0.0, 1.0);
  return ((lo + (hi - lo) * t) / 5).round() * 5;
}

/// Time of day nudges which genres appear (night = electronic & R&B,
/// morning = pop & folk, evening = rock & hip hop).
Map<int, double> timeOfDayBias(int hour) {
  if (hour >= 22 || hour < 5) return const {106: 2.0, 113: 2.0, 165: 1.6, 129: 1.5};
  if (hour < 11) return const {132: 1.4, 466: 1.8, 84: 1.4, 98: 1.5};
  if (hour >= 17) return const {152: 1.5, 116: 1.4, 464: 1.6, 85: 1.3};
  return const {};
}

/// Multiplies two genre bias maps.
Map<int, double> combineBias(Map<int, double> a, Map<int, double> b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final out = Map<int, double>.of(a);
  b.forEach((k, v) => out[k] = (out[k] ?? 1) * v);
  return out;
}

// ======================================================================== days
/// A calendar day ("2026-11-9") for a moment and a time-zone offset.
String dayKeyAt(int ms, int tzOffsetMinutes) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms + tzOffsetMinutes * 60000, isUtc: true);
  return '${d.year}-${d.month}-${d.day}';
}

/// Milliseconds until the next local midnight.
int msUntilMidnight(int ms, int tzOffsetMinutes) {
  const day = 24 * 3600 * 1000;
  final local = ms + tzOffsetMinutes * 60000;
  return day - (local % day);
}

/// A new time-zone offset is only accepted this long after the previous one
/// was pinned (so hopping time zones can't add extra days).
const int kTzRepinMs = 20 * 3600 * 1000;

// ========================================================================= shop
enum ShopKind { bits, theme, hat, shirt, pet, backpack, bundle, profileTheme }

/// Prices of everything in the shop (the game adds names, art and colours).
class ShopItem {
  const ShopItem(this.id, this.kind, {this.usd = 0, this.bits = 0, this.bitsPrice = 0, this.bundleOf});
  final String id;
  final ShopKind kind;

  /// Real-money price (0 = free or bought with bits).
  final double usd;

  /// Bits a bits bundle gives.
  final int bits;

  /// Price in bits (pets, profile themes).
  final int bitsPrice;

  /// A bundle unlocks every item of this kind.
  final ShopKind? bundleOf;

  bool get realMoney => usd > 0 && bitsPrice == 0;
  bool get free => usd == 0 && bitsPrice == 0 && kind != ShopKind.bits;
}

const List<ShopItem> kShopItems = [
  ShopItem('bits_100', ShopKind.bits, usd: 0.99, bits: 100),
  ShopItem('bits_550', ShopKind.bits, usd: 4.99, bits: 550),
  ShopItem('bits_1200', ShopKind.bits, usd: 9.99, bits: 1200),
  ShopItem('bits_2500', ShopKind.bits, usd: 19.99, bits: 2500),
  ShopItem('bits_6500', ShopKind.bits, usd: 49.99, bits: 6500),
  ShopItem('theme_classic', ShopKind.theme),
  ShopItem('theme_midnight', ShopKind.theme, usd: 0.99),
  ShopItem('theme_synthwave', ShopKind.theme, usd: 0.99),
  ShopItem('theme_vaporwave', ShopKind.theme, usd: 0.99),
  ShopItem('theme_noir', ShopKind.theme, usd: 0.99),
  ShopItem('theme_vinyl', ShopKind.theme, usd: 0.99),
  ShopItem('theme_matrix', ShopKind.theme, usd: 0.99),
  ShopItem('theme_arctic', ShopKind.theme, usd: 0.99),
  ShopItem('theme_lava', ShopKind.theme, usd: 0.99),
  ShopItem('theme_aurora', ShopKind.theme, usd: 0.99),
  ShopItem('theme_candy', ShopKind.theme, usd: 0.99),
  ShopItem('theme_sakura', ShopKind.theme, usd: 0.99),
  ShopItem('hat_cap', ShopKind.hat, usd: 0.99),
  ShopItem('hat_beanie', ShopKind.hat, usd: 0.99),
  ShopItem('hat_headphones', ShopKind.hat, usd: 1.99),
  ShopItem('hat_tophat', ShopKind.hat, usd: 1.99),
  ShopItem('hat_cowboy', ShopKind.hat, usd: 1.99),
  ShopItem('hat_party', ShopKind.hat, usd: 0.99),
  ShopItem('hat_wizard', ShopKind.hat, usd: 2.49),
  ShopItem('hat_crown', ShopKind.hat, usd: 2.99),
  ShopItem('hat_halo', ShopKind.hat, usd: 2.99),
  ShopItem('shirt_tee_red', ShopKind.shirt, usd: 0.99),
  ShopItem('shirt_tee_black', ShopKind.shirt, usd: 0.99),
  ShopItem('shirt_striped', ShopKind.shirt, usd: 1.49),
  ShopItem('shirt_hoodie', ShopKind.shirt, usd: 1.99),
  ShopItem('shirt_hawaiian', ShopKind.shirt, usd: 1.99),
  ShopItem('shirt_tux', ShopKind.shirt, usd: 2.49),
  ShopItem('shirt_lightning', ShopKind.shirt, usd: 1.99),
  ShopItem('shirt_rainbow', ShopKind.shirt, usd: 2.49),
  ShopItem('pet_cat', ShopKind.pet, bitsPrice: 500),
  ShopItem('pet_dog', ShopKind.pet, bitsPrice: 500),
  ShopItem('pet_bird', ShopKind.pet, bitsPrice: 500),
  ShopItem('pet_slime', ShopKind.pet, bitsPrice: 500),
  ShopItem('pet_robot', ShopKind.pet, bitsPrice: 500),
  ShopItem('pet_ghost', ShopKind.pet, bitsPrice: 500),
  ShopItem('pet_hamster', ShopKind.pet, bitsPrice: 500),
  ShopItem('bag_classic', ShopKind.backpack, usd: 0.99),
  ShopItem('bag_boombox', ShopKind.backpack, usd: 1.99),
  ShopItem('bag_guitar', ShopKind.backpack, usd: 1.99),
  ShopItem('bag_crate', ShopKind.backpack, usd: 1.99),
  ShopItem('bag_jetpack', ShopKind.backpack, usd: 3.99),
  ShopItem('bag_wings', ShopKind.backpack, usd: 3.99),
  ShopItem('bundle_hats', ShopKind.bundle, usd: 2.99, bundleOf: ShopKind.hat),
  ShopItem('bundle_shirts', ShopKind.bundle, usd: 2.99, bundleOf: ShopKind.shirt),
  ShopItem('bundle_backpacks', ShopKind.bundle, usd: 2.99, bundleOf: ShopKind.backpack),
  ShopItem('pt_graphite', ShopKind.profileTheme),
  ShopItem('pt_violet', ShopKind.profileTheme),
  ShopItem('pt_ocean', ShopKind.profileTheme),
  ShopItem('pt_mono', ShopKind.profileTheme, bitsPrice: 100),
  ShopItem('pt_sunset', ShopKind.profileTheme, bitsPrice: 150),
  ShopItem('pt_forest', ShopKind.profileTheme, bitsPrice: 150),
  ShopItem('pt_vinyl', ShopKind.profileTheme, bitsPrice: 200),
  ShopItem('pt_candy', ShopKind.profileTheme, bitsPrice: 200),
  ShopItem('pt_neon', ShopKind.profileTheme, bitsPrice: 300),
  ShopItem('pt_lava', ShopKind.profileTheme, bitsPrice: 300),
  ShopItem('pt_starfield', ShopKind.profileTheme, bitsPrice: 400),
  ShopItem('pt_waves', ShopKind.profileTheme, bitsPrice: 400),
  ShopItem('pt_party', ShopKind.profileTheme, bitsPrice: 500),
  ShopItem('pt_aurora', ShopKind.profileTheme, bitsPrice: 600),
  ShopItem('pt_sweetheart', ShopKind.profileTheme, bitsPrice: 750),
  ShopItem('pt_gold', ShopKind.profileTheme, bitsPrice: 1000),
];

final Map<String, ShopItem> _shopById = {for (final i in kShopItems) i.id: i};

ShopItem? shopItem(String id) => _shopById[id];

/// Ids of every item of [kind] (what a bundle unlocks).
List<String> shopIdsOfKind(ShopKind kind) => [for (final i in kShopItems) if (i.kind == kind) i.id];

/// Bits it costs to put up (or replace) a showcase on the market.
const int kShowcaseBits = 100;

/// Bits a username change costs (the first choice and first change are free).
const int kUsernameChangeBits = 100;

// ======================================================================== packs
/// The odds of a pack of song cards bought with bits.
class PackRules {
  const PackRules(this.id,
      {required this.bits,
      required this.cards,
      this.allMin = Rarity.common,
      this.guaranteedMin,
      this.luck = 1.0,
      this.shinyOdds = kShinyOdds,
      this.guaranteedShiny = false,
      this.canvasOdds = 0});
  final String id;
  final int bits;
  final int cards;

  /// Every card is at least this rarity.
  final Rarity allMin;

  /// At least one card of this rarity or higher.
  final Rarity? guaranteedMin;

  /// Multiplier on rare+ weights.
  final double luck;

  /// 1 in [shinyOdds] per card (0 = no random shinies).
  final int shinyOdds;

  /// One card is guaranteed to be shiny.
  final bool guaranteedShiny;

  /// 1 in [canvasOdds] packs holds a random Canvas edition (0 = never).
  final int canvasOdds;
}

const List<PackRules> kPackRules = [
  PackRules('pack_gold', bits: 100, cards: 10, allMin: Rarity.rare, guaranteedMin: Rarity.epic, shinyOdds: 0),
  PackRules('pack_platinum', bits: 500, cards: 10, allMin: Rarity.epic, guaranteedMin: Rarity.legendary, shinyOdds: 100),
  PackRules('pack_prismatic', bits: 1000, cards: 10, allMin: Rarity.epic, shinyOdds: 0, guaranteedShiny: true, canvasOdds: 20),
];

PackRules? packRules(String id) {
  for (final p in kPackRules) {
    if (p.id == id) return p;
  }
  return null;
}

/// One card rolled for a pack.
class PackRoll {
  const PackRoll(this.song, this.shiny, this.canvas);
  final SongInfo song;
  final bool shiny;

  /// This slot is a Canvas edition (if serials remain).
  final bool canvas;
}

/// Rolls a pack's cards. Regular slots lean towards favourite artists
/// (1 in 3); Shiny and Canvas slots never do.
List<PackRoll> rollPack(SongPool pool, PackRules p, Rng rng, {Set<int> favorites = const {}}) {
  if (pool.size == 0) return const [];
  SongInfo pick(Rarity min, bool fav) {
    if (fav && favorites.isNotEmpty && rng.nextInt(3) == 0) {
      final f = pool.favoriteAtLeast(rng, favorites, min);
      if (f != null) return f;
    }
    for (var tries = 0; tries < 12; tries++) {
      final cand = pool.pickSong(rng, rarity: rng.rollRarity(minIndex: min.index, luck: p.luck));
      if (cand != null && pool.rarityOf(cand.id).index >= min.index) return cand;
    }
    return pool.pickSong(rng, rarity: min) ?? pool.pickSong(rng)!;
  }

  final shiny = List.generate(p.cards, (_) => p.shinyOdds > 0 && rng.chance(p.shinyOdds));
  if (p.guaranteedShiny && !shiny.contains(true)) shiny[rng.nextInt(p.cards)] = true;
  var canvasSlot = -1;
  if (p.canvasOdds > 0 && rng.nextInt(p.canvasOdds) == 0) {
    for (var i = 0; i < p.cards; i++) {
      if (!shiny[i]) {
        canvasSlot = i;
        break;
      }
    }
  }
  final rolls = <PackRoll>[
    for (var i = 0; i < p.cards; i++) PackRoll(pick(p.allMin, !shiny[i] && i != canvasSlot), shiny[i], i == canvasSlot),
  ];
  // Guarantee: the last regular slot is redrawn at the guaranteed rarity.
  final g = p.guaranteedMin;
  if (g != null && !rolls.any((r) => pool.rarityOf(r.song.id).index >= g.index)) {
    final i = rolls.lastIndexWhere((r) => !r.shiny && !r.canvas);
    final at = i < 0 ? rolls.length - 1 : i;
    rolls[at] = PackRoll(pick(g, !rolls[at].shiny && !rolls[at].canvas), rolls[at].shiny, rolls[at].canvas);
  }
  return rolls;
}

/// Bits for an artist's blind box: 5 for small artists up to 100 for the
/// biggest (log scale of Deezer fans).
int blindBoxPrice(int fans) {
  final t = (math.log(math.max(fans, 1)) / math.ln10 - 4) / (math.log(30000000) / math.ln10 - 4);
  return (5 + 95 * t.clamp(0.0, 1.0)).round();
}

/// 1 in [kBlindBoxCanvasOdds] blind boxes holds a Canvas edition.
const int kBlindBoxCanvasOdds = 100;

// ==================================================================== minigames
const int kMinigamePlaysPerDay = 3;

/// The most bits one round of a minigame can pay.
int minigameMaxBits(String game) => switch (game) {
      'song' => 5,
      'artist' => 5,
      'album' => 3,
      'trivia' => 3,
      _ => 0,
    };

const List<String> kMinigames = ['song', 'artist', 'album', 'trivia'];
