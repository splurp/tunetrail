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
import '../data/samples.dart';
import '../map3d/map_data.dart';
import '../map3d/props3d.dart';
import 'genre_zones.dart';
import 'movie_service.dart';
import 'sample_player.dart';
import 'audio_service.dart';
import 'location_service.dart';
import 'market_service.dart';
import 'purchase_service.dart';
import 'quests.dart';
import 'spawns.dart';
import 'store_catalog.dart';
import 'trusted_clock.dart';

/// Central game controller. Owns every subsystem and exposes game actions.
class Game extends ChangeNotifier {
  Game._(this.dir, this.api, this.catalog, this.collection, this.profile, this.location, this.audio, this.mapData, this.movies)
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
  final MovieService movies;
  late final SamplePlayer samples = SamplePlayer(audio);
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
  final Map<String, Spawn> _spawnMemo = {};
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
    await PropsPainter.loadModels();
    final movies = MovieService(dir);
    await movies.load();
    final g = Game._(dir, api, catalog, collection, profile, location, audio, MapData(tilesDir), movies);
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
    mapData.buildingsEnabled = profile.showBuildings;
    mapData.ensureAround(location.position.latitude, location.position.longitude);
    collection.addListener(notifyListeners);

    SampleLibrary.overrides
      ..clear()
      ..addAll(profile.sampleOverrides);
    for (final s in SampleLibrary.all) {
      catalog.addSongs([s.song]);
    }
    // A song has exactly one rarity (from its popularity): re-rate cards
    // from older versions before folding duplicates.
    collection.normalizeRarities((id) {
      final s = catalog.songs[id];
      return s == null ? null : catalog.rarityOf(s);
    });
    // One copy per variant: fold any older duplicates into the scrapyard.
    final dups = collection.removeDuplicateVariants();
    if (dups.isNotEmpty) {
      var coins = 0;
      for (final c in dups) {
        coins += scrapValueOf(c);
        _removeFromPlaylists(c.uid);
      }
      profile.coins += coins;
      profile.cardsScrapped += dups.length;
      profile.changed();
      Timer(const Duration(seconds: 3), () => toast('${dups.length} duplicate cards were auto-scrapped for $coins coins'));
    }
    unawaited(audio.setVolume(profile.volume));
    audio.sfxEnabled = profile.soundEffects;
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

  final Set<String> _seenOffers = {};
  bool _offersPrimed = false;

  Future<void> syncInbox() async {
    try {
      final items = await market.claimInbox();
      for (final i in items) {
        if (i.coins > 0) profile.coins += i.coins;
        for (final c in i.cards) {
          acquirePayload(c, CardSource.trade);
        }
        if (i.message.contains('accepted') || i.message.contains('Trade with')) {
          profile.tradesCompleted++;
          unawaited(audio.playSfx(Sfx.tradeAccepted));
        }
        if (i.message.contains('bought your')) {
          profile.cardsSold++;
          unawaited(audio.playSfx(Sfx.sold));
        }
        toast(i.message);
      }
      if (items.isNotEmpty) {
        profile.changed();
        notifyListeners();
      }
      // New trade offers on my listings.
      final incoming = [for (final o in await market.offers()) if (o.toId == profile.playerId) o];
      final fresh = incoming.where((o) => !_seenOffers.contains(o.id)).toList();
      if (_offersPrimed && fresh.isNotEmpty) {
        unawaited(audio.playSfx(Sfx.offer));
        toast(fresh.length == 1 ? 'New trade offer from ${fresh.first.fromName}' : '${fresh.length} new trade offers');
      }
      _seenOffers.addAll(incoming.map((o) => o.id));
      _offersPrimed = true;
    } catch (_) {}
  }

  // ----------------------------------------------------------- acquiring
  /// Adds a card unless the player already owns that exact variant (song ×
  /// rarity × shiny × edition); a duplicate goes straight to the scrapyard
  /// for its coin value instead. Returns the new card, or null for a
  /// duplicate (the coins credited are in [lastDuplicateCoins]).
  OwnedCard? acquire(int songId, Rarity rarity, bool shiny, Edition edition, CardSource source,
      {int? uid, bool notify = true, bool announce = true, int serial = 0}) {
    if (edition != Edition.standard) shiny = false;
    // One rarity per song, whatever the source says.
    final known = catalog.songs[songId];
    if (known != null) rarity = catalog.rarityOf(known);
    if (collection.ownsVariant(songId, rarity, shiny, edition)) {
      final song = catalog.songs[songId];
      final coins = scrapValue(rarity, shiny, song?.rank ?? 0, edition: edition);
      lastDuplicateCoins = coins;
      profile.coins += coins;
      profile.cardsScrapped++;
      profile.changed();
      if (announce) toast('Already owned: ${song?.title ?? 'song'} (${variantLabel(rarity, shiny, edition)}) — scrapped for $coins coins');
      return null;
    }
    lastDuplicateCoins = 0;
    final id = collection.add(songId, rarity, shiny, source, uid: uid, notify: notify, edition: edition, serial: serial);
    return collection.byUid(id);
  }

