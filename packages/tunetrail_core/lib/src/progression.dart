import 'rarity.dart';

// ====================================================================== levels
/// Levels run from 1 to [kMaxLevel].
const int kMaxLevel = 100;

/// XP needed to go from [level] to the next: 200 for level 1 → 2, 3,700 for
/// 36 → 37, 10,000 for 99 → 100 (0 at the top level).
int xpToNextLevel(int level) => level >= kMaxLevel ? 0 : 100 * (level.clamp(1, kMaxLevel) + 1);

/// Total XP at which [level] is reached (0 for level 1).
int xpForLevel(int level) {
  final l = level.clamp(1, kMaxLevel);
  return 100 * (l * (l + 1) ~/ 2 - 1);
}

/// The level a total of [xp] gives.
int levelForXp(int xp) {
  var l = 1;
  while (l < kMaxLevel && xp >= xpForLevel(l + 1)) {
    l++;
  }
  return l;
}

// ========================================================================== XP
const List<int> _kCatchXp = [5, 10, 20, 50, 100];

/// XP for catching a song: by rarity, ×5 for a Shiny; 1,000 for a Canvas
/// and 2,000 for a Sample or Live edition.
int catchXp(Rarity r, {bool shiny = false, Edition edition = Edition.standard}) => switch (edition) {
      Edition.canvas => 1000,
      Edition.sample || Edition.live => 2000,
      Edition.standard => _kCatchXp[r.index] * (shiny ? 5 : 1),
    };

/// XP for each side of a completed trade.
const int kTradeXp = 10;

/// XP for every player in a won DJ battle.
const int kDjBattleXp = 100;

/// XP for bits won in a minigame.
int minigameXp(int bits) => bits * 5;

// ===================================================================== bonuses
/// Permanent account bonuses, one chosen every [kLevelsPerBonus] levels.
enum Bonus {
  scrap('Scrapyard value', '+5% coins from scrapping songs'),
  spawn('Song spawn rate', '+5% more songs around you'),
  xp('XP yield', '+5% XP from everything'),
  rarity('Rarity', '+5% Uncommon, +4% Rare, +3% Epic, +2% Legendary and +1% Shiny chance');

  const Bonus(this.label, this.description);
  final String label;
  final String description;

  static Bonus? byName(String? n) {
    for (final b in values) {
      if (b.name == n) return b;
    }
    return null;
  }
}

const int kLevelsPerBonus = 5;

/// Bits it costs to take every chosen bonus back and choose again.
const int kRespecBits = 100;

/// Bonus choices a level has earned in total.
int bonusChoicesAt(int level) => level ~/ kLevelsPerBonus;

/// A player's bonuses: the ones they chose (limited by their level) plus
/// any an admin added or took away.
class Bonuses {
  Bonuses({Map<Bonus, int>? chosen, Map<Bonus, int>? granted})
      : chosen = chosen ?? {},
        granted = granted ?? {};
  final Map<Bonus, int> chosen;
  final Map<Bonus, int> granted;

  int get chosenTotal => chosen.values.fold(0, (a, b) => a + b);

  /// How many times a bonus applies (never below zero).
  int of(Bonus b) {
    final n = (chosen[b] ?? 0) + (granted[b] ?? 0);
    return n < 0 ? 0 : n;
  }

  /// Choices still to make at [level].
  int unspent(int level) {
    final n = bonusChoicesAt(level) - chosenTotal;
    return n < 0 ? 0 : n;
  }

  double get scrapMultiplier => 1 + 0.05 * of(Bonus.scrap);
  double get spawnMultiplier => 1 + 0.05 * of(Bonus.spawn);
  double get xpMultiplier => 1 + 0.05 * of(Bonus.xp);
  double get shinyMultiplier => 1 + 0.01 * of(Bonus.rarity);

  /// Multipliers on the spawn weight of each rarity (common first).
  List<double> get rarityWeights {
    final n = of(Bonus.rarity);
    return [1, 1 + 0.05 * n, 1 + 0.04 * n, 1 + 0.03 * n, 1 + 0.02 * n];
  }

  int scaleXp(int xp) => (xp * xpMultiplier).round();
  int scaleScrap(int coins) => (coins * scrapMultiplier).round();

  Map<String, dynamic> toJson() => {
        'chosen': {for (final e in chosen.entries) if (e.value != 0) e.key.name: e.value},
        'granted': {for (final e in granted.entries) if (e.value != 0) e.key.name: e.value},
      };

  factory Bonuses.fromJson(Map<String, dynamic>? j) {
    Map<Bonus, int> read(Object? m) => {
          if (m is Map)
            for (final e in m.entries)
              if (Bonus.byName('${e.key}') != null && e.value is num) Bonus.byName('${e.key}')!: (e.value as num).toInt(),
        };
    return Bonuses(chosen: read(j?['chosen']), granted: read(j?['granted']));
  }
}
