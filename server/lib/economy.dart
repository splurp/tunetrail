import 'dart:math' as math;

import 'package:tunetrail_core/tunetrail_core.dart';

import 'catalog.dart';

part 'economy_world.dart';

/// One change to a player's cards (for syncing games).
class _CardChange {
  _CardChange(this.rev, {this.added, this.removed});
  final int rev;
  final CardPayload? added;
  final int? removed;
}

/// A cheat flag for an admin to review.
class CheatFlag {
  CheatFlag(this.kind, this.detail, this.at);
  final String kind;
  final String detail;
  final int at;

  Map<String, dynamic> toJson() => {'k': kind, 'd': detail, 'at': at};
  factory CheatFlag.fromJson(Map<String, dynamic> j) => CheatFlag(j['k'] as String? ?? '', j['d'] as String? ?? '', (j['at'] as num?)?.toInt() ?? 0);
}

/// What the server holds for one player once their progress lives on the
/// server: balances, items, cards and the state of the world around them.
class Account {
  Account(this.id, {required this.createdAt});
  final String id;
  int createdAt;
  bool imported = false;

  int coins = 0;
  int bits = 0;
  int xp = 0;
  final Set<String> owned = {};
  int usernameChanges = 0;

  /// Cards by uid (in the order they were added).
  final Map<int, CardPayload> cards = {};
  final Map<String, int> _variants = {};
  int lastUid = 0;

  /// Bumped on every card change; games send the one they've seen.
  int rev = 0;
  final List<_CardChange> _log = [];

  /// Counters (catches, packs, distance…) shown on profiles and used by
  /// quests and cheat checks.
  final Map<String, num> stats = {};

  // World state.
  final Map<String, int> spent = {}; // spawn id → expiry (ms)
  final Map<String, int> purchased = {}; // spawn id → expiry
  final Map<String, int> throws = {}; // spawn id → throws so far
  final Map<String, WorldSpawn> memo = {}; // spawns as first shown

  /// Spawn spots caught today: "cx:cy:day:slot" → (next song's generation,
  /// when it appears).
  final Map<String, (int, int)> slots = {};

  /// The ground of each cell for the day ("cx:cy:day"), as first reported.
  final Map<String, CellGround> grounds = {};

  /// The terrain of each cell for the day ("cx:cy:day"), as first reported.
  final Map<String, CellTerrain> terrains = {};

  /// Glowing features used up today ("cx:cy:square:day").
  final Set<String> claimedFeatures = {};

  /// The treasure map the player holds.
  Treasure? treasure;

  /// DJs that won't battle this player again until a time (DJ id → ms).
  final Map<String, int> djDone = {};

  /// DJs an admin summoned for this player.
  final List<DjNpc> summonedDjs = [];
  double? lat, lng;
  int locAt = 0;
  double heading = 0;

  /// Whether nearby players see this player on their map.
  bool showOnMap = true;

  /// Admin testing: every tap on the catch / battle ring is perfect.
  bool perfectRing = false;

  /// An admin moved this player: where to, and when ({lat, lng, at}).
  Map<String, dynamic>? teleport;

  /// Until then, a jump in position isn't flagged (an admin moved them).
  int travelGraceUntil = 0;

  /// Level bonuses (chosen and admin-given).
  Bonuses bonuses = Bonuses();
  int get level => levelForXp(xp);

  // Days (pinned time-zone offset).
  int? tz;
  int tzAt = 0;

  // Quests.
  String questDay = '';
  final Map<String, int> questProgress = {};
  final Set<String> questsClaimed = {};

  // Minigames: plays per day, and bits paid in each game's open round.
  final Map<String, (String, int)> plays = {};
  final Map<String, int> roundBits = {};

  // Recent throw times (bot checks).
  final List<int> recentThrows = [];

  final List<CheatFlag> flags = [];

  /// What admins gave this player: {by, what, at}.
  final List<Map<String, dynamic>> adminLog = [];
  int flagsSeen = 0;

  static String variantOf(CardPayload c) => '${c.songId}:${c.rarity.index}:${c.shiny ? 1 : 0}:${c.edition.index}';

  bool ownsVariant(CardPayload c) => (_variants[variantOf(c)] ?? 0) > 0;
  bool ownsSong(int songId) => cards.values.any((c) => c.songId == songId);

  int newUid() {
    var id = math.max(DateTime.now().microsecondsSinceEpoch * 1000, lastUid + 1);
    while (cards.containsKey(id)) {
      id++;
    }
    return lastUid = id;
  }

  CardPayload addCard(CardPayload c, {bool keepUid = true}) {
    final card = keepUid && c.uid > 0 && !cards.containsKey(c.uid) ? c : c.withUid(newUid());
    if (card.uid > lastUid) lastUid = card.uid;
    cards[card.uid] = card;
    _variants.update(variantOf(card), (n) => n + 1, ifAbsent: () => 1);
    rev++;
    _log.add(_CardChange(rev, added: card));
    _trimLog();
    return card;
  }

  CardPayload? removeCard(int uid) {
    final c = cards.remove(uid);
    if (c == null) return null;
    final k = variantOf(c);
    final n = (_variants[k] ?? 1) - 1;
    n <= 0 ? _variants.remove(k) : _variants[k] = n;
    rev++;
    _log.add(_CardChange(rev, removed: uid));
    _trimLog();
    return c;
  }

  void _trimLog() {
    if (_log.length > 3000) _log.removeRange(0, _log.length - 2000);
  }

  /// Card changes since [since] — null when the game must fetch everything.
  ({List<CardPayload> added, List<int> removed})? changesSince(int since) {
    if (since == rev) return (added: const [], removed: const []);
    if (since > rev || _log.isEmpty || _log.first.rev > since + 1) return null;
    final added = <int, CardPayload>{};
    final removed = <int>{};
    for (final ch in _log) {
      if (ch.rev <= since) continue;
      if (ch.added != null) {
        added[ch.added!.uid] = ch.added!;
        removed.remove(ch.added!.uid);
      }
      if (ch.removed != null) {
        if (added.remove(ch.removed) == null) removed.add(ch.removed!);
      }
    }
    return (added: added.values.toList(), removed: removed.toList());
  }

  void stat(String k, num by) => stats[k] = (stats[k] ?? 0) + by;
  int statInt(String k) => (stats[k] ?? 0).toInt();

  Map<String, dynamic> toJson() => {
        'id': id,
        'created': createdAt,
        'imported': imported,
        'coins': coins,
        'bits': bits,
        'xp': xp,
        'owned': owned.toList(),
        'unc': usernameChanges,
        'lastUid': lastUid,
        'rev': rev,
        'stats': stats,
        'spent': spent,
        'purchased': purchased,
        'slots': {for (final e in slots.entries) e.key: [e.value.$1, e.value.$2]},
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        'locAt': locAt,
        if (tz != null) 'tz': tz,
        'tzAt': tzAt,
        'qd': questDay,
        'qp': questProgress,
        'qc': questsClaimed.toList(),
        'plays': {for (final e in plays.entries) e.key: [e.value.$1, e.value.$2]},
        'round': roundBits,
        'flags': [for (final f in flags) f.toJson()],
        'adminLog': adminLog,
        'flagsSeen': flagsSeen,
        'bonuses': bonuses.toJson(),
        'claimedF': claimedFeatures.toList(),
        if (treasure != null) 'treasure': treasure!.toJson(),
        'djDone': djDone,
        if (!showOnMap) 'hidden': true,
        if (perfectRing) 'perfect': true,
        'teleport': ?teleport,
        if (travelGraceUntil > 0) 'grace': travelGraceUntil,
      };

