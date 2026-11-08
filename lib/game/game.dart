import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../data/catalog.dart';
import '../data/collection.dart';
import '../data/deezer_api.dart';
import '../data/models.dart';
import '../data/profile.dart';
import '../map3d/map_data.dart';
import 'genre_zones.dart';
import 'audio_service.dart';
import 'location_service.dart';
import 'market_service.dart';
import 'purchase_service.dart';
import 'quests.dart';
import 'spawns.dart';
import 'store_catalog.dart';

/// Central game controller. Owns every subsystem and exposes game actions.
class Game extends ChangeNotifier {
  Game._(this.dir, this.api, this.catalog, this.collection, this.profile, this.location, this.audio, this.mapData)
      : zones = GenreZones(mapData) {
    spawnEngine = SpawnEngine(catalog, zoneBias: (lat, lng) => zones.sample(lat, lng).genreBias);
  }

  final Directory dir;
  final DeezerApi api;
  final Catalog catalog;
  final CollectionStore collection;
  final PlayerProfile profile;
  final LocationService location;
  final AudioService audio;
  final MapData mapData;
  final GenreZones zones;
  late final SpawnEngine spawnEngine;

  /// Genre zone reading at the player's position.
  ZoneReading zoneHere = const ZoneReading({}, false);
  late final PurchaseService purchases;
  late MarketBackend market;

  final _toasts = StreamController<String>.broadcast();
  Stream<String> get toasts => _toasts.stream;
  void toast(String m) => _toasts.add(m);

  List<Spawn> spawns = [];
  LatLng? _spawnCenter;
  int _spawnWindow = -1;
  int _spawnCatalogVersion = -1;
  Timer? _tick;
  Timer? _inboxTimer;

  static const catchRangeMeters = 70.0;