  int lastDuplicateCoins = 0;

  /// Extra information about the last catch (e.g. serials ran out).
  String? lastCatchNote;

  OwnedCard? acquirePayload(CardPayload p, CardSource source, {bool keepUid = true}) {
    catalog.ensureFromPayload(p);
    return acquire(p.songId, p.rarity, p.shiny, p.edition, source, uid: keepUid ? p.uid : null, serial: p.serial);
  }

  static String variantLabel(Rarity r, bool shiny, Edition e) =>
      e != Edition.standard ? e.label : [if (shiny) 'shiny', r.label].join(' ');

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
      unawaited(audio.playSfx(Sfx.list));
    } catch (e) {
      for (final c in cards) {
        acquirePayload(c.toPayload(), c.source);
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
      acquirePayload(c, CardSource.market);
    }
  }

  Future<void> withdrawFromListing(Listing l, int cardUid) async {
    acquirePayload(await market.withdrawItem(l.id, cardUid), CardSource.market);
  }

  /// Buys a whole folder at its folder price.
  Future<void> buyListing(Listing l) async {
    final price = l.folderPrice;
    if (profile.coins < price) throw MarketException('Not enough coins');
    profile.coins -= price;
    profile.changed();
    try {
      for (final c in await market.buy(l.id, price)) {
        acquirePayload(c, CardSource.market, keepUid: false);
      }
    } catch (e) {
      profile.coins += price;
      profile.changed();
      rethrow;
    }
  }

  /// Buys a single song from a folder at its own price.
  Future<void> buyListingItem(Listing l, ListingItem item) async {
    final c = item.card;
    if (collection.ownsVariant(c.songId, c.rarity, c.shiny, c.edition)) {
      throw MarketException('You already own this variant');
    }
    if (profile.coins < item.price) throw MarketException('Not enough coins');
    profile.coins -= item.price;
    profile.changed();
    try {
      final c = await market.buyItem(l.id, item.card.uid, item.price);
      acquirePayload(c, CardSource.market, keepUid: false);
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
        acquirePayload(c.toPayload(), c.source);
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
    // A spawn keeps the song it first showed until it expires — the
    // catalogue keeps growing in the background, which would otherwise
    // re-roll what an existing spawn contains.
    _spawnMemo.removeWhere((_, s) => s.expiresAt.isBefore(now));
    spawns = [
      for (final s in spawnEngine.around(location.position, exclude: profile.spentSpawns.keys.toSet())) _spawnMemo.putIfAbsent(s.id, () => s),
      ...debugSpawns,
    ];
    zoneHere = zones.sample(location.position.latitude, location.position.longitude);
    _applyEditionAvailability();
  }

  /// Serials left per "songId:edition" (cached from the market backend).
  final Map<String, int> _serialsLeft = {};
  final Set<String> _serialsPending = {};

  int? serialsLeft(int songId, Edition e) => _serialsLeft['$songId:${e.index}'];

  /// Edition spawns only stand while numbered copies remain: once every
  /// serial of a song's Canvas/Sample edition is claimed it spawns as a
  /// standard card instead.
  void _applyEditionAvailability() {
    var changed = false;
    final out = <Spawn>[];
    for (final s in spawns) {
      if (s.edition != Edition.standard) {
        final key = '${s.song.id}:${s.edition.index}';
        final left = _serialsLeft[key];
        if (left == null && _serialsPending.add(key)) {
          unawaited(market.serialsLeft(s.song.id, s.edition).then((n) {
            _serialsLeft[key] = n;
            _applyEditionAvailability();
          }).catchError((_) {}).whenComplete(() {
            _serialsPending.remove(key);
          }));
        }
        if (left == 0) {
          out.add(s.withEdition(Edition.standard));
          changed = true;
          continue;
        }
      }
      out.add(s);
    }
    if (changed) spawns = out;
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
  /// Returns the new card, or null if that variant was already owned (it is
  /// then auto-scrapped; see [lastDuplicateCoins]).
  ///
  /// Edition spawns claim the next global serial number; if they've all
  /// gone in the meantime the catch becomes a standard card.
  Future<OwnedCard?> catchSpawn(Spawn s, {bool perfect = false}) async {
    catalog.addSongs([s.song]);
    var edition = s.edition;
    var serial = 0;
    lastCatchNote = null;
    if (edition != Edition.standard) {
      if (collection.ownsVariant(s.song.id, s.rarity, false, edition)) {
        // Already own this edition: don't burn a serial on a duplicate.
      } else {
        int? n;
        try {
          n = await market.claimSerial(s.song.id, edition);
        } catch (_) {}
        final key = '${s.song.id}:${edition.index}';
        if (n == null) {
          lastCatchNote = 'Every ${edition.label} edition of this song has been claimed — you caught a standard card.';
          _serialsLeft[key] = 0;
          edition = Edition.standard;
        } else {
          serial = n;
          _serialsLeft[key] = edition.maxSerials - n;
        }
      }
    }
    // Editions are exclusive: a perfect catch only turns standard cards shiny.
    final shiny = edition == Edition.standard && (s.shiny || perfect);
    final card = acquire(s.song.id, s.rarity, shiny, edition, CardSource.wild, announce: false, serial: serial);
    unawaited(audio.playSfx(Sfx.catchSong));
    profile.coins += s.rarity.catchCoins * (shiny ? 3 : 1);
    profile.xp += s.rarity.catchXp * (shiny ? 3 : 1);
    profile.totalCaught++;
    if (shiny) profile.shinyCaught++;
    questEvent(QuestKind.catchAny);
    questEvent(QuestKind.catchGenre, genreId: s.song.genreId);
    if (s.rarity.index >= Rarity.rare.index) questEvent(QuestKind.catchRarePlus);
    _markSpent(s);
    return card;
  }

  void fleeSpawn(Spawn s) => _markSpent(s);

  double _walkPending = 0;

  /// Walking is reported ~30×/s by the joystick and every few metres by GPS;
  /// committing each step saved the profile and rebuilt the whole map screen
  /// many times a second. Distance is batched into 25 m chunks instead.
  void _onTravel(double m) {
    profile.metersWalked += m;
    _walkPending += m;
    if (_walkPending >= 25) {
      final whole = _walkPending.floor();
      _walkPending -= whole;
      questEvent(QuestKind.walkMeters, amount: whole);
    }
  }

  // ----------------------------------------------------------------- packs
  /// Opens a pack; returns the new cards. Throws if not enough bits.
  List<PackPull> openPack(PackDef p, {int? genreId}) {
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
    final out = <PackPull>[];
    for (final r in rolls) {
      // Songs with known sample data sometimes come as Sample editions.
      const ed = Edition.standard;
      final card = acquire(r.$1.id, r.$2, r.$3, ed, CardSource.pack, notify: false, announce: false);
      out.add(PackPull(card ?? OwnedCard(-1, r.$1, r.$2, r.$3, false, DateTime.now(), CardSource.pack, ed), card == null ? lastDuplicateCoins : 0));
    }
    collection.notifyListeners();
    unawaited(collection.save());
    profile.packsOpened++;
    questEvent(QuestKind.openPack);
    profile.changed();
    notifyListeners();
    return out;
  }

  // ------------------------------------------------------ artist blind box
  /// Bits for an artist's blind box: 5 for small artists up to 100 for the
  /// biggest (log scale of Deezer fans).
  static int blindBoxPrice(int fans) {
    final t = (math.log(math.max(fans, 1)) / math.ln10 - 4) / (math.log(30000000) / math.ln10 - 4);
    return (5 + 95 * t.clamp(0.0, 1.0)).round();
  }

  /// Opens an Artist Blind Box: one of the artist's songs, always shiny,
  /// with every rarity they have equally likely — or, 1 time in 100, a
  /// Canvas edition instead (if serials remain). Returns the pull.
  Future<PackPull> openArtistBlindBox(ArtistInfo artist) async {
    final price = blindBoxPrice(artist.fans);
    if (profile.bits < price) throw MarketException('Not enough bits');
    final tracks = await api.artistTop(artist.id, limit: 100);
    if (tracks.isEmpty) throw MarketException('No songs found for ${artist.name}');
    catalog.addSongs(tracks);
    profile.bits -= price;
    profile.changed();
    final rng = math.Random();
    final byRarity = <Rarity, List<Song>>{};
    for (final t in tracks) {
      final s = catalog.songs[t.id] ?? t;
      (byRarity[catalog.rarityOf(s)] ??= []).add(s);
    }
    final rarities = byRarity.keys.toList();
    final rarity = rarities[rng.nextInt(rarities.length)];
    final pool = byRarity[rarity]!;
    final song = pool[rng.nextInt(pool.length)];
    var edition = Edition.standard;
    var serial = 0;
    if (rng.nextInt(100) == 0 && !collection.ownsVariant(song.id, rarity, false, Edition.canvas)) {
      try {
        final n = await market.claimSerial(song.id, Edition.canvas);
        if (n != null) {
          edition = Edition.canvas;
          serial = n;
        }
      } catch (_) {}
    }
    final card = acquire(song.id, rarity, edition == Edition.standard, edition, CardSource.pack, announce: false, serial: serial);
    profile.packsOpened++;
    profile.changed();
    notifyListeners();
    return PackPull(
      card ?? OwnedCard(-1, song, rarity, edition == Edition.standard, false, DateTime.now(), CardSource.pack, edition, serial),
      card == null ? lastDuplicateCoins : 0,
    );
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
  int scrapValueOf(OwnedCard c) => scrapValue(c.rarity, c.shiny, c.song.rank, edition: c.edition);

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
    if (n > 0) unawaited(audio.playSfx(Sfx.quicksell));
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
      card = acquire(song.id, catalog.rarityOf(song), q.reward.shiny || Rng(DateTime.now().microsecondsSinceEpoch).chance(8), Edition.standard,
          CardSource.quest);
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

  void setShowBuildings(bool on) {
    profile.showBuildings = on;
    profile.changed();
    mapData.buildingsEnabled = on;
    mapData.ensureAround(location.position.latitude, location.position.longitude);
  }

  // ------------------------------------------------------------- minigames
  static const kMinigamePlaysPerDay = 3;
  final TrustedClock clock = TrustedClock();

  /// Plays left today for a minigame, plus time until the reset — using
  /// trusted server time (changing the device clock doesn't help) and a
  /// pinned time-zone offset (a new offset is only accepted 20 h after the
  /// previous one, so hopping time zones can't add extra days).
  Future<MinigameQuota?> minigameQuota(String game) async {
    final now = await clock.now();
    if (now == null) return null;
    final device = DateTime.now().timeZoneOffset.inMinutes;
    final pinned = profile.minigameTzOffset;
    if (pinned == null || (pinned != device && now.millisecondsSinceEpoch - profile.minigameTzSetAt > 20 * 3600 * 1000)) {
      profile.minigameTzOffset = device;
      profile.minigameTzSetAt = now.millisecondsSinceEpoch;
      profile.changed();
    }
    final off = profile.minigameTzOffset!;
    final day = TrustedClock.dayKey(now, off);
    final rec = profile.minigamePlays[game];
    final used = rec != null && rec.$1 == day ? rec.$2 : 0;
    return MinigameQuota(kMinigamePlaysPerDay - used, TrustedClock.untilMidnight(now, off), day);
  }

  /// Spends one of today's plays; false if none are left (or no trusted time).
  Future<bool> useMinigamePlay(String game) async {
    final q = await minigameQuota(game);
    if (q == null || q.left <= 0) return false;
    final rec = profile.minigamePlays[game];
    final used = rec != null && rec.$1 == q.day ? rec.$2 : 0;
    profile.minigamePlays[game] = (q.day, used + 1);
    profile.changed();
    return true;
  }

  void awardMinigameBits(int bits) {
    if (bits <= 0) return;
    profile.bits += bits;
    profile.minigameBits += bits;
    profile.changed();
    notifyListeners();
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
  Spawn debugSpawnSong(Song song, {bool shiny = false, Edition edition = Edition.standard}) {
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
      rarity: catalog.rarityOf(known),
      shiny: shiny,
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      edition: edition,
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

/// One card from a pack; [duplicateCoins] > 0 when that variant was already
/// owned and the card went to the scrapyard instead.
class PackPull {
  const PackPull(this.card, this.duplicateCoins);
  final OwnedCard card;
  final int duplicateCoins;
  bool get duplicate => duplicateCoins > 0 || card.uid < 0;
}

class MinigameQuota {
  const MinigameQuota(this.left, this.resetIn, this.day);
  final int left;
  final Duration resetIn;
  final String day;
}