  factory Account.fromJson(Map<String, dynamic> j, List<CardPayload> cards) {
    final a = Account(j['id'] as String, createdAt: (j['created'] as num?)?.toInt() ?? 0)
      ..imported = j['imported'] as bool? ?? false
      ..coins = (j['coins'] as num?)?.toInt() ?? 0
      ..bits = (j['bits'] as num?)?.toInt() ?? 0
      ..xp = (j['xp'] as num?)?.toInt() ?? 0
      ..usernameChanges = (j['unc'] as num?)?.toInt() ?? 0
      ..lat = (j['lat'] as num?)?.toDouble()
      ..lng = (j['lng'] as num?)?.toDouble()
      ..locAt = (j['locAt'] as num?)?.toInt() ?? 0
      ..tz = (j['tz'] as num?)?.toInt()
      ..tzAt = (j['tzAt'] as num?)?.toInt() ?? 0
      ..questDay = j['qd'] as String? ?? ''
      ..flagsSeen = (j['flagsSeen'] as num?)?.toInt() ?? 0;
    a.owned.addAll([for (final x in (j['owned'] as List? ?? const [])) '$x']);
    for (final c in cards) {
      a.cards[c.uid] = c;
      a._variants.update(variantOf(c), (n) => n + 1, ifAbsent: () => 1);
    }
    a.lastUid = math.max((j['lastUid'] as num?)?.toInt() ?? 0, cards.fold<int>(0, (m, c) => math.max(m, c.uid)));
    a.rev = (j['rev'] as num?)?.toInt() ?? 0;
    (j['stats'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => a.stats[k] = v as num);
    (j['spent'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => a.spent[k] = (v as num).toInt());
    (j['purchased'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => a.purchased[k] = (v as num).toInt());
    (j['slots'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final l = v as List;
      a.slots[k] = ((l[0] as num).toInt(), (l[1] as num).toInt());
    });
    (j['qp'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => a.questProgress[k] = (v as num).toInt());
    a.questsClaimed.addAll([for (final x in (j['qc'] as List? ?? const [])) '$x']);
    (j['plays'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final l = v as List;
      a.plays[k] = (l[0] as String, (l[1] as num).toInt());
    });
    (j['round'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => a.roundBits[k] = (v as num).toInt());
    a.flags.addAll([for (final f in (j['flags'] as List? ?? const [])) CheatFlag.fromJson(f as Map<String, dynamic>)]);
    a.adminLog.addAll([for (final x in (j['adminLog'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)]);
    a.bonuses = Bonuses.fromJson(j['bonuses'] as Map<String, dynamic>?);
    a.claimedFeatures.addAll([for (final x in (j['claimedF'] as List? ?? const [])) '$x']);
    if (j['treasure'] is Map<String, dynamic>) a.treasure = Treasure.fromJson(j['treasure'] as Map<String, dynamic>);
    (j['djDone'] as Map<String, dynamic>? ?? const {}).forEach((k, v) => a.djDone[k] = (v as num).toInt());
    a.showOnMap = j['hidden'] != true;
    a.perfectRing = j['perfect'] == true;
    a.teleport = j['teleport'] as Map<String, dynamic>?;
    a.travelGraceUntil = (j['grace'] as num?)?.toInt() ?? 0;
    return a;
  }
}

/// The result of one throw at a spawn.
class ThrowResult {
  ThrowResult(this.result, {this.card, this.dupCoins = 0, this.note, this.coins = 0, this.xp = 0});

  /// "caught", "slipped" or "fled".
  final String result;
  final CardPayload? card;
  final int dupCoins;
  final String? note;
  final int coins;
  final int xp;

  Map<String, dynamic> toJson() => {
        'result': result,
        if (card != null) 'card': card!.toJson(),
        if (dupCoins > 0) 'dupCoins': dupCoins,
        if (note != null) 'note': note,
        if (coins > 0) 'coins': coins,
        if (xp > 0) 'xp': xp,
      };
}

/// Server-side balances, collections, spawns, packs, shop, quests and
/// minigames. Games ask; the server decides and answers with the new state.
class Economy {
  Economy({required this.engine, required this.catalog, required this.seed, Set<String>? admins, int Function()? clock, math.Random? random})
      : admins = admins ?? {},
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        rng = random ?? math.Random.secure();

  final MarketEngine engine;
  final ServerCatalog catalog;
  final int seed;
  final Set<String> admins;
  final int Function() _clock;
  final math.Random rng;

  final Map<String, Account> accounts = {};

  /// Each player's collection as their pre-server game last uploaded it
  /// (for restoring cards lost in the switch).
  final Map<String, List<CardPayload>> legacy = {};

  /// Accounts with unsaved changes, and their card changes since the last
  /// save (or a full rewrite).
  final Set<String> dirty = {};
  final Map<String, Map<int, CardPayload?>> pendingCards = {};
  final Set<String> rewriteCards = {};

  /// The world's DJs, the same for every player: worked out once per cell
  /// and day (from the first ground map the server gets for it), plus the
  /// ones admins summon. By id.
  final Map<String, DjNpc> worldDjs = {};

  /// Cells and days known to have no DJ ("dj:cx:cy:day").
  final Set<String> noDj = {};

  /// DJs someone beat: gone for everyone until then (ms). Kept across
  /// restarts.
  final Map<String, int> defeatedDjs = {};

  /// DJ battles going on (and just finished), by id.
  final Map<String, Battle> battles = {};
  int _battleCounter = 0;

  /// Players whose position was updated lately (id → ms), for showing
  /// players to each other.
  final Map<String, int> _active = {};
  List<SongInfo>? _djSongs;
  SongPool? _djSongsPool;

  int now() => _clock();

  /// Adds XP (with the player's XP bonus). Returns what was added.
  int _xp(Account a, int base) {
    if (base <= 0) return 0;
    final xp = a.bonuses.scaleXp(base);
    a.xp += xp;
    return xp;
  }

  /// Hooks the market up: sale proceeds, returned cards and trades go
  /// straight into accounts.
  void attach() {
    engine.onDeliver = (id, coins, cards) {
      final a = accounts[id];
      if (a == null || !a.imported) return false;
      a.coins += coins;
      for (final c in cards) {
        _add(a, c);
      }
      touch(a);
      return true;
    };
    engine.cardOf = (id, uid) {
      final a = accounts[id];
      return a == null || !a.imported ? null : a.cards[uid];
    };
    engine.onTradeCompleted = (x, y) {
      for (final id in {x, y}) {
        final a = accounts[id];
        if (a == null || !a.imported) continue;
        _xp(a, kTradeXp);
        a.stat('trades', 1);
        touch(a);
      }
    };
    engine.onTake = (id, cards) {
      final a = accounts[id];
      if (a == null || !a.imported) return true;
      if (!cards.every((c) => a.cards.containsKey(c.uid))) return false;
      for (final c in cards) {
        _remove(a, c.uid);
      }
      touch(a);
      return true;
    };
  }

  bool active(String id) => accounts[id]?.imported ?? false;

  /// The player's account; their progress must have been moved to the
  /// server first (the game does that once, by itself).
  Account account(String id) {
    final a = accounts[id];
    if (a == null || !a.imported) throw MarketException('Your progress is still being set up on the server — try again in a moment');
    return a;
  }

  void touch(Account a) {
    dirty.add(a.id);
    _publish(a);
  }

  CardPayload _add(Account a, CardPayload c, {bool keepUid = true}) {
    final card = a.addCard(c, keepUid: keepUid);
    pendingCards.putIfAbsent(a.id, () => {})[card.uid] = card;
    return card;
  }

  CardPayload? _remove(Account a, int uid) {
    final c = a.removeCard(uid);
    if (c != null) pendingCards.putIfAbsent(a.id, () => {})[uid] = null;
    return c;
  }

  /// Keeps the market's view of the collection (what other players browse
  /// and request in trades) in step with the account.
  void _publish(Account a) {
    engine.collections[a.id] = a.cards.values.toList();
  }

  // ------------------------------------------------------------------- sync
  /// Balances, items and card changes since [sinceRev] for the game.
  Map<String, dynamic> sync(Account a, int? sinceRev) {
    final ch = sinceRev == null ? null : a.changesSince(sinceRev);
    return {
      'rev': a.rev,
      'coins': a.coins,
      'bits': a.bits,
      'xp': a.xp,
      'owned': a.owned.toList(),
      'stats': a.stats,
      'unc': a.usernameChanges,
      'bonuses': a.bonuses.toJson(),
      'treasure': a.treasure?.toJson(),
      'onMap': a.showOnMap,
      'perfect': a.perfectRing,
      'teleport': a.teleport,
      if (ch == null) 'full': true else ...{
        if (ch.added.isNotEmpty) 'add': [for (final c in ch.added) c.toJson()],
        if (ch.removed.isNotEmpty) 'del': ch.removed,
      },
    };
  }

  // ----------------------------------------------------------------- import
  /// Moves a player's existing progress to the server — once.
  Account import(String id, Map<String, dynamic> b) {
    final existing = accounts[id];
    if (existing != null && existing.imported) throw MarketException('Your progress is already on the server');
    final a = Account(id, createdAt: now());
    final old = engine.collections[id];
    if (old != null && old.isNotEmpty) legacy[id] ??= List.of(old);
    int num0(String k, int max) => ((b[k] as num?)?.toInt() ?? 0).clamp(0, max);
    a
      ..coins = num0('coins', 2000000000)
      ..bits = num0('bits', 2000000000)
      ..xp = num0('xp', 2000000000)
      ..usernameChanges = num0('unc', 1000);
    for (final o in (b['owned'] as List? ?? const [])) {
      if (shopItem('$o') != null) a.owned.add('$o');
    }
    // Milestones, spotlights and albums already claimed stay claimed.
    for (final q in (b['claimed'] as List? ?? const [])) {
      final id = '$q';
      if (id.length < 80 && (id.startsWith('m_') || id.startsWith('u_') || id.startsWith('a_'))) a.questsClaimed.add(id);
    }
    (b['stats'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      if (v is num && k.length < 40 && a.stats.length < 50) a.stats[k] = v;
    });
    final pool = catalog.songs.isEmpty ? null : catalog.freshPool;
    final list = b['cards'] as List? ?? const [];
    if (list.length > MarketEngine.kMaxCollection) throw MarketException('Too many cards');
    for (final raw in list) {
      var c = CardPayload.fromJson(raw as Map<String, dynamic>);
      // A song has one rarity: the server's, where it knows the song.
      if (pool != null && catalog.songs.containsKey(c.songId)) {
        final r = pool.rarityOf(c.songId);
        if (r != c.rarity) c = _withRarity(c, r);
      }
      if (c.edition != Edition.standard && c.serial <= 0) c = _asStandard(c);
      a.addCard(c);
    }
    a.rev = 1;
    a._log.clear();
    a.imported = true;
    accounts[id] = a;
    rewriteCards.add(id);
    pendingCards.remove(id);
    if (a.coins > 5000000 || a.bits > 100000 || list.length > 20000) {
      _flag(a, 'big_import', '${a.coins} coins, ${a.bits} bits, ${list.length} cards');
    }
    touch(a);
    return a;
  }

  static CardPayload _withRarity(CardPayload c, Rarity r) => CardPayload.fromJson({...c.toJson(), 'rarity': r.index});
  static CardPayload _asStandard(CardPayload c) => CardPayload.fromJson({...c.toJson()}..remove('ed')..remove('sn'));

  // ----------------------------------------------------------------- flags
  void _flag(Account a, String kind, String detail) {
    if (admins.contains(a.id)) return;
    // An admin turned on perfect accuracy for testing.
    if (a.perfectRing && (kind == 'perfect_rate' || kind == 'dj_accuracy')) return;
    final t = now();
    // One flag of a kind per hour is enough.
    if (a.flags.any((f) => f.kind == kind && t - f.at < 3600000)) return;
    a.flags.add(CheatFlag(kind, detail, t));
    if (a.flags.length > 200) a.flags.removeAt(0);
    dirty.add(a.id);
  }

  /// Accounts with flags an admin hasn't cleared.
  List<Map<String, dynamic>> flagged() {
    final out = <Map<String, dynamic>>[];
    for (final a in accounts.values) {
      final open = a.flags.skip(a.flagsSeen.clamp(0, a.flags.length)).toList();
      if (open.isEmpty) continue;
      out.add({
        'id': a.id,
        'name': engine.nameOf(a.id),
        'flags': [for (final f in open) f.toJson()],
        'coins': a.coins,
        'bits': a.bits,
        'cards': a.cards.length,
        'stats': a.stats,
      });
    }
    out.sort((x, y) => ((y['flags'] as List).last['at'] as int).compareTo((x['flags'] as List).last['at'] as int));
    return out;
  }

  void clearFlags(String id) {
    final a = accounts[id];
    if (a == null) return;
    a.flagsSeen = a.flags.length;
    dirty.add(id);
  }

  // ------------------------------------------------------------------ days
  /// Pins the player's time-zone offset (a new one is only accepted 20 h
  /// after the last, so hopping time zones can't add days). Returns today.
  String today(Account a, int? tz) {
    final t = now();
    if (tz != null && tz.abs() <= 14 * 60) {
      if (a.tz == null || (a.tz != tz && t - a.tzAt > kTzRepinMs)) {
        a
          ..tz = tz
          ..tzAt = t;
        dirty.add(a.id);
      }
    }
    final day = dayKeyAt(t, a.tz ?? 0);
    if (a.questDay != day) {
      a.questDay = day;
      a.questProgress.removeWhere((k, _) => k.startsWith('d_'));
      a.questsClaimed.removeWhere((k) => k.startsWith('d_'));
      dirty.add(a.id);
    }
    return day;
  }

  void _questEvent(Account a, QuestKind kind, {int amount = 1, int? genreId}) {
    for (final q in dailyQuests(a)) {
      if (q.kind != kind) continue;
      if (kind == QuestKind.catchGenre && q.genreId != genreId) continue;
      a.questProgress[q.id] = (a.questProgress[q.id] ?? 0) + amount;
    }
  }

  // ------------------------------------------------------------- location
  /// Records where the player is. Walking counts towards distance (and the
  /// walking quest); jumps no person could make are flagged.
  void _moveTo(Account a, double lat, double lng) {
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) throw MarketException('Invalid position');
    final t = now();
    if (a.lat != null && a.lng != null) {
      final d = distanceMeters(a.lat!, a.lng!, lat, lng);
      final secs = math.max(1, (t - a.locAt) / 1000);
      final speed = d / secs;
      if (d > 1000 && speed > 80 && t > a.travelGraceUntil) {
        _flag(a, 'impossible_travel', '${(d / 1000).toStringAsFixed(1)} km in ${secs.round()} s');
      } else if (d >= 3 && speed <= 7) {
        a.stat('meters', d);
        _questEvent(a, QuestKind.walkMeters, amount: d.round());
      }
    }
    a
      ..lat = lat
      ..lng = lng
      ..locAt = t;
    _active[a.id] = t;
    // An admin's move has happened (or is too old to still be waiting for).
    final tp = a.teleport;
    if (tp != null &&
        (t - ((tp['at'] as num?)?.toInt() ?? 0) > 10 * 60000 || distanceMeters(lat, lng, (tp['lat'] as num).toDouble(), (tp['lng'] as num).toDouble()) < 300)) {
      a.teleport = null;
    }
    // A treasure map is lost by straying too far from where it was found.
    final tr = a.treasure;
    if (tr != null && distanceMeters(lat, lng, tr.fromLat, tr.fromLng) > kTreasureMaxMeters) a.treasure = null;
    dirty.add(a.id);
  }

  // ---------------------------------------------------------------- spawns
  WorldSpawner get _spawner => WorldSpawner(catalog.pool, seed: seed, sampleSongs: kSampleSongs);

  Set<int> _favorites(String id) => {for (final f in engine.players[id]?.favoriteArtists ?? const <FavoriteArtist>[]) f.id};

  /// Spawns around a position. [grounds] are the cells' ground maps
  /// ("cx:cy" → [CellGround] code) and [zones] their genre multipliers
  /// ("cx:cy" → genre → multiplier), both from the game's map data. A cell
  /// keeps the first ground map it got for the day (so it can't be
  /// re-rolled); cells without one have no spawns yet.
  List<Map<String, dynamic>> spawnsAround(String id, double lat, double lng,
      {int? tz, Map<String, Map<int, double>> zones = const {}, Map<String, String> grounds = const {}, Map<String, String> terrains = const {}}) {
    final a = account(id);
    _moveTo(a, lat, lng);
    today(a, tz);
    final t = now();
    final offset = a.tz ?? tz ?? 0;
    final d = WorldSpawner.dayAt(t, offset);
    final dayEnd = WorldSpawner.dayEndMs(d, offset);
    a.spent.removeWhere((_, exp) => exp < t);
    a.purchased.removeWhere((_, exp) => exp < t);
    a.memo.removeWhere((_, s) => s.expiresAt < t);
    a.throws.removeWhere((k, _) => !a.memo.containsKey(k));
    a.grounds.removeWhere((k, _) => !k.endsWith(':$d'));
    a.terrains.removeWhere((k, _) => !k.endsWith(':$d'));
    a.claimedFeatures.removeWhere((k) => !k.endsWith(':$d'));
    a.slots.removeWhere((k, _) => k.split(':')[2] != '$d');
    for (final e in terrains.entries) {
      final k = '${e.key}:$d';
      if (a.terrains.containsKey(k) || a.terrains.length > 400) continue;
      final t = CellTerrain.parse(e.value);
      if (t != null) a.terrains[k] = t;
    }
    if (catalog.songs.isEmpty) return const [];
    final hour = DateTime.fromMillisecondsSinceEpoch(t + offset * 60000, isUtc: true).hour;
    final timeBias = timeOfDayBias(hour);
    final favs = _favorites(id);
    final spawner = _spawner;
    final out = <Map<String, dynamic>>[];
    final rate = a.bonuses.spawnMultiplier;
    final rarityBoost = a.bonuses.rarityWeights;
    final shinyBoost = a.bonuses.shinyMultiplier;
    for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng)) {
      final gk = '$cx:$cy:$d';
      var ground = a.grounds[gk];
      if (ground == null) {
        final code = grounds['$cx:$cy'];
        ground = code == null ? null : CellGround.parse(code);
        if (ground == null) continue;
        a.grounds[gk] = ground;
      }
      final spots = [
        ...spawner.spots(cx, cy, d, ground, rate: rate),
        // Glowing bushes and saplings are nests: more songs around them.
        ..._nestSpots(a, cx, cy, d, ground),
      ];
      for (final (slot, sLat, sLng) in spots) {
        final key = WorldSpawner.slotKey(cx, cy, d, slot);
        final st = a.slots[key];
        if (st != null && st.$2 > t) continue; // a new song appears an hour after a catch
        final sid = '$key:${st?.$1 ?? 0}';
        if (a.spent.containsKey(sid)) continue;
        var spawn = a.memo[sid];
        if (spawn == null) {
          final made = spawner.spawnAt(cx, cy, d, slot, st?.$1 ?? 0, sLat, sLng,
              expiresAt: dayEnd,
              favorites: favs,
              bias: combineBias(timeBias, zones['$cx:$cy'] ?? const {}),
              rarityBoost: rarityBoost,
              shinyBoost: shinyBoost);
          if (made == null) continue;
          // A spawn keeps what it first showed until the day ends.
          spawn = a.memo[sid] = made;
        }
        if (spawn.edition != Edition.standard && engine.serialsLeft(spawn.song.id, spawn.edition) <= 0) {
          spawn = a.memo[sid] = _downgrade(spawn);
        }
        out.add({...spawn.toJson(), if (a.purchased.containsKey(sid)) 'paid': true});
      }
    }
    for (final s in a.memo.values.where((s) => s.id.startsWith('debug:'))) {
      if (!a.spent.containsKey(s.id)) out.add({...s.toJson(), if (a.purchased.containsKey(s.id)) 'paid': true});
    }
    return out;
  }

  /// A spawn was caught or got away: its spot gets a new song in an hour.
  void _retire(Account a, WorldSpawn s) {
    a.spent[s.id] = s.expiresAt + 60000;
    a.purchased.remove(s.id);
    final p = s.id.split(':');
    if (p.length == 5 && !s.id.startsWith('debug:')) {
      final gen = int.tryParse(p[4]) ?? 0;
      a.slots[p.take(4).join(':')] = (gen + 1, now() + WorldSpawner.respawn.inMilliseconds);
    }
  }

  static WorldSpawn _downgrade(WorldSpawn s) => WorldSpawn(
        id: s.id,
        lat: s.lat,
        lng: s.lng,
        song: s.song,
        rarity: s.rarity,
        shiny: false,
        edition: Edition.standard,
        expiresAt: s.expiresAt,
      );

  WorldSpawn _spawn(Account a, String spawnId) {
    final s = a.memo[spawnId];
    if (s == null || s.expiresAt < now()) throw MarketException('That song has moved on — look around for another');
    if (a.spent.containsKey(spawnId)) throw MarketException('That song is gone');
    return s;
  }

  /// Pays coins for an out-of-range spawn; it can then be caught from here
  /// (and can't get away).
  int buySpawn(String id, String spawnId, double lat, double lng) {
    final a = account(id);
    _moveTo(a, lat, lng);
    final s = _spawn(a, spawnId);
    if (a.purchased.containsKey(spawnId)) return 0;
    final price = spawnPrice(s.rarity, distanceMeters(lat, lng, s.lat, s.lng), shiny: s.shiny, edition: s.edition);
    if (price == null) throw MarketException('This song can\'t be bought — go and catch it');
    if (a.coins < price) throw MarketException('Not enough coins ($price needed)');
    a.coins -= price;
    a.purchased[spawnId] = s.expiresAt + 60000;
    a.stat('spawnsBought', 1);
    touch(a);
    return price;
  }

  /// One throw at a spawn with [acc]% timing (100 = perfect: always caught,
  /// and shiny). The server rolls the catch.
  Future<ThrowResult> throwAt(String id, String spawnId, double lat, double lng, int acc, {bool unlimitedRange = false, bool noLiveFootage = false}) async {
    final a = account(id);
    _moveTo(a, lat, lng);
    final s = _spawn(a, spawnId);
    final t = now();
    final dist = distanceMeters(lat, lng, s.lat, s.lng);
    final paid = a.purchased.containsKey(spawnId);
    final admin = admins.contains(id) && unlimitedRange;
    if (!paid && !admin && dist > kCatchRangeMeters + kCatchRangeSlackMeters) {
      _flag(a, 'throw_out_of_range', '${dist.round()} m from ${s.song.title}');
      throw MarketException('You\'re too far away — walk closer');
    }
    acc = acc.clamp(0, 100);
    // Bot checks: inhumanly fast throws, and too many perfect beats.
    a.recentThrows
      ..add(t)
      ..removeWhere((x) => t - x > 60000);
    if (a.recentThrows.length > 40) _flag(a, 'rapid_throws', '${a.recentThrows.length} throws in a minute');
    a.stat('throws', 1);
    if (acc == 100) a.stat('perfect', 1);
    final throwsN = a.statInt('throws'), perfect = a.statInt('perfect');
    if (throwsN >= 50 && perfect / throwsN > 0.6) _flag(a, 'perfect_rate', '$perfect of $throwsN throws perfect');

    final n = (a.throws[spawnId] ?? 0) + 1;
    a.throws[spawnId] = n;
    final r = s.rarity;
    final success = acc == 100 || paid || rng.nextDouble() < catchChance(r, acc);
    if (!success) {
      if (n >= kMaxThrows || rng.nextDouble() < kFleeChance[r.index]) {
        _retire(a, s);
        touch(a);
        return ThrowResult('fled');
      }
      dirty.add(a.id);
      return ThrowResult('slipped');
    }
    // Caught.
    var edition = s.edition;
    if (edition == Edition.live && noLiveFootage) edition = Edition.standard;
    var serial = 0;
    String? note;
    if (edition != Edition.standard) {
      final claimed = engine.claimSerial(s.song.id, edition, song: s.song, playerId: id);
      if (claimed == null) {
        note = 'Every ${edition.label} edition of this song has been claimed — you caught a standard card.';
        edition = Edition.standard;
      } else {
        serial = claimed;
      }
    }
    // Editions are exclusive: a perfect catch only turns standard cards shiny.
    final shiny = edition == Edition.standard && (s.shiny || acc == 100);
    final card = s.song.toPayload(uid: 0, rarity: r, shiny: shiny, edition: edition, serial: serial, acquiredAt: t);
    final coins = r.catchCoins * (shiny ? 3 : 1);
    a.coins += coins;
    final xp = _xp(a, catchXp(r, shiny: shiny, edition: edition));
    a.stat('caught', 1);
    if (shiny) a.stat('shinies', 1);
    _questEvent(a, QuestKind.catchAny);
    _questEvent(a, QuestKind.catchGenre, genreId: s.song.genreId);
    if (r.index >= Rarity.rare.index) _questEvent(a, QuestKind.catchRarePlus);
    _retire(a, s);
    final (got, dup) = _give(a, card);
    touch(a);
    return ThrowResult('caught', card: got ?? card, dupCoins: dup, note: note, coins: coins, xp: xp);
  }

  /// Adds a card; a regular card whose variant the player already owns is
  /// scrapped for coins instead. Returns (the new card or null, coins).
  (CardPayload?, int) _give(Account a, CardPayload c) {
    if (c.edition == Edition.standard && a.ownsVariant(c)) {
      final coins = a.bonuses.scaleScrap(scrapValue(c.rarity, c.shiny, c.rank));
      a.coins += coins;
      a.stat('scrapped', 1);
      return (null, coins);
    }
    return (_add(a, c, keepUid: false), 0);
  }

  /// Admin: puts [song] a few metres from the player.
  Map<String, dynamic> debugSpawn(String id, SongInfo song, double lat, double lng, {bool shiny = false, Edition edition = Edition.standard, Rarity? rarity}) {
    if (!admins.contains(id)) throw MarketException('Admins only');
    final a = account(id);
    final r = rarity ?? (catalog.songs.containsKey(song.id) ? catalog.pool.rarityOf(song.id) : Rarity.common);
    final s = WorldSpawn(
      id: 'debug:${song.id}:${now()}',
      lat: lat,
      lng: lng,
      song: song,
      rarity: r,
      shiny: shiny && edition == Edition.standard,
      edition: edition,
      expiresAt: now() + 30 * 60000,
    );
    a.memo[s.id] = s;
    return s.toJson();
  }

  /// Serial-numbered cards anyone holds ("songId:edition:serial").
  Set<String> _heldSerials() => {
    for (final acc in accounts.values)
      for (final c in acc.cards.values)
        if (c.edition != Edition.standard && c.serial > 0) '${c.songId}:${c.edition.index}:${c.serial}',
    for (final l in engine.listings.values)
      for (final c in l.cards)
        if (c.edition != Edition.standard && c.serial > 0) '${c.songId}:${c.edition.index}:${c.serial}',
  };

  /// Adds [cards] the account doesn't have (by uid); numbered editions
  /// someone already holds are skipped. Returns how many were added.
  int _addMissing(Account a, Iterable<CardPayload> cards) {
    final held = _heldSerials();
    final pool = catalog.songs.isEmpty ? null : catalog.pool;
    var n = 0;
    for (var c in cards) {
      if (a.cards.containsKey(c.uid)) continue;
      if (c.edition != Edition.standard) {
        if (c.serial <= 0 || held.contains('${c.songId}:${c.edition.index}:${c.serial}')) continue;
      }
      if (pool != null && catalog.songs.containsKey(c.songId)) {
        final r = pool.rarityOf(c.songId);
        if (r != c.rarity) c = _withRarity(c, r);
      }
      _add(a, c);
      n++;
    }
    return n;
  }

  /// Admin: gives back the cards a player had before the server switch
  /// (from their old game's last uploaded collection) that they no longer
  /// have. Returns how many were restored.
  int adminRestoreLegacy(String adminId, String targetId) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    final a = accounts[targetId];
    if (a == null || !a.imported) throw MarketException('That player isn\'t on the server economy yet (they need to open the updated game once)');
    final old = legacy[targetId];
    if (old == null || old.isEmpty) throw MarketException('No collection from before the switch was found for this player');
    final n = _addMissing(a, old);
    _logAdmin(a, adminId, 'restored $n cards from before the server switch');
    if (n > 0) engine.notice(targetId, '$n cards from before the server switch were restored to your collection', title: 'Cards restored');
    touch(a);
    return n;
  }

  /// Progress a second device still had when it found the account already
  /// on the server: its cards, coins, bits, XP and items are added (a few
  /// times per account at most; flagged for review).
  Account merge(String id, Map<String, dynamic> b) {
    final a = account(id);
    if (a.statInt('merges') >= 3) throw MarketException('This account has already merged progress from other devices');
    int num0(String k, int max) => ((b[k] as num?)?.toInt() ?? 0).clamp(0, max);
    final coins = num0('coins', 100000000), bits = num0('bits', 10000000), xp = num0('xp', 100000000);
    a
      ..coins += coins
      ..bits += bits
      ..xp += xp;
    for (final o in (b['owned'] as List? ?? const [])) {
      if (shopItem('$o') != null) a.owned.add('$o');
    }
    final list = b['cards'] as List? ?? const [];
    if (list.length > MarketEngine.kMaxCollection) throw MarketException('Too many cards');
    final n = _addMissing(a, [for (final c in list) CardPayload.fromJson(c as Map<String, dynamic>)]);
    a.stat('merges', 1);
    final t = now();
    a.flags.add(CheatFlag('device_merge', 'merged another device: $n cards, $coins coins, $bits bits', t));
    dirty.add(a.id);
    touch(a);
    return a;
  }

  /// Admin: wipes a numbered card that no longer exists (lost with an
  /// uninstalled game, say) from every record and frees its number. Refused
  /// while anyone holds it. Returns how many records were removed.
  int adminPurgeSerial(String adminId, int songId, Edition edition, int serial) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    bool same(CardPayload c) => c.songId == songId && c.edition == edition && c.serial == serial;
    for (final a in accounts.values) {
      if (a.cards.values.any(same)) throw MarketException('${engine.nameOf(a.id)} still has this card');
    }
    var n = engine.purgeSerial(songId, edition, serial);
    for (final l in legacy.values) {
      final before = l.length;
      l.removeWhere(same);
      n += before - l.length;
    }
    final me = accounts[adminId];
    if (me != null) {
      _logAdmin(me, adminId, 'purged ${edition.label} #$serial of song $songId ($n records)');
      touch(me);
    }
    return n;
  }

  /// Admin: takes one card out of [targetId]'s collection, with no notice
  /// and no refund. Offers asking for it are returned, it leaves their
  /// showcases, and a numbered edition's serial is freed to be found
  /// again. Returns the card removed.
  CardPayload adminRemoveCard(String adminId, String targetId, int uid) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    final a = accounts[targetId];
    if (a == null || !a.imported) throw MarketException('No such player');
    final c = _remove(a, uid);
    if (c == null) throw MarketException("They don't have that card any more (it may be listed, up for auction or traded)");
    touch(a);
    engine.dropCard(targetId, c);
    // So restoring their pre-server cards can't bring it back.
    legacy[targetId]?.removeWhere((x) => x.uid == uid);
    var freed = false;
    if (c.edition.serialized && c.serial > 0) {
      bool same(CardPayload x) => x.songId == c.songId && x.edition == c.edition && x.serial == c.serial;
      if (!accounts.values.any((x) => x.cards.values.any(same))) {
        try {
          engine.purgeSerial(c.songId, c.edition, c.serial);
          freed = true;
        } on MarketException {
          // Still listed or offered somewhere: leave the number taken.
        }
      }
    }
    final what = '${c.title}${c.shiny ? ' (shiny)' : ''}${c.edition.serialized ? ' ${c.edition.label} #${c.serial}' : ''}';
    _logAdmin(a, adminId, 'removed $what${freed ? ' and freed its number' : ''}');
    final me = accounts[adminId];
    if (me != null && me != a) {
      _logAdmin(me, adminId, 'removed $what from ${engine.nameOf(targetId)}');
      touch(me);
    }
    return c;
  }

  /// Admin: gives back today's minigame rounds ([extra] > 0 adds rounds on
  /// top of the daily allowance).
  void adminMinigames(String adminId, String targetId, {int extra = 0}) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    final a = accounts[targetId];
    if (a == null || !a.imported) throw MarketException('That player isn\'t on the server economy yet (they need to open the updated game once)');
    final day = today(a, null);
    final rec = a.plays[_allGames];
    final used = rec != null && rec.$1 == day ? rec.$2 : 0;
    // Plays used can go below zero: that's rounds on top of the allowance.
    a.plays[_allGames] = (day, extra > 0 ? used - extra : 0);
    a.roundBits.clear();
    _logAdmin(a, adminId, extra > 0 ? 'gave $extra extra minigame rounds' : 'reset today\'s minigame rounds');
    engine.notice(targetId, extra > 0 ? 'You got $extra extra minigame rounds for today' : 'Your minigame rounds for today were reset', title: 'Minigames');
    touch(a);
  }