  static Future<Game> create() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/tunetrail');
    await dir.create(recursive: true);
    final api = DeezerApi();
    final catalog = Catalog(api, dir);
    final collection = CollectionStore(catalog, dir);
    final profile = PlayerProfile(dir);
    await Future.wait([catalog.load(), profile.load()]);
    await collection.load();
    final location = LocationService(LatLng(profile.lastLat, profile.lastLng));
    final audio = AudioService(catalog);
    final tilesDir = Directory('${dir.path}/tiles');
    await tilesDir.create(recursive: true);
    final g = Game._(dir, api, catalog, collection, profile, location, audio, MapData(tilesDir));
    await g._init();
    return g;
  }

  Future<void> _init() async {
    purchases = PurchaseService(onGrant: _grantProduct);
    unawaited(purchases.init());
    location.joystickMode = profile.debugEnabled && profile.joystickEnabled;
    location.speedMultiplier = profile.speedMultiplier;
    location.onTravel = _onTravel;
    location.addListener(_onLocation);
    catalog.addListener(_onCatalog);
    profile.addListener(notifyListeners);
    mapData.addListener(_onMapData);
    mapData.ensureAround(location.position.latitude, location.position.longitude);
    collection.addListener(notifyListeners);
    unawaited(audio.setVolume(profile.volume));
    await _connectMarket();
    _resetDailyIfNeeded();
    unawaited(location.start());
    catalog.lastFmKey = profile.effectiveLastFmKey;
    catalog.favoriteArtists = {for (final a in profile.favoriteArtists) a.id};
    unawaited(catalog.crawl());
    unawaited(catalog.backfillPlays());
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _refreshSpawns());
    _inboxTimer = Timer.periodic(const Duration(seconds: 15), (_) => syncInbox());
    _refreshSpawns(force: true);
  }

  // ---------------------------------------------------------------- market
  Future<void> _connectMarket() async {
    if (profile.marketMode == MarketMode.online) {
      market = RemoteMarket(profile.serverUrl, profile.playerId, profile.name);
      try {
        await market.register(profile.playerId, profile.name);
        return;
      } catch (e) {
        toast('Market server unreachable — using local market');
      }
    }
    final local = LocalMarket(dir, catalog, profile.playerId, profile.name);
    await local.init();
    market = local;
  }

  Future<void> setMarketMode(MarketMode mode, String url) async {
    profile.marketMode = mode;
    profile.serverUrl = url;
    profile.changed();
    market.dispose();
    await _connectMarket();
    notifyListeners();
  }

  Future<void> syncInbox() async {
    try {
      final items = await market.claimInbox();
      for (final i in items) {
        if (i.coins > 0) profile.coins += i.coins;
        for (final c in i.cards) {
          collection.addPayload(c, CardSource.trade);
        }
        if (i.message.contains('accepted') || i.message.contains('Trade with')) {
          profile.tradesCompleted++;
        }
        if (i.message.contains('bought your')) profile.cardsSold++;
        toast(i.message);
      }
      if (items.isNotEmpty) {
        profile.changed();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Lists a folder of owned cards: uid → price. Cards move into escrow.
  Future<void> listCards(Map<int, int> prices, {int? folderPrice, String note = '', bool trades = false}) async {
    final cards = <OwnedCard>[];
    for (final uid in prices.keys) {
      final c = collection.byUid(uid);
      if (c == null) throw MarketException('You no longer own one of those songs');
      cards.add(c);
    }
    for (final c in cards) {
      _removeFromPlaylists(c.uid);
      collection.remove(c.uid);
    }
    try {
      await market.createListing([for (final c in cards) ListingItem(card: c.toPayload(), price: prices[c.uid]!)],
          folderPrice: folderPrice, note: note, acceptsTrades: trades);
      questEvent(QuestKind.listOnMarket);
    } catch (e) {
      for (final c in cards) {
        collection.addPayload(c.toPayload(), c.source);
      }
      rethrow;
    }
  }

  /// Quick list: one card with the player's preset price/note for its rarity.
  Future<void> quickList(int uid) async {
    final c = collection.byUid(uid);
    if (c == null) throw MarketException('You no longer own that card');
    final preset = profile.quickListPreset(c.rarity);
    final price = preset.price * (c.shiny ? kShinyValueMultiplier : 1);
    await listCards({uid: price}, note: preset.note, trades: preset.trades);
  }

  Future<void> cancelListing(Listing l) async {
    for (final c in await market.cancelListing(l.id)) {
      collection.addPayload(c, CardSource.market);
    }
  }

  Future<void> withdrawFromListing(Listing l, int cardUid) async {
    collection.addPayload(await market.withdrawItem(l.id, cardUid), CardSource.market);
  }

  /// Buys a whole folder at its folder price.
  Future<void> buyListing(Listing l) async {
    final price = l.folderPrice;
    if (profile.coins < price) throw MarketException('Not enough coins');
    profile.coins -= price;
    profile.changed();
    try {
      for (final c in await market.buy(l.id, price)) {
        collection.addPayload(c.withUid(collection.newUid()), CardSource.market);
      }
    } catch (e) {
      profile.coins += price;
      profile.changed();
      rethrow;
    }
  }

  /// Buys a single song from a folder at its own price.
  Future<void> buyListingItem(Listing l, ListingItem item) async {
    if (profile.coins < item.price) throw MarketException('Not enough coins');
    profile.coins -= item.price;
    profile.changed();
    try {
      final c = await market.buyItem(l.id, item.card.uid, item.price);
      collection.addPayload(c.withUid(collection.newUid()), CardSource.market);
    } catch (e) {
      profile.coins += item.price;
      profile.changed();
      rethrow;
    }
  }

  Future<void> makeOffer(Listing l, List<int> uids, int coins, {String note = ''}) async {
    if (profile.coins < coins) throw MarketException('Not enough coins');
    final cards = [for (final u in uids) ?collection.byUid(u)];
    for (final c in cards) {
      _removeFromPlaylists(c.uid);
      collection.remove(c.uid);
    }
    profile.coins -= coins;
    profile.changed();
    try {
      await market.createOffer(l.id, [for (final c in cards) c.toPayload()], coins, note: note);
    } catch (e) {
      for (final c in cards) {
        collection.addPayload(c.toPayload(), c.source);
      }
      profile.coins += coins;
      profile.changed();
      rethrow;
    }
  }

  Future<void> acceptOffer(TradeOffer o) async {
    await market.acceptOffer(o.id);
    await syncInbox();
  }

  Future<void> declineOffer(TradeOffer o) async {
    await market.declineOffer(o.id);
    await syncInbox();
  }

  Future<void> publishShowcase() async {
    final cards = [for (final u in profile.showcaseCards) ?collection.byUid(u)?.toPayload()];
    final pls = [
      for (final p in profile.playlists.where((p) => profile.showcasePlaylists.contains(p.id)))
        ShowcasePlaylist(name: p.name, cards: [
          for (final u in p.cardUids.take(50)) ?collection.byUid(u)?.toPayload()
        ])
    ];
    await market.setShowcase(profile.showcaseTitle, cards, pls, favoriteArtists: profile.favoriteArtists);
  }

  // ---------------------------------------------------------------- spawns
  void _onLocation() {
    profile.lastLat = location.position.latitude;
    profile.lastLng = location.position.longitude;
    mapData.ensureAround(location.position.latitude, location.position.longitude);
    _refreshSpawns();
  }

  Timer? _mapDebounce;
  void _onMapData() {
    _mapDebounce?.cancel();
    _mapDebounce = Timer(const Duration(milliseconds: 400), () => _refreshSpawns(force: true));
  }

  void _onCatalog() {
    if (spawns.isEmpty) _refreshSpawns(force: true);
  }

  void _refreshSpawns({bool force = false}) {
    final now = DateTime.now();
    final w = now.millisecondsSinceEpoch ~/ SpawnEngine.window.inMilliseconds;
    final moved = _spawnCenter == null || metersBetween(_spawnCenter!, location.position) > 60;
    final catalogGrew = catalog.version != _spawnCatalogVersion && spawns.isEmpty;
    if (!force && !moved && w == _spawnWindow && !catalogGrew) return;
    _spawnCenter = location.position;
    _spawnWindow = w;
    _spawnCatalogVersion = catalog.version;
    final nowMs = now.millisecondsSinceEpoch;
    profile.spentSpawns.removeWhere((_, exp) => exp < nowMs);
    debugSpawns.removeWhere((d) => d.expiresAt.isBefore(now) || profile.spentSpawns.containsKey(d.id));
    spawns = [...spawnEngine.around(location.position, exclude: profile.spentSpawns.keys.toSet()), ...debugSpawns];
    zoneHere = zones.sample(location.position.latitude, location.position.longitude);
    notifyListeners();
  }

  bool inRange(Spawn s) =>
      (profile.debugEnabled && profile.unlimitedRange) ||
      metersBetween(location.position, s.point) <= catchRangeMeters;

  void _markSpent(Spawn s) {
    profile.spentSpawns[s.id] = s.expiresAt.millisecondsSinceEpoch + 60000;
    spawns = spawns.where((x) => x.id != s.id).toList();
    profile.changed();
    notifyListeners();
  }

  /// Catches a spawn. A 100% perfect catch makes any song shiny.
  OwnedCard catchSpawn(Spawn s, {bool perfect = false}) {
    catalog.addSongs([s.song]);
    final shiny = s.shiny || perfect;
    final uid = collection.add(s.song.id, s.rarity, shiny, CardSource.wild);
    profile.coins += s.rarity.catchCoins * (shiny ? 3 : 1);
    profile.xp += s.rarity.catchXp * (shiny ? 3 : 1);
    profile.totalCaught++;
    if (shiny) profile.shinyCaught++;
    questEvent(QuestKind.catchAny);
    questEvent(QuestKind.catchGenre, genreId: s.song.genreId);
    if (s.rarity.index >= Rarity.rare.index) questEvent(QuestKind.catchRarePlus);
    _markSpent(s);
    return collection.byUid(uid)!;
  }

  void fleeSpawn(Spawn s) => _markSpent(s);

  void _onTravel(double m) {
    profile.metersWalked += m;
    questEvent(QuestKind.walkMeters, amount: m.round());
  }

  // ----------------------------------------------------------------- packs
  /// Opens a pack; returns the new cards. Throws if not enough bits.
  List<OwnedCard> openPack(PackDef p, {int? genreId}) {
    if (profile.bits < p.bits) throw MarketException('Not enough bits');
    if (catalog.size == 0) throw MarketException('Song catalog still loading');
    profile.bits -= p.bits;
    final rng = Rng(DateTime.now().microsecondsSinceEpoch ^ profile.packsOpened * 7919);
    final rolls = <(Song, Rarity, bool)>[];
    for (var i = 0; i < p.cards; i++) {
      final song = catalog.pickSong(rng, genreId: genreId, rarity: rng.rollRarity(minIndex: p.allMin.index, luck: p.luck))!;
      rolls.add((song, catalog.rarityOf(song), rng.chance(p.shinyOdds)));
    }
    // Enforce guarantees on the last card (classic "pity slot"). Rarity is a
    // property of the song, so the slot draws a song of that rarity.
    if (p.guaranteedMin != null && !rolls.any((x) => x.$2.index >= p.guaranteedMin!.index)) {
      final last = rolls.removeLast();
      Song? pick;
      for (var tries = 0; tries < 12; tries++) {
        final cand = catalog.pickSong(rng, genreId: genreId, rarity: rng.rollRarity(minIndex: p.guaranteedMin!.index, luck: p.luck));
        if (cand != null && catalog.rarityOf(cand).index >= p.guaranteedMin!.index) {
          pick = cand;
          break;
        }
      }
      pick ??= catalog.pickSong(rng, rarity: p.guaranteedMin);
      rolls.add(pick == null ? last : (pick, catalog.rarityOf(pick), last.$3));
    }
    if (p.guaranteedShiny && !rolls.any((x) => x.$3)) {
      final i = rng.nextInt(rolls.length);
      rolls[i] = (rolls[i].$1, rolls[i].$2, true);
    }
    final out = <OwnedCard>[];
    for (final r in rolls) {
      final uid = collection.add(r.$1.id, r.$2, r.$3, CardSource.pack, notify: false);
      out.add(collection.byUid(uid)!);
    }
    collection.notifyListeners();
    unawaited(collection.save());
    profile.packsOpened++;
    questEvent(QuestKind.openPack);
    profile.changed();
    notifyListeners();
    return out;
  }

  // ------------------------------------------------------------- purchases
  Future<PurchaseResult> purchase(Product p) async {
    if (p.kind != ProductKind.bits && profile.owned.contains(p.id)) {
      return PurchaseResult.granted;
    }
    final r = await purchases.buy(p, debugFree: profile.debugEnabled && profile.freePurchases);
    return r;
  }

  void _grantProduct(Product p) {
    if (p.kind == ProductKind.bits) {
      profile.bits += p.bits;
      toast('+${p.bits} bits');
    } else {
      profile.owned.add(p.id);
      toast('Unlocked ${p.name}');
    }
    profile.changed();
    notifyListeners();
  }

  void equip(ProductKind kind, String? id) {
    switch (kind) {
      case ProductKind.hat:
        profile.hat = id;
      case ProductKind.shirt:
        profile.shirt = id;
      case ProductKind.pet:
        profile.pet = id;
      case ProductKind.backpack:
        profile.backpack = id;
      case ProductKind.theme:
        profile.activeTheme = id ?? 'theme_classic';
      case ProductKind.bits:
        break;
    }
    profile.changed();
    notifyListeners();
  }

  /// Scrapyard value of a card: rarer and more-streamed songs pay more.
  int scrapValueOf(OwnedCard c) => scrapValue(c.rarity, c.shiny, c.song.rank);

  /// Scraps cards for coins. Returns the coins earned.
  int scrap(Iterable<int> uids) {
    var total = 0;
    var n = 0;
    for (final uid in uids.toList()) {
      final c = collection.byUid(uid);
      if (c == null) continue;
      total += scrapValueOf(c);
      _removeFromPlaylists(uid);
      collection.remove(uid);
      n++;
    }
    profile.coins += total;
    profile.cardsScrapped += n;
    profile.changed();
    return total;
  }

  // ---------------------------------------------------------------- quests
  void _resetDailyIfNeeded() {
    final today = QuestBoard.dayKey(DateTime.now());
    if (profile.questDay != today) {
      profile.questDay = today;
      profile.questProgress.removeWhere((k, _) => k.startsWith('d_'));
      profile.questsClaimed.removeWhere((k) => k.startsWith('d_'));
      profile.changed();
    }
  }

  List<Quest> get dailyQuests => QuestBoard.daily(DateTime.now(), catalog);
  List<Quest> get unlockQuests => QuestBoard.unlocks(DateTime.now(), catalog);
  List<Quest> get milestoneQuests => QuestBoard.milestones();

  void questEvent(QuestKind kind, {int amount = 1, int? genreId}) {
    _resetDailyIfNeeded();
    for (final q in dailyQuests) {
      if (q.kind != kind) continue;
      if (kind == QuestKind.catchGenre && q.genreId != genreId) continue;
      profile.questProgress[q.id] = (profile.questProgress[q.id] ?? 0) + amount;
    }
    profile.changed();
  }

  int questProgress(Quest q) {
    switch (q.kind) {
      case QuestKind.artistSongs:
        return collection.distinctSongsByArtist(q.artistId!);
      case QuestKind.collectionSize:
        return collection.length;
      case QuestKind.catchShiny:
        return profile.shinyCaught;
      case QuestKind.albumComplete:
        return profile.questProgress[q.id] ?? 0;
      default:
        return profile.questProgress[q.id] ?? 0;
    }
  }

  bool questDone(Quest q) => questProgress(q) >= q.target;
  bool questClaimed(Quest q) => profile.questsClaimed.contains(q.id);

  OwnedCard? claimQuest(Quest q) {
    if (!questDone(q) || questClaimed(q)) return null;
    profile.questsClaimed.add(q.id);
    profile.coins += q.reward.coins;
    profile.bits += q.reward.bits;
    profile.xp += q.reward.xp;
    OwnedCard? card;
    if (q.reward.songId != null && catalog.songs.containsKey(q.reward.songId)) {
      final song = catalog.songs[q.reward.songId]!;
      final uid = collection.add(song.id, catalog.rarityOf(song),
          q.reward.shiny || Rng(DateTime.now().microsecondsSinceEpoch).chance(8), CardSource.quest);
      card = collection.byUid(uid);
    }
    profile.changed();
    notifyListeners();
    return card;
  }

  /// Album completion check (called from the album screen).
  void updateAlbumQuest(Quest q, int ownedTracks) {
    profile.questProgress[q.id] = ownedTracks;
  }

  // ------------------------------------------------------------- playlists
  Playlist createPlaylist(String name) {
    final p = Playlist(id: 'p${DateTime.now().microsecondsSinceEpoch}', name: name);
    profile.playlists.add(p);
    profile.changed();
    return p;
  }

  void addToPlaylist(Playlist p, int uid) {
    if (!p.cardUids.contains(uid)) p.cardUids.add(uid);
    profile.changed();
  }

  void removeFromPlaylist(Playlist p, int uid) {
    p.cardUids.remove(uid);
    profile.changed();
  }

  void deletePlaylist(Playlist p) {
    profile.playlists.remove(p);
    profile.showcasePlaylists.remove(p.id);
    profile.changed();
  }

  void _removeFromPlaylists(int uid) {
    for (final p in profile.playlists) {
      p.cardUids.remove(uid);
    }
    profile.showcaseCards.remove(uid);
  }

  Future<void> playPlaylist(Playlist p, {int start = 0}) {
    final ids = [for (final u in p.cardUids) ?collection.byUid(u)?.song.id];
    return audio.playQueue(ids, start: start, name: p.name);
  }

  bool isFavoriteArtist(int id) => profile.favoriteArtists.any((a) => a.id == id);

  /// Adds/removes a favourite artist. Their songs then spawn 10× as often
  /// for this player, and the list is shown on the player's public showcase.
  Future<void> toggleFavoriteArtist(int id, String name, String picMd5) async {
    if (isFavoriteArtist(id)) {
      profile.favoriteArtists.removeWhere((a) => a.id == id);
    } else {
      if (profile.favoriteArtists.length >= kMaxFavoriteArtists) {
        toast('You can pick up to $kMaxFavoriteArtists favourite artists');
        return;
      }
      profile.favoriteArtists.add(FavoriteArtist(id: id, name: name, picMd5: picMd5));
      // Make sure their songs are in the catalogue so they can spawn.
      try {
        await catalog.topTracks(id);
        unawaited(catalog.fetchPlays(id).catchError((_) => false));
      } catch (_) {}
    }
    catalog.favoriteArtists = {for (final a in profile.favoriteArtists) a.id};
    profile.changed();
    _refreshSpawns(force: true);
    // Keep the public profile in sync.
    unawaited(publishShowcase().catchError((_) {}));
  }

  void setLastFmKey(String key) {
    profile.lastFmKey = key.trim();
    profile.changed();
    catalog.lastFmKey = profile.effectiveLastFmKey;
    catalog.favoriteArtists = {for (final a in profile.favoriteArtists) a.id};
    unawaited(catalog.backfillPlays());
  }

  // ----------------------------------------------------------------- debug
  void debugSetBalances({int? coins, int? bits}) {
    if (coins != null) profile.coins = coins;
    if (bits != null) profile.bits = bits;
    profile.changed();
    notifyListeners();
  }

  void setJoystick(bool on) {
    profile.joystickEnabled = on;
    location.setJoystickMode(on && profile.debugEnabled);
    profile.changed();
    notifyListeners();
  }

  void setDebug(bool on) {
    profile.debugEnabled = on;
    location.setJoystickMode(on && profile.joystickEnabled);
    profile.changed();
    notifyListeners();
  }

  void setSpeed(double v) {
    profile.speedMultiplier = v;
    location.speedMultiplier = v;
    profile.changed();
  }

  void teleport(LatLng p) {
    location.teleport(p);
    _refreshSpawns(force: true);
  }

  /// Songs spawned from the debug menu.
  final List<Spawn> debugSpawns = [];

  /// Debug: spawns [song] a few metres in front of the player.
  Spawn debugSpawnSong(Song song, {bool shiny = false, Rarity? rarity}) {
    catalog.addSongs([song]);
    final known = catalog.songs[song.id] ?? song;
    final rng = math.Random();
    final heading = (location.heading + (rng.nextDouble() - 0.5) * 60) * math.pi / 180;
    final dist = 18 + rng.nextDouble() * 12;
    final p = location.position;
    final lat = p.latitude + math.cos(heading) * dist / 111132.95;
    final lng = p.longitude + math.sin(heading) * dist / (111319.49 * math.cos(p.latitude * math.pi / 180));
    final s = Spawn(
      id: 'debug:${known.id}:${DateTime.now().microsecondsSinceEpoch}',
      point: LatLng(lat, lng),
      song: known,
      rarity: rarity ?? catalog.rarityOf(known),
      shiny: shiny,
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
    );
    debugSpawns.add(s);
    _refreshSpawns(force: true);
    return s;
  }

  /// Stress-test helper: adds [n] random cards using the current catalog.
  Future<int> debugGenerateCards(int n) async {
    if (catalog.size == 0) return 0;
    final rng = Rng(DateTime.now().microsecondsSinceEpoch);
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = <(int, Rarity, bool, CardSource, DateTime)>[];
    for (var i = 0; i < n; i++) {
      final s = catalog.pickSong(rng, rarity: rng.rollRarity())!;
      batch.add((
        s.id,
        catalog.rarityOf(s),
        rng.chance(kShinyOdds),
        CardSource.debug,
        DateTime.fromMillisecondsSinceEpoch(now - rng.nextInt(365 * 24 * 3600) * 1000),
      ));
    }
    collection.addMany(batch);
    await collection.save();
    notifyListeners();
    return n;
  }

  void debugClearCollection() {
    collection.clear();
    for (final p in profile.playlists) {
      p.cardUids.clear();
    }
    profile.showcaseCards.clear();
    profile.changed();
    notifyListeners();
  }

  void debugRespawn() {
    profile.spentSpawns.clear();
    _refreshSpawns(force: true);
  }

  Future<void> saveAll() async {
    await Future.wait([profile.save(), collection.save(), catalog.flush()]);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _inboxTimer?.cancel();
    _mapDebounce?.cancel();
    mapData.dispose();
    market.dispose();
    purchases.dispose();
    location.dispose();
    audio.dispose();
    super.dispose();
  }
}