  void _logAdmin(Account a, String adminId, String what) {
    a.adminLog.add({'by': engine.nameOf(adminId), 'id': adminId, 'what': what, 'at': now()});
    if (a.adminLog.length > 200) a.adminLog.removeAt(0);
  }

  /// Admin: puts [song] 15–30 m from where [targetId] last was, with any
  /// rarity and variant. The player is told (their game then refreshes its
  /// spawns).
  Map<String, dynamic> adminSpawnFor(String adminId, String targetId, SongInfo song,
      {bool shiny = false, Edition edition = Edition.standard, Rarity? rarity}) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    final a = accounts[targetId];
    if (a == null || !a.imported) throw MarketException('That player isn\'t on the server economy yet (they need to open the updated game once)');
    final lat0 = a.lat, lng0 = a.lng;
    if (lat0 == null || lng0 == null) throw MarketException('No recent location for that player — they need to open the map first');
    final ang = rng.nextDouble() * 2 * math.pi, dist = 15 + rng.nextDouble() * 15;
    final lat = lat0 + math.cos(ang) * dist / 111132.95;
    final lng = lng0 + math.sin(ang) * dist / (111319.49 * math.cos(lat0 * math.pi / 180));
    final r = rarity ?? (catalog.songs.containsKey(song.id) ? catalog.pool.rarityOf(song.id) : Rarity.common);
    final s = WorldSpawn(
      id: 'debug:${song.id}:${now()}',
      lat: lat,
      lng: lng,
      song: song,
      rarity: r,
      shiny: shiny && edition == Edition.standard,
      edition: edition,
      expiresAt: now() + 60 * 60000,
    );
    a.memo[s.id] = s;
    final what = edition != Edition.standard ? '${edition.label} edition' : '${shiny ? 'shiny ' : ''}${r.label}';
    _logAdmin(a, adminId, 'spawned ${song.title} ($what)');
    engine.notice(targetId, 'A special song appeared near you: ${song.title} by ${song.artistName} ($what) — it stays for an hour', title: 'A song appeared near you');
    touch(a);
    return s.toJson();
  }

  /// Admin: gives [targetId] a shop item (free — e.g. paid outside the app
  /// stores) and/or coins and bits. Returns what was given.
  String adminGrant(String adminId, String targetId, {String? item, String? label, int coins = 0, int bits = 0}) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    final a = accounts[targetId];
    if (a == null || !a.imported) throw MarketException('That player isn\'t on the server economy yet (they need to open the updated game once)');
    if (coins < 0 || bits < 0 || coins > 100000000 || bits > 10000000) throw MarketException('Invalid amount');
    final given = <String>[];
    if (item != null && item.isNotEmpty) {
      final it = shopItem(item);
      if (it == null) throw MarketException('Unknown item');
      if (it.kind == ShopKind.bits) {
        a.bits += it.bits;
        given.add('${it.bits} bits');
      } else {
        a.owned.add(item);
        if (it.bundleOf != null) a.owned.addAll(shopIdsOfKind(it.bundleOf!));
        // The game sends the item's display name ("Aurora") for the notice.
        final name = label == null ? '' : cleanUserText(label, maxLength: 60);
        given.add(name.isEmpty ? item : name);
      }
    }
    if (coins > 0) {
      a.coins += coins;
      given.add('$coins coins');
    }
    if (bits > 0) {
      a.bits += bits;
      given.add('$bits bits');
    }
    if (given.isEmpty) throw MarketException('Nothing to give');
    final what = given.join(', ');
    _logAdmin(a, adminId, 'gave $what');
    engine.notice(targetId, 'You received a gift: $what', title: 'You received a gift');
    touch(a);
    return what;
  }

  // ----------------------------------------------------------------- packs
  /// Opens a pack bought with bits. Returns each card (null = an owned
  /// variant, scrapped for the coins given).
  List<(CardPayload, CardPayload?, int)> openPack(String id, String packId) {
    final a = account(id);
    final p = packRules(packId);
    if (p == null) throw MarketException('Unknown pack');
    if (catalog.songs.isEmpty) throw MarketException('The song catalogue is still loading — try again soon');
    if (a.bits < p.bits) throw MarketException('Not enough bits');
    a.bits -= p.bits;
    final rolls = rollPack(catalog.pool, p, Rng(rng.nextInt(1 << 32) ^ (now() << 20)), favorites: _favorites(id));
    final out = <(CardPayload, CardPayload?, int)>[];
    for (final r in rolls) {
      var ed = Edition.standard;
      var serial = 0;
      if (r.canvas) {
        final n = engine.claimSerial(r.song.id, Edition.canvas, song: r.song, playerId: id);
        if (n != null) {
          ed = Edition.canvas;
          serial = n;
        }
      }
      final card = r.song.toPayload(uid: 0, rarity: catalog.pool.rarityOf(r.song.id), shiny: r.shiny && ed == Edition.standard, edition: ed, serial: serial, acquiredAt: now());
      final (got, dup) = _give(a, card);
      out.add((card, got, dup));
    }
    a.stat('packs', 1);
    _questEvent(a, QuestKind.openPack);
    touch(a);
    return out;
  }

  /// The price of an artist's blind box, from their Deezer fans.
  Future<int> blindBoxPriceOf(int artistId) async {
    final f = catalog.fans[artistId];
    if (f != null && f > 0) return blindBoxPrice(f);
    final info = await catalog.artistTop(artistId);
    return blindBoxPrice(info.fans);
  }

  /// Opens an Artist Blind Box: one of the artist's songs, always shiny,
  /// with every rarity they have equally likely — or, 1 time in 100, a
  /// Canvas edition instead (if serials remain).
  Future<(CardPayload, CardPayload?, int)> openBlindBox(String id, int artistId, {int? expectedPrice}) async {
    final a = account(id);
    final info = await catalog.artistTop(artistId);
    if (info.songs.isEmpty) throw MarketException('No songs found for ${info.name}');
    final price = blindBoxPrice(info.fans);
    if (expectedPrice != null && price > expectedPrice) throw MarketException('The price changed to $price bits — try again');
    if (a.bits < price) throw MarketException('Not enough bits');
    a.bits -= price;
    final pool = catalog.freshPool;
    // Songs the player doesn't have yet (as the shiny a box gives) come
    // first, so boxes don't keep handing out the same song; once they own
    // them all, any song can come up again.
    final ownedShiny = {
      for (final c in a.cards.values)
        if (c.shiny && c.edition == Edition.standard) c.songId,
    };
    final fresh = [
      for (final s in info.songs)
        if (!ownedShiny.contains(s.id)) s,
    ];
    final byRarity = <Rarity, List<SongInfo>>{};
    for (final s in fresh.isEmpty ? info.songs : fresh) {
      (byRarity[pool.rarityOf(s.id)] ??= []).add(s);
    }
    final rarities = byRarity.keys.toList();
    final rarity = rarities[rng.nextInt(rarities.length)];
    final list = byRarity[rarity]!;
    final song = list[rng.nextInt(list.length)];
    var edition = Edition.standard;
    var serial = 0;
    if (rng.nextInt(kBlindBoxCanvasOdds) == 0) {
      final n = engine.claimSerial(song.id, Edition.canvas, song: song, playerId: id);
      if (n != null) {
        edition = Edition.canvas;
        serial = n;
      }
    }
    final card = song.toPayload(uid: 0, rarity: rarity, shiny: edition == Edition.standard, edition: edition, serial: serial, acquiredAt: now());
    final (got, dup) = _give(a, card);
    a.stat('packs', 1);
    touch(a);
    return (card, got, dup);
  }

  // ------------------------------------------------------------------ shop
  /// Buys an item priced in bits (pets, profile themes).
  void buyItem(String id, String itemId, {bool free = false}) {
    final a = account(id);
    final item = shopItem(itemId);
    if (item == null) throw MarketException('Unknown item');
    if (a.owned.contains(itemId)) return;
    if (item.kind == ShopKind.bits) throw MarketException('Bits are bought through the app store');
    if (!item.free && !free) {
      if (item.bitsPrice <= 0) throw MarketException('This item is bought through the app store');
      if (a.bits < item.bitsPrice) throw MarketException('Not enough bits');
      a.bits -= item.bitsPrice;
    }
    a.owned.add(itemId);
    touch(a);
  }

  /// Grants a real-money item (bits bundles, themes, cosmetics, bundles).
  /// There are no receipt checks yet; grants are logged for review.
  void grant(String id, String itemId) {
    final a = account(id);
    final item = shopItem(itemId);
    if (item == null) throw MarketException('Unknown item');
    if (item.kind == ShopKind.bits) {
      a.bits += item.bits;
      a.stat('bitsBought', item.bits);
    } else {
      a.owned.add(itemId);
      if (item.bundleOf != null) a.owned.addAll(shopIdsOfKind(item.bundleOf!));
    }
    if (item.realMoney) {
      a.stat('grants', 1);
      if (a.statInt('grants') > 30) _flag(a, 'many_grants', '${a.statInt('grants')} store grants');
    }
    touch(a);
  }

  /// Bits a username change costs (the first choice and first change are
  /// free). Charged by [chargeUsernameChange].
  int usernameChangeCost(String id) {
    final a = accounts[id];
    final named = engine.players[id]?.named ?? false;
    if (a == null || !a.imported || !named) return 0;
    return a.usernameChanges == 0 ? 0 : kUsernameChangeBits;
  }

  void chargeUsernameChange(String id) {
    final a = accounts[id];
    final named = engine.players[id]?.named ?? false;
    if (a == null || !a.imported || !named) return;
    final cost = usernameChangeCost(id);
    if (a.bits < cost) throw MarketException('Changing your username again costs $cost bits');
    a.bits -= cost;
    a.usernameChanges++;
    touch(a);
  }

  /// Takes [bits] for something (a showcase). Throws if short.
  void chargeBits(String id, int bits, String what) {
    final a = accounts[id];
    if (a == null || !a.imported || bits <= 0) return;
    if (a.bits < bits) throw MarketException('$what costs $bits bits');
    a.bits -= bits;
    touch(a);
  }

  // ----------------------------------------------------------------- scrap
  /// Scraps cards for coins. Editions can't be scrapped, and cards on the
  /// market are held by it (not in the collection).
  int scrap(String id, Iterable<int> uids) {
    final a = account(id);
    var total = 0;
    for (final uid in uids.toSet()) {
      final c = a.cards[uid];
      if (c == null || !canScrap(c.edition)) continue;
      total += a.bonuses.scaleScrap(scrapValue(c.rarity, c.shiny, c.rank));
      _remove(a, uid);
      a.stat('scrapped', 1);
    }
    a.coins += total;
    touch(a);
    return total;
  }

  // ---------------------------------------------------------------- market
  /// The player's own copies of [cards] (checked against the collection),
  /// taken out of it for the market. Throws if any is missing.
  List<CardPayload> escrowCards(String id, List<CardPayload> cards) {
    final a = accounts[id];
    if (a == null || !a.imported) return cards;
    final mine = <CardPayload>[];
    for (final c in cards) {
      final own = a.cards[c.uid];
      if (own == null) throw MarketException('You don\'t have ${c.title.isEmpty ? 'that song' : c.title} any more');
      mine.add(own);
    }
    for (final c in mine) {
      _remove(a, c.uid);
    }
    touch(a);
    return mine;
  }

  /// Takes [coins] for a purchase, bid or offer. Throws if short.
  void escrowCoins(String id, int coins) {
    final a = accounts[id];
    if (a == null || !a.imported || coins <= 0) return;
    if (a.coins < coins) throw MarketException('Not enough coins ($coins needed)');
    a.coins -= coins;
    touch(a);
  }

  /// Gives back coins and cards when a market request fails, and adds cards
  /// the market returns or sells to the player.
  void credit(String id, {int coins = 0, List<CardPayload> cards = const []}) {
    final a = accounts[id];
    if (a == null || !a.imported) return;
    a.coins += coins;
    for (final c in cards) {
      _add(a, c);
    }
    touch(a);
  }

  void listedOnMarket(String id) {
    final a = accounts[id];
    if (a == null || !a.imported) return;
    _questEvent(a, QuestKind.listOnMarket);
    a.stat('listed', 1);
    touch(a);
  }

  // ---------------------------------------------------------------- quests
  List<Quest> dailyQuests(Account a) {
    final pool = catalog.songs.isEmpty ? null : catalog.pool;
    final genres = [for (final g in kWorldGenres) if ((pool?.genreSize(g.id) ?? 0) > 20) g];
    return QuestRules.daily(a.questDay.isEmpty ? dayKeyAt(now(), a.tz ?? 0) : a.questDay, genres);
  }

  List<Quest>? _unlockCache;
  String _unlockKey = '';

  List<Quest> unlockQuests(Account a) {
    final week = QuestRules.weekOf(a.questDay.isEmpty ? dayKeyAt(now(), a.tz ?? 0) : a.questDay);
    final key = '$week:${catalog.songs.length ~/ 500}';
    if (_unlockKey != key || _unlockCache == null) {
      final pool = catalog.pool;
      _unlockCache = QuestRules.unlocks(week, {for (final e in pool.artistsWithAtLeast(8)) e.key: e.value}, (s) => pool.rarityOf(s.id));
      _unlockKey = key;
    }
    return _unlockCache!;
  }

  int questProgress(Account a, Quest q) => switch (q.kind) {
        QuestKind.artistSongs => {for (final c in a.cards.values) if (c.artistId == q.artistId) c.songId}.length,
        QuestKind.collectionSize => a.cards.length,
        QuestKind.catchShiny => a.statInt('shinies'),
        _ => a.questProgress[q.id] ?? 0,
      };

  /// The quest board with progress, for the game.
  Map<String, dynamic> questBoard(String id, {int? tz}) {
    final a = account(id);
    today(a, tz);
    Map<String, dynamic> j(Quest q) => {...q.toJson(), 'progress': questProgress(a, q), 'claimed': a.questsClaimed.contains(q.id)};
    return {
      'day': a.questDay,
      'resetMs': msUntilMidnight(now(), a.tz ?? 0),
      'daily': [for (final q in dailyQuests(a)) j(q)],
      'unlock': [for (final q in unlockQuests(a)) j(q)],
      'milestone': [for (final q in QuestRules.milestones()) j(q)],
      'albums': [for (final c in a.questsClaimed) if (c.startsWith('a_')) c],
    };
  }

  /// Claims a finished quest's reward. Returns the reward card, if any.
  Future<(CardPayload?, int)> claimQuest(String id, String questId) async {
    final a = account(id);
    today(a, null);
    if (a.questsClaimed.contains(questId)) throw MarketException('Already claimed');
    Quest? q;
    var progress = 0;
    if (questId.startsWith('a_')) {
      final albumId = int.tryParse(questId.substring(2));
      if (albumId == null) throw MarketException('Unknown quest');
      final album = await catalog.album(albumId);
      if (album.tracks.isEmpty) throw MarketException('Album not found');
      final ownedIds = {for (final c in a.cards.values) c.songId};
      progress = album.tracks.where((t) => ownedIds.contains(t.id)).length;
      final top = (List.of(album.tracks)..sort((x, y) => y.rank.compareTo(x.rank))).first;
      q = QuestRules.album(albumId: albumId, title: album.title, recordType: album.recordType, trackCount: album.tracks.length, coverMd5: album.coverMd5, topSongId: top.id);
    } else {
      for (final x in [...dailyQuests(a), ...unlockQuests(a), ...QuestRules.milestones()]) {
        if (x.id == questId) q = x;
      }
      if (q == null) throw MarketException('That quest is over');
      progress = questProgress(a, q);
    }
    if (progress < q.target) throw MarketException('Not finished yet');
    a.questsClaimed.add(questId);
    a.coins += q.reward.coins;
    a.bits += q.reward.bits;
    _xp(a, q.reward.xp);
    CardPayload? card;
    var dup = 0;
    final songId = q.reward.songId;
    if (songId != null) {
      var song = catalog.songs[songId];
      if (song == null && questId.startsWith('a_')) {
        final album = await catalog.album(int.parse(questId.substring(2)));
        song = album.tracks.where((t) => t.id == songId).firstOrNull;
      }
      if (song != null) {
        final rarity = catalog.songs.containsKey(song.id) ? catalog.pool.rarityOf(song.id) : (q.reward.rarity ?? Rarity.rare);
        final shiny = q.reward.shiny || rng.nextInt(8) == 0;
        final (got, d) = _give(a, song.toPayload(uid: 0, rarity: rarity, shiny: shiny, acquiredAt: now()));
        card = got;
        dup = d;
      }
    }
    touch(a);
    return (card, dup);
  }

  // ------------------------------------------------------------- minigames
  static const _allGames = '_all';

  Map<String, dynamic> minigameQuota(String id, String game, {int? tz}) {
    final a = account(id);
    if (!kMinigames.contains(game)) throw MarketException('Unknown minigame');
    final day = today(a, tz);
    // One pool of rounds a day for all the games together.
    final rec = a.plays[_allGames];
    final used = rec != null && rec.$1 == day ? rec.$2 : 0;
    return {'left': math.max(0, kMinigamePlaysPerDay - used), 'total': kMinigamePlaysPerDay, 'resetMs': msUntilMidnight(now(), a.tz ?? 0), 'day': day};
  }

  /// Spends one of today's plays and opens a round.
  Map<String, dynamic> startMinigame(String id, String game, {int? tz}) {
    final a = account(id);
    final q = minigameQuota(id, game, tz: tz);
    if ((q['left'] as int) <= 0) throw MarketException('No plays left today');
    final rec = a.plays[_allGames];
    final used = rec != null && rec.$1 == q['day'] ? rec.$2 : 0;
    a.plays[_allGames] = (q['day'] as String, used + 1);
    a.roundBits[game] = 0;
    a.stat('rounds', 1);
    touch(a);
    return {...q, 'left': (q['left'] as int) - 1};
  }

  /// Pays bits won in the open round (never more than the game allows per
  /// round). Returns the bits actually paid.
  int awardMinigame(String id, String game, int bits) {
    final a = account(id);
    final paid = a.roundBits[game];
    if (paid == null) throw MarketException('Start a round first');
    final int pay = bits.clamp(0, math.max(0, minigameMaxBits(game) - paid)).toInt();
    if (bits > minigameMaxBits(game)) _flag(a, 'minigame_bits', 'asked for $bits bits in $game');
    a.roundBits[game] = paid + pay;
    a.bits += pay;
    _xp(a, minigameXp(pay));
    a.stat('minigameBits', pay);
    touch(a);
    return pay;
  }

  // ----------------------------------------------------------------- admin
  void adminSetBalances(String id, {int? coins, int? bits}) {
    final a = account(id);
    if (coins != null) a.coins = coins.clamp(0, 2000000000);
    if (bits != null) a.bits = bits.clamp(0, 2000000000);
    touch(a);
  }

  int adminGenerateCards(String id, int n) {
    final a = account(id);
    if (catalog.songs.isEmpty) return 0;
    final r = Rng(rng.nextInt(1 << 32));
    final pool = catalog.pool;
    var added = 0;
    for (var i = 0; i < n.clamp(0, 5000); i++) {
      final s = pool.pickSong(r, rarity: r.rollRarity());
      if (s == null) continue;
      final c = s.toPayload(uid: 0, rarity: pool.rarityOf(s.id), shiny: r.chance(kShinyOdds), acquiredAt: now() - r.nextInt(365 * 24 * 3600) * 1000);
      if (a.ownsVariant(c)) continue;
      _add(a, c, keepUid: false);
      added++;
    }
    touch(a);
    return added;
  }

  void adminClearCards(String id) {
    final a = account(id);
    for (final uid in a.cards.keys.toList()) {
      _remove(a, uid);
    }
    touch(a);
  }

  void adminResetMinigames(String id) {
    final a = account(id);
    a.plays.clear();
    a.roundBits.clear();
    touch(a);
  }

  void adminRespawn(String id) {
    final a = account(id);
    a.spent.clear();
    a.slots.clear();
    touch(a);
  }
}
