import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../build_flags.dart';
import '../data/catalog.dart';
import '../data/collection.dart';
import '../data/deezer_api.dart';
import '../data/models.dart';
import '../data/profile.dart';
import '../data/samples.dart';
import '../map3d/map_data.dart';
import '../map3d/props3d.dart';
import 'genre_zones.dart';
import 'google_auth.dart';
import 'movie_service.dart';
import 'push_service.dart';
import 'profile_themes.dart';
import 'sample_player.dart';
import 'audio_service.dart';
import 'location_service.dart';
import 'market_service.dart';
import 'purchase_service.dart';
import 'quests.dart';
import 'spawns.dart';
import 'store_catalog.dart';
import 'trusted_clock.dart';

part 'economy_client.dart';

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

  /// The server economy (when the server has one).
  EconomyClient? _econ;

  /// Coins, bits, items and cards live on the server: actions are server
  /// requests.
  bool get serverEconomy => _econ != null && profile.econImported && market is RemoteMarket;
  EconomyClient get econ => _econ!;

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
    location.joystickMode = kAdminBuild && profile.debugEnabled && profile.joystickEnabled;
    location.speedMultiplier = profile.speedMultiplier;
    location.onTravel = _onTravel;
    location.addListener(_onLocation);
    catalog.addListener(_onCatalog);
    profile.addListener(notifyListeners);
    mapData.addListener(_onMapData);
    mapData.buildingsEnabled = profile.showBuildings;
    mapData.ensureAround(location.position.latitude, location.position.longitude);
    collection.addListener(notifyListeners);
    collection.addListener(_scheduleCollectionSync);
    profile.addListener(_scheduleProfileSync);
    // Beat-synced animation (pets) uses the same calibration as the catch ring.
    void latency() => audio.outputLatency = 0.045 + profile.beatOffsetMs / 1000;
    latency();
    profile.addListener(latency);

    SampleLibrary.overrides
      ..clear()
      ..addAll(profile.sampleOverrides);
    for (final s in SampleLibrary.all) {
      catalog.addSongs([s.song]);
    }
    // A song has exactly one rarity (from its popularity): re-rate cards
    // from older versions before folding duplicates.
    // (Cards on the server keep the server's rarities.)
    if (!profile.econImported) {
      collection.normalizeRarities((id) {
        final s = catalog.songs[id];
        return s == null ? null : catalog.rarityOf(s);
      });
    }
    // One copy per variant: fold any older duplicates into the scrapyard.
    final dups = profile.econImported ? const <OwnedCard>[] : collection.removeDuplicateVariants();
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
    _scheduleCollectionSync(soon: true);
    _scheduleProfileSync();
  }

  // ---------------------------------------------------------------- market
  Future<void> _connectMarket() async {
    // Builds with a server always trade online (no offline NPC market);
    // admin builds may point at another server.
    final server = PlayerProfile.builtInServer.isNotEmpty && !kAdminBuild ? PlayerProfile.builtInServer : profile.serverUrl;
    if (PlayerProfile.builtInServer.isNotEmpty) {
      profile
        ..marketMode = MarketMode.online
        ..serverUrl = server;
    }
    _econ = null;
    if (profile.marketMode == MarketMode.online) {
      market = RemoteMarket(server, profile.playerId, profile.name, token: profile.authToken);
      _marketReady = true;
      try {
        await market.register(profile.playerId, profile.name);
        unawaited(refreshAccount());
        return;
      } catch (e) {
        if (PlayerProfile.builtInServer.isEmpty) {
          toast('Market server unreachable — using local market');
        } else {
          return; // Stay online; requests retry as the player uses the market.
        }
      }
      if (PlayerProfile.builtInServer.isNotEmpty) return;
    }
    final local = LocalMarket(dir, catalog, profile.playerId, profile.name);
    await local.init();
    market = local;
    _marketReady = true;
  }

  /// Songs blocked by admins (reported content): no trading, showcasing or
  /// video. Refreshed on connect.
  Set<int> blockedSongs = {};

  Future<void> refreshBlockedSongs() async {
    try {
      blockedSongs = await market.blockedSongs();
    } catch (_) {}
  }

  /// Sends a report about a song card or a player to the admins.
  Future<void> report(ReportKind kind, String targetId, String label, String reason, String details, {CardPayload? card}) =>
      market.report(kind, targetId, label, reason, details, card: card);

  /// Account details from the server: admin flag and unread messages.
  Future<void> refreshAccount() async {
    unawaited(refreshBlockedSongs());
    final m = market;
    if (m is! RemoteMarket || (profile.authToken.isEmpty && onlineAccounts)) return;
    try {
      final j = await m.me();
      profile.isAdmin = j['admin'] as bool? ?? false;
      unreadMessages.value = (j['unread'] as num?)?.toInt() ?? unreadMessages.value;
      profile.changed();
      if (j['economy'] == true) await _startEconomy(m, j['imported'] == true);
    } catch (_) {}
    await registerPush();
  }

  /// Moves this player's progress to the server the first time (or picks
  /// up the server's copy on a new device), then follows the server.
  Future<void> _startEconomy(RemoteMarket m, bool imported) async {
    final e = _econ ??= EconomyClient(this, m);
    if (!imported) {
      // Before importing, the account must be this player's for good.
      if (onlineAccounts && profile.authToken.isEmpty) return;
      await e.importProgress();
      toast('Your progress is now saved on the server');
    } else {
      if (!profile.econImported) {
        // A new device, or progress moved from another one: the server's wins.
        profile.econImported = true;
        profile.econRev = -1;
      }
      await e.sync();
    }
    _refreshSpawns(force: true);
    unawaited(refreshQuests());
    notifyListeners();
  }

  /// Signs this device up for push notifications (messages, sales, offers).
  Future<void> registerPush() async {
    if (!PushService.available || profile.authToken.isEmpty || !profile.usernameSet) return;
    final t = await PushService.token();
    if (t == null) return;
    try {
      await market.registerPush(t);
    } catch (_) {}
  }

  /// Signs in with Google through the game server; the account then owns
  /// this player's market activity on every device.
  Future<String?> signInWithGoogle() async {
    try {
      final idToken = await GoogleAuth.idToken();
      final base = profile.serverUrl.endsWith('/') ? profile.serverUrl.substring(0, profile.serverUrl.length - 1) : profile.serverUrl;
      final res = await http.post(Uri.parse('$base/auth/google'), headers: {'content-type': 'application/json'}, body: jsonEncode({'idToken': idToken})).timeout(const Duration(seconds: 15));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) return j['error'] as String? ?? 'Sign-in failed (${res.statusCode})';
      final needsName = j['needsUsername'] as bool? ?? false;
      profile
        ..authToken = j['token'] as String
        ..playerId = j['playerId'] as String
        ..usernameSet = !needsName
        ..marketMode = MarketMode.online;
      if (!needsName) profile.name = j['name'] as String? ?? profile.name;
      profile.changed();
      market.dispose();
      await _connectMarket();
      notifyListeners();
      _scheduleCollectionSync(soon: true);
      return null;
    } catch (e) {
      return '$e'.replaceFirst('Bad state: ', '');
    }
  }

  Future<void> signOut() async {
    await GoogleAuth.signOut();
    profile
      ..authToken = ''
      ..accountName = ''
      ..usernameSet = false;
    profile.changed();
    market.dispose();
    await _connectMarket();
    notifyListeners();
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
        // On the server economy the coins and cards are already in the
        // account (synced below).
        if (!i.credited && !serverEconomy) {
          if (i.coins > 0) profile.coins += i.coins;
          for (final c in i.cards) {
            acquirePayload(c, CardSource.trade);
          }
        }
        if (i.message.contains('accepted your trade')) newOffers.value++;
        if (i.message.contains('accepted') || i.message.contains('Trade with')) {
          profile.tradesCompleted++;
          unawaited(audio.playSfx(Sfx.tradeAccepted));
        }
        if (i.message.contains('won your') || i.message.contains('bought your')) {
          newSales.value++;
          profile.cardsSold++;
          unawaited(audio.playSfx(Sfx.sold));
        }
        toast(i.message);
      }
      if (items.isNotEmpty) {
        if (serverEconomy) await econ.sync();
        profile.changed();
        notifyListeners();
      }
      // New trade offers on my listings.
      final incoming = [for (final o in await market.offers()) if (o.toId == profile.playerId) o];
      final fresh = incoming.where((o) => !_seenOffers.contains(o.id)).toList();
      if (_offersPrimed) newOffers.value += fresh.length;
      if (_offersPrimed && fresh.isNotEmpty) {
        unawaited(audio.playSfx(Sfx.offer));
        toast(fresh.length == 1 ? 'New trade offer from ${fresh.first.fromName}' : '${fresh.length} new trade offers');
      }
      _seenOffers.addAll(incoming.map((o) => o.id));
      _offersPrimed = true;
      final unread = await market.unreadMessages();
      if (unread > unreadMessages.value) unawaited(audio.playSfx(Sfx.offer));
      unreadMessages.value = unread;
    } catch (_) {}
  }

  // ------------------------------------------------------------- accounts
  /// This build has online accounts (a server and Google sign-in built in):
  /// new players sign in and pick a username before playing.
  bool get onlineAccounts => GoogleAuth.available && PlayerProfile.builtInServer.isNotEmpty;

  /// First-run setup still has steps left.
  bool get needsOnboarding =>
      !_skipOnboarding && onlineAccounts && (profile.authToken.isEmpty || !profile.usernameSet || !profile.onboarded);
  bool _skipOnboarding = false;

  /// Debug players can skip account setup for this session.
  void skipOnboardingForNow() {
    _skipOnboarding = true;
    notifyListeners();
  }

  /// Unread direct messages (refreshed with the inbox).
  final ValueNotifier<int> unreadMessages = ValueNotifier(0);

  /// New trade offers and accepted offers since the Offers page was opened.
  final ValueNotifier<int> newOffers = ValueNotifier(0);

  /// Songs sold since the My listings page was opened.
  final ValueNotifier<int> newSales = ValueNotifier(0);

  /// Everything new for the Market tab badge.
  late final Listenable marketActivity = Listenable.merge([unreadMessages, newOffers, newSales]);
  int get marketBadge => unreadMessages.value + newOffers.value + newSales.value;

  /// Null when [name] can be the player's username, else why not.
  Future<String?> checkUsername(String name) async {
    final err = usernameError(name.trim());
    if (err != null) return err;
    try {
      return await market.checkUsername(name.trim());
    } catch (e) {
      return '$e';
    }
  }

  /// Claims [name] as this player's unique username.
  /// Bits the next username change costs (the first change is free).
  int get usernameChangeCost => !profile.usernameSet || profile.usernameChanges == 0 ? 0 : 100;

  Future<void> chooseUsername(String name) async {
    final changing = profile.usernameSet;
    final cost = usernameChangeCost;
    if (changing && name.trim() == profile.name) return;
    if (profile.bits < cost) throw MarketException('Changing your username again costs $cost bits');
    final (chosen, token) = await market.setUsername(name.trim());
    if (serverEconomy) {
      await econ.sync();
    } else if (changing) {
      profile.bits -= cost;
      profile.usernameChanges++;
    }
    profile
      ..name = chosen
      ..usernameSet = true;
    if (token != null && token.isNotEmpty) profile.authToken = token;
    profile.changed();
    _scheduleCollectionSync(soon: true);
    _profileSig = '';
    _scheduleProfileSync();
  }

  void finishOnboarding() {
    unawaited(registerPush());
    profile.onboarded = true;
    profile.changed();
    notifyListeners();
  }

  /// Whether public data (collection, profile) can be sent to the market.
  bool _marketReady = false;
  bool get _canPublish => _marketReady && (market is LocalMarket || (profile.authToken.isNotEmpty && profile.usernameSet));

  Timer? _collectionSync;
  Timer? _profileSync;
  String _profileSig = '';

  /// Uploads the collection other players browse, at most every ~20 s.
  void _scheduleCollectionSync({bool soon = false}) {
    // Server accounts' collections are on the server already.
    if (!_canPublish || serverEconomy) return;
    if (!soon && _collectionSync?.isActive == true) return;
    _collectionSync?.cancel();
    _collectionSync = Timer(Duration(seconds: soon ? 2 : 20), () async {
      if (!_canPublish) return;
      try {
        await market.uploadCollection([for (var i = 0; i < collection.length; i++) collection.at(i).toPayload()]);
      } catch (_) {
        _collectionSync = Timer(const Duration(minutes: 2), () => _scheduleCollectionSync(soon: true));
      }
    });
  }

  Map<String, num> get _publicStats => {
        'caught': profile.totalCaught,
        'shinies': profile.shinyCaught,
        'km': (profile.metersWalked / 100).round() / 10,
        'packs': profile.packsOpened,
        'trades': profile.tradesCompleted,
        'unique': collection.uniqueSongCount,
      };

  /// Sends the public profile (theme, level, stats, showcased editions)
  /// when it changes.
  void _scheduleProfileSync() {
    if (!_canPublish) return;
    final sig = '${profile.profileTheme}|${profile.level}|${profile.editionShowcase.join(',')}|${profile.totalCaught ~/ 10}|${profile.tradesCompleted}|'
        '${profile.favoriteArtists.map((a) => a.id).join(',')}';
    if (sig == _profileSig) return;
    _profileSync?.cancel();
    _profileSync = Timer(const Duration(seconds: 4), () async {
      try {
        await market.setPublicProfile(
          theme: profile.profileTheme,
          level: profile.level,
          stats: _publicStats,
          editions: [for (final u in profile.editionShowcase) ?collection.byUid(u)?.toPayload()],
          favoriteArtists: profile.favoriteArtists,
        );
        _profileSig = sig;
      } catch (_) {}
    });
  }

  void setProfileTheme(String id) {
    if (!profile.owned.contains(id)) return;
    profile.profileTheme = id;
    profile.changed();
  }

  /// Buys a profile theme with bits and puts it on.
  Future<void> buyProfileTheme(ProfileTheme t) async {
    if (profile.owned.contains(t.id)) return setProfileTheme(t.id);
    if (serverEconomy) {
      await econ.call('POST', _debugFree ? '/admin/econ/free/${t.id}' : '/shop/${t.id}/buy');
      profile.profileTheme = t.id;
      profile.changed();
      toast('Unlocked ${t.name}');
      return;
    }
    if (!(kAdminBuild && profile.freePurchases && profile.debugEnabled)) {
      if (profile.bits < t.price) throw MarketException('Not enough bits');
      profile.bits -= t.price;
    }
    profile.owned.add(t.id);
    profile.profileTheme = t.id;
    profile.changed();
    toast('Unlocked ${t.name}');
  }

  void _econChanged() => notifyListeners();

  bool get _debugFree => kAdminBuild && profile.freePurchases && profile.debugEnabled;

  /// On the server economy: runs a market request (the server holds and
  /// pays the cards and coins), then syncs the account.
  Future<T> _serverTrade<T>(Future<T> Function() f) async {
    try {
      return await f();
    } finally {
      await econ.sync();
    }
  }

  /// Offers cards and/or coins for songs in another player's collection.
  Future<void> makeDirectOffer(String toId, String toName, List<CardPayload> wanted, List<int> uids, int coins, {String note = ''}) async {
    if (coins < 0) throw MarketException('Invalid coin amount');
    if (profile.coins < coins) throw MarketException('Not enough coins');
    final cards = [for (final u in uids) ?collection.byUid(u)];
    if (serverEconomy) {
      await _serverTrade(() => market.createDirectOffer(toId, [for (final w in wanted) w.uid], [for (final c in cards) c.toPayload()], coins, note: note));
      return;
    }
    for (final c in cards) {
      _removeFromPlaylists(c.uid);
      collection.remove(c.uid);
    }
    profile.coins -= coins;
    profile.changed();
    try {
      await market.createDirectOffer(toId, [for (final w in wanted) w.uid], [for (final c in cards) c.toPayload()], coins, note: note);
    } catch (e) {
      for (final c in cards) {
        acquirePayload(c.toPayload(), c.source);
      }
      profile.coins += coins;
      profile.changed();
      rethrow;
    }
  }

  // ----------------------------------------------------------- acquiring
  /// Adds a card unless the player already owns that exact variant (song ×
  /// rarity × shiny × edition); a duplicate goes straight to the scrapyard
  /// for its coin value instead. Returns the new card, or null for a
  /// duplicate (the coins credited are in [lastDuplicateCoins]).
  OwnedCard? acquire(int songId, Rarity rarity, bool shiny, Edition edition, CardSource source,
      {int? uid, bool notify = true, bool announce = true, int serial = 0}) {
    if (edition != Edition.standard) shiny = false;
    // Editions are never auto-scrapped: each copy has its own serial.
    // One rarity per song, whatever the source says.
    final known = catalog.songs[songId];
    if (known != null) rarity = catalog.rarityOf(known);
    if (edition == Edition.standard && collection.ownsVariant(songId, rarity, shiny, edition)) {
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
    if (serverEconomy) {
      await _serverTrade(() => market.createListing([for (final c in cards) ListingItem(card: c.toPayload(), price: prices[c.uid]!)],
          folderPrice: folderPrice, note: note, acceptsTrades: trades));
      unawaited(audio.playSfx(Sfx.list));
      return;
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
    if (serverEconomy) return _serverTrade(() => market.cancelListing(l.id));
    for (final c in await market.cancelListing(l.id)) {
      acquirePayload(c, CardSource.market);
    }
  }

  Future<void> withdrawFromListing(Listing l, int cardUid) async {
    if (serverEconomy) return _serverTrade(() => market.withdrawItem(l.id, cardUid));
    acquirePayload(await market.withdrawItem(l.id, cardUid), CardSource.market);
  }

  /// Buys a whole folder at its folder price.
  Future<void> buyListing(Listing l) async {
    final price = l.folderPrice;
    if (profile.coins < price) throw MarketException('Not enough coins');
    if (serverEconomy) return _serverTrade(() => market.buy(l.id, price));
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
    if (serverEconomy) return _serverTrade(() => market.buyItem(l.id, item.card.uid, item.price));
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
    if (serverEconomy) return _serverTrade(() => market.createOffer(l.id, [for (final c in cards) c.toPayload()], coins, note: note));
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

  // ------------------------------------------------------------- auctions
  /// Puts songs up for auction; they're held until it ends.
  Future<Auction> createAuction(List<int> uids, {required int startPrice, required int increment, int? buyNow, required Duration duration, String note = ''}) async {
    final cards = [for (final u in uids) ?collection.byUid(u)];
    if (cards.length != uids.length) throw MarketException('You no longer own one of those songs');
    if (serverEconomy) {
      return _serverTrade(() => market.createAuction([for (final c in cards) c.toPayload()],
          startPrice: startPrice, increment: increment, buyNow: buyNow, duration: duration, note: note));
    }
    for (final c in cards) {
      _removeFromPlaylists(c.uid);
      collection.remove(c.uid);
    }
    try {
      return await market.createAuction([for (final c in cards) c.toPayload()],
          startPrice: startPrice, increment: increment, buyNow: buyNow, duration: duration, note: note);
    } catch (e) {
      for (final c in cards) {
        acquirePayload(c.toPayload(), c.source);
      }
      rethrow;
    }
  }

  /// Bids [amount] coins; they're held until you're outbid (then returned
  /// through the inbox) or win.
  Future<Auction> placeBid(Auction a, int amount) async {
    if (profile.coins < amount) throw MarketException('Not enough coins');
    if (serverEconomy) return _serverTrade(() => market.bid(a.id, amount));
    profile.coins -= amount;
    profile.changed();
    try {
      return await market.bid(a.id, amount);
    } catch (e) {
      profile.coins += amount;
      profile.changed();
      rethrow;
    }
  }

  Future<void> buyAuctionNow(Auction a) async {
    final price = a.buyNow;
    if (price == null) throw MarketException('No Buy It Now price');
    if (profile.coins < price) throw MarketException('Not enough coins');
    if (serverEconomy) {
      await _serverTrade(() => market.buyAuctionNow(a.id, price));
      unawaited(audio.playSfx(Sfx.tradeAccepted));
      return;
    }
    profile.coins -= price;
    profile.changed();
    try {
      for (final c in await market.buyAuctionNow(a.id, price)) {
        acquirePayload(c, CardSource.market, keepUid: false);
      }
      unawaited(audio.playSfx(Sfx.tradeAccepted));
    } catch (e) {
      profile.coins += price;
      profile.changed();
      rethrow;
    }
  }

  Future<void> cancelAuction(Auction a) async {
    if (serverEconomy) return _serverTrade(() => market.cancelAuction(a.id));
    for (final c in await market.cancelAuction(a.id)) {
      acquirePayload(c, CardSource.market);
    }
  }

  Future<void> acceptOffer(TradeOffer o) async {
    if (!o.direct) {
      await market.acceptOffer(o.id);
      await syncInbox();
      return;
    }
    if (serverEconomy) {
      await _serverTrade(() => market.acceptOffer(o.id));
      await syncInbox();
      return;
    }
    // A direct offer is for songs in this collection: hand them over.
    final mine = <OwnedCard>[];
    for (final w in o.requestedCards) {
      final c = collection.byUid(w.uid);
      if (c == null) throw MarketException('You no longer have ${w.title} — decline this offer instead');
      mine.add(c);
    }
    for (final c in mine) {
      _removeFromPlaylists(c.uid);
      collection.remove(c.uid);
    }
    try {
      await market.acceptOffer(o.id);
    } catch (e) {
      for (final c in mine) {
        acquirePayload(c.toPayload(), c.source);
      }
      rethrow;
    }
    await syncInbox();
  }

  Future<void> declineOffer(TradeOffer o) async {
    await market.declineOffer(o.id);
    await syncInbox();
  }

  /// Bits it costs to put up (or replace) a showcase.
  static const showcaseCost = 100;

  /// Puts the player's showcase (up to 10 cards) on the market for
  /// [showcaseCost] bits. One showcase per player: this replaces the last.
  Future<void> publishShowcase() async {
    final cards = [for (final u in profile.showcaseCards.take(kMaxShowcaseCards)) ?collection.byUid(u)?.toPayload()];
    if (cards.isEmpty) throw MarketException('Add at least one card');
    if (profile.bits < showcaseCost) throw MarketException('A showcase costs $showcaseCost bits');
    await market.setShowcase(profile.showcaseTitle, cards, const []);
    if (serverEconomy) {
      await econ.sync();
    } else {
      profile.bits -= showcaseCost;
    }
    profile.showcasePublished = true;
    profile.changed();
  }

  Future<void> removeShowcase() async {
    await market.removeShowcase();
    profile.showcasePublished = false;
    profile.changed();
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
    if (serverEconomy) {
      unawaited(_fetchServerSpawns());
      return;
    }
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

  bool _spawnFetching = false;
  bool _spawnFetchAgain = false;

  /// Spawns that turned out to have no live footage (their Live edition is
  /// shown, and caught, as a regular card).
  final Set<String> _noLive = {};

  /// Asks the server what's spawned around the player. The game sends its
  /// genre zones per map cell (the server mixes them with the time of day).
  Future<void> _fetchServerSpawns() async {
    if (_spawnFetching) {
      _spawnFetchAgain = true;
      return;
    }
    _spawnFetching = true;
    try {
      final pos = location.position;
      final (_, cy) = WorldSpawner.cellOf(pos.latitude, pos.longitude);
      final cells = <String, Map<String, double>>{};
      for (var dy = -2; dy <= 2; dy++) {
        final row = cy + dy;
        final cx = (pos.longitude / WorldSpawner.lngDegForRow(row)).floor();
        for (var dx = -2; dx <= 2; dx++) {
          final (lat, lng) = WorldSpawner.cellCenter(cx + dx, row);
          final bias = zones.sample(lat, lng).genreBias;
          if (bias.isNotEmpty) cells['${cx + dx}:$row'] = {for (final e in bias.entries) '${e.key}': e.value};
        }
      }
      final j = await econ.call('POST', '/spawns', body: {
        'lat': pos.latitude,
        'lng': pos.longitude,
        'tz': DateTime.now().timeZoneOffset.inMinutes,
        'zones': cells,
      });
      final now = DateTime.now();
      final list = <Spawn>[];
      for (final x in (j['spawns'] as List? ?? const [])) {
        final m = x as Map<String, dynamic>;
        final w = WorldSpawn.fromJson(m);
        final song = Song.fromInfo(w.song);
        catalog.addSongs([song]);
        if (m['paid'] == true) purchasedSpawns.add(w.id);
        final s = Spawn(
          id: w.id,
          point: LatLng(w.lat, w.lng),
          song: song,
          rarity: w.rarity,
          shiny: w.shiny,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(w.expiresAt),
          edition: w.edition,
        );
        list.add(_noLive.contains(s.id) ? s.withEdition(Edition.standard) : s);
      }
      _spawnMemo.removeWhere((_, s) => s.expiresAt.isBefore(now));
      spawns = list;
      zoneHere = zones.sample(pos.latitude, pos.longitude);
      _applyEditionAvailability();
    } catch (_) {
      // Retried on the next move or tick.
      _spawnCenter = null;
    } finally {
      _spawnFetching = false;
      if (_spawnFetchAgain) {
        _spawnFetchAgain = false;
        unawaited(_fetchServerSpawns());
      }
    }
  }

  /// Serials left per "songId:edition" (cached from the market backend).
  final Map<String, int> _serialsLeft = {};
  final Set<String> _serialsPending = {};
  final Set<int> _liveChecks = {};

  int? serialsLeft(int songId, Edition e) => _serialsLeft['$songId:${e.index}'];

  /// Edition spawns only stand while numbered copies remain: once every
  /// serial of a song's Canvas/Sample edition is claimed it spawns as a
  /// standard card instead.
  void _applyEditionAvailability() {
    var changed = false;
    final out = <Spawn>[];
    for (final s in spawns) {
      // A Live edition needs live footage of the song: look it up, and
      // spawn it as a standard card if there is none.
      if (s.edition == Edition.live) {
        final has = movies.hasLive(s.song.id);
        if (has == null && _liveChecks.add(s.song.id)) {
          unawaited(movies.liveClipFor(s.song).then((_) => _applyEditionAvailability()).catchError((_) {}));
        }
        if (has == false) {
          _noLive.add(s.id);
          final std = s.withEdition(Edition.standard);
          _spawnMemo[s.id] = std;
          out.add(std);
          changed = true;
          continue;
        }
      }
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
      (kAdminBuild && profile.debugEnabled && profile.unlimitedRange) ||
      metersBetween(location.position, s.point) <= catchRangeMeters;

  void _markSpent(Spawn s) {
    purchasedSpawns.remove(s.id);
    profile.spentSpawns[s.id] = s.expiresAt.millisecondsSinceEpoch + 60000;
    spawns = spawns.where((x) => x.id != s.id).toList();
    profile.changed();
    notifyListeners();
  }

  /// Coins to buy an out-of-range spawn without walking there: more for
  /// rarer songs and further away. Null when it can't be bought — in range
  /// (catch it!), or a Shiny / Canvas / Live / Sample, which you have to go
  /// to in person.
  int? spawnPrice(Spawn s) {
    if (s.shiny || s.edition != Edition.standard) return null;
    final d = metersBetween(location.position, s.point);
    if (d <= catchRangeMeters) return null;
    final (lo, hi) = mapPriceRange(s.rarity);
    // Just outside the catch circle costs the low end; the far edge of the
    // nearby area (~500 m) the high end.
    final t = ((d - catchRangeMeters) / (500 - catchRangeMeters)).clamp(0.0, 1.0);
    return ((lo + (hi - lo) * t) / 5).round() * 5;
  }

  /// Spawns paid for but not yet caught (the catch minigame follows; leaving
  /// it doesn't lose the purchase).
  final Set<String> purchasedSpawns = {};

  bool isPurchased(Spawn s) => purchasedSpawns.contains(s.id);

  /// Pays [spawnPrice] coins for an out-of-range spawn; the catch minigame
  /// then plays as usual, except the song can't get away.
  Future<void> buySpawn(Spawn s) async {
    if (isPurchased(s)) return;
    if (serverEconomy) {
      final p = location.position;
      await econ.call('POST', '/spawns/${Uri.encodeComponent(s.id)}/buy', body: {'lat': p.latitude, 'lng': p.longitude});
      purchasedSpawns.add(s.id);
      notifyListeners();
      return;
    }
    final price = spawnPrice(s);
    if (price == null) throw MarketException('This song can\'t be bought — go and catch it');
    if (profile.coins < price) throw MarketException('Not enough coins ($price needed)');
    profile.coins -= price;
    purchasedSpawns.add(s.id);
    profile.changed();
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
      // Every edition copy gets its own serial (editions are never
      // scrapped, so a second copy is kept).
      {
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

  final math.Random _throwRng = math.Random();

  /// One throw in the catch minigame with [acc]% timing (100 = a perfect
  /// beat: always caught, and shiny). [attempt] counts from 1. On the server
  /// economy the server rolls it; otherwise it's rolled here.
  Future<ThrowOutcome> throwAt(Spawn s, int acc, int attempt) async {
    lastCatchNote = null;
    if (serverEconomy) {
      final p = location.position;
      final j = await econ.call('POST', '/spawns/${Uri.encodeComponent(s.id)}/throw',
          body: {
            'lat': p.latitude,
            'lng': p.longitude,
            'acc': acc,
            if (_noLive.contains(s.id)) 'noLive': true,
            if (kAdminBuild && profile.debugEnabled && profile.unlimitedRange) 'unlimited': true,
          },
          source: CardSource.wild);
      final result = j['result'] as String? ?? 'slipped';
      if (result == 'slipped') return const ThrowOutcome('slipped');
      _markSpent(s);
      if (result == 'fled') return const ThrowOutcome('fled');
      unawaited(audio.playSfx(Sfx.catchSong));
      final c = CardPayload.fromJson(j['card'] as Map<String, dynamic>);
      final dup = (j['dupCoins'] as num?)?.toInt() ?? 0;
      lastDuplicateCoins = dup;
      lastCatchNote = j['note'] as String?;
      return ThrowOutcome('caught', card: dup > 0 ? null : collection.byUid(c.uid), duplicateCoins: dup, note: lastCatchNote);
    }
    final success = acc == 100 || isPurchased(s) || _throwRng.nextDouble() < catchChance(s.rarity, acc);
    if (success) {
      final card = await catchSpawn(s, perfect: acc == 100);
      return ThrowOutcome('caught', card: card, duplicateCoins: card == null ? lastDuplicateCoins : 0, note: lastCatchNote);
    }
    if (attempt >= kMaxThrows || _throwRng.nextDouble() < kFleeChance[s.rarity.index]) {
      fleeSpawn(s);
      return const ThrowOutcome('fled');
    }
    return const ThrowOutcome('slipped');
  }

  double _walkPending = 0;

  /// Walking is reported ~30×/s by the joystick and every few metres by GPS;
  /// committing each step saved the profile and rebuilt the whole map screen
  /// many times a second. Distance is batched into 25 m chunks instead.
  void _onTravel(double m) {
    profile.metersWalked += m;
    // (The server measures walking itself.)
    if (serverEconomy) return;
    _walkPending += m;
    if (_walkPending >= 25) {
      final whole = _walkPending.floor();
      _walkPending -= whole;
      questEvent(QuestKind.walkMeters, amount: whole);
    }
  }

  // ----------------------------------------------------------------- packs
  /// A song by one of the player's favourite artists, at least [min].
  Song? _favoriteSong(Rng rng, Rarity min) {
    final favs = catalog.favoriteArtists;
    if (favs.isEmpty) return null;
    final pool = [for (final s in catalog.songs.values) if (favs.contains(s.artistId) && catalog.rarityOf(s).index >= min.index) s];
    return pool.isEmpty ? null : pool[rng.nextInt(pool.length)];
  }

  /// A song of at least [min] rarity (rolled with the pack's odds).
  Song _packSong(Rng rng, PackDef p, Rarity min, {bool favorites = false}) {
    // Regular cards lean towards favourite artists (1 in 3); Shiny and
    // Canvas cards never do.
    if (favorites && rng.nextInt(3) == 0) {
      final f = _favoriteSong(rng, min);
      if (f != null) return f;
    }
    for (var tries = 0; tries < 12; tries++) {
      final cand = catalog.pickSong(rng, rarity: rng.rollRarity(minIndex: min.index, luck: p.luck));
      if (cand != null && catalog.rarityOf(cand).index >= min.index) return cand;
    }
    return catalog.pickSong(rng, rarity: min) ?? catalog.pickSong(rng)!;
  }

  /// Opens a pack; returns the new cards. Throws if not enough bits.
  /// Packs never contain Sample or Live editions.
  /// A pack or blind-box card from the server.
  PackPull _pull(Map<String, dynamic> j) {
    final c = CardPayload.fromJson(j['card'] as Map<String, dynamic>);
    final dup = (j['dup'] as num?)?.toInt();
    final owned = dup == null ? collection.byUid(c.uid) : null;
    if (owned != null) return PackPull(owned, 0);
    catalog.ensureFromPayload(c);
    final song = catalog.songs[c.songId] ?? Song.fromInfo(SongInfo(id: c.songId, title: c.title, artistId: c.artistId, artistName: c.artistName, albumId: c.albumId, albumTitle: c.albumTitle, coverMd5: c.coverMd5));
    return PackPull(OwnedCard(-1, song, c.rarity, c.shiny, false, DateTime.now(), CardSource.pack, c.edition, c.serial), dup ?? 0);
  }

  Future<List<PackPull>> openPack(PackDef p) async {
    if (profile.bits < p.bits) throw MarketException('Not enough bits');
    if (serverEconomy) {
      final j = await econ.call('POST', '/packs/${p.id}/open', source: CardSource.pack);
      return [for (final x in (j['pulls'] as List)) _pull(x as Map<String, dynamic>)];
    }
    if (catalog.size == 0) throw MarketException('Song catalog still loading');
    profile.bits -= p.bits;
    profile.changed();
    final rng = Rng(DateTime.now().microsecondsSinceEpoch ^ profile.packsOpened * 7919);
    // Which slots are special: shinies, and maybe one Canvas.
    final shiny = List.generate(p.cards, (_) => p.shinyOdds > 0 && rng.chance(p.shinyOdds));
    if (p.guaranteedShiny && !shiny.contains(true)) shiny[rng.nextInt(p.cards)] = true;
    var canvasSlot = -1;
    if (p.canvasOdds > 0 && rng.nextInt(p.canvasOdds) == 0) {
      canvasSlot = [for (var i = 0; i < p.cards; i++) if (!shiny[i]) i].firstOrNull ?? -1;
    }
    final rolls = <(Song, bool, bool)>[]; // song, shiny, canvas
    for (var i = 0; i < p.cards; i++) {
      final special = shiny[i] || i == canvasSlot;
      rolls.add((_packSong(rng, p, p.allMin, favorites: !special), shiny[i], i == canvasSlot));
    }
    // Guarantee: the last regular slot is redrawn at the guaranteed rarity.
    final g = p.guaranteedMin;
    if (g != null && !rolls.any((r) => catalog.rarityOf(r.$1).index >= g.index)) {
      final i = rolls.lastIndexWhere((r) => !r.$2 && !r.$3);
      final at = i < 0 ? rolls.length - 1 : i;
      rolls[at] = (_packSong(rng, p, g, favorites: !rolls[at].$2 && !rolls[at].$3), rolls[at].$2, rolls[at].$3);
    }
    final out = <PackPull>[];
    for (final r in rolls) {
      var ed = Edition.standard;
      var serial = 0;
      if (r.$3) {
        try {
          final n = await market.claimSerial(r.$1.id, Edition.canvas);
          if (n != null) {
            ed = Edition.canvas;
            serial = n;
          }
        } catch (_) {}
      }
      final rarity = catalog.rarityOf(r.$1);
      final isShiny = r.$2 && ed == Edition.standard;
      final card = acquire(r.$1.id, rarity, isShiny, ed, CardSource.pack, notify: false, announce: false, serial: serial);
      out.add(PackPull(card ?? OwnedCard(-1, r.$1, rarity, isShiny, false, DateTime.now(), CardSource.pack, ed), card == null ? lastDuplicateCoins : 0));
    }
    collection.commit();
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
    if (serverEconomy) {
      final j = await econ.call('POST', '/blindbox/${artist.id}/open', body: {'price': price}, source: CardSource.pack);
      return _pull(j['pull'] as Map<String, dynamic>);
    }
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
    if (p.bitsPrice > 0) {
      await buyWithBits(p);
      return PurchaseResult.granted;
    }
    final r = await purchases.buy(p, debugFree: kAdminBuild && profile.debugEnabled && profile.freePurchases);
    return r;
  }

  /// Buys a bits-priced item (pets).
  Future<void> buyWithBits(Product p) async {
    if (profile.owned.contains(p.id)) return;
    if (profile.bits < p.bitsPrice) throw MarketException('Not enough bits');
    if (serverEconomy) {
      await econ.call('POST', '/shop/${p.id}/buy');
      toast('Unlocked ${p.name}');
      return;
    }
    profile.bits -= p.bitsPrice;
    profile.owned.add(p.id);
    profile.changed();
    toast('Unlocked ${p.name}');
  }

  /// Gives a store item away (while real-money purchases aren't live).
  void grantFree(Product p) => _grantProduct(p);

  void _grantProduct(Product p) {
    if (serverEconomy) {
      unawaited(econ.call('POST', '/shop/${p.id}/grant').then((_) {
        toast(p.kind == ProductKind.bits ? '+${p.bits} bits' : 'Unlocked ${p.name}');
      }).catchError((Object e) {
        toast('Couldn\'t add ${p.name}: $e — it will be restored on the next connection');
      }));
      return;
    }
    if (p.kind == ProductKind.bits) {
      profile.bits += p.bits;
      toast('+${p.bits} bits');
    } else if (p.bundleOf != null) {
      profile.owned
        ..add(p.id)
        ..addAll(productsOfKind(p.bundleOf!).map((x) => x.id));
      toast('Unlocked the ${p.name}');
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
      case ProductKind.bundle:
        break;
    }
    profile.changed();
    notifyListeners();
  }

  /// Scrapyard value of a card: rarer and more-streamed songs pay more.
  int scrapValueOf(OwnedCard c) => scrapValue(c.rarity, c.shiny, c.song.rank, edition: c.edition);

  /// Scraps cards for coins. Returns the coins earned.
  Future<int> scrap(Iterable<int> uids) async {
    if (serverEconomy) {
      final j = await econ.call('POST', '/me/scrap', body: {'uids': uids.toList()});
      unawaited(audio.playSfx(Sfx.quicksell));
      return (j['coins'] as num?)?.toInt() ?? 0;
    }
    var total = 0;
    var n = 0;
    for (final uid in uids.toList()) {
      final c = collection.byUid(uid);
      if (c == null || !canScrap(c.edition)) continue;
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

  /// The server's quest board (on the server economy).
  Map<String, dynamic>? _board;
  final Map<String, int> _boardProgress = {};
  final Set<String> _boardClaimed = {};

  List<Quest> _boardList(String k) => [for (final q in (_board?[k] as List? ?? const [])) Quest.fromJson(q as Map<String, dynamic>)];

  /// Fetches the quest board and progress from the server.
  Future<void> refreshQuests() async {
    if (!serverEconomy) return;
    try {
      final j = await econ.call('GET', '/quests', q: {'tz': '${DateTime.now().timeZoneOffset.inMinutes}'});
      _board = j;
      _boardProgress.clear();
      _boardClaimed
        ..clear()
        ..addAll([for (final a in (j['albums'] as List? ?? const [])) '$a']);
      for (final k in ['daily', 'unlock', 'milestone']) {
        for (final q in (j[k] as List? ?? const [])) {
          final m = q as Map<String, dynamic>;
          _boardProgress[m['id'] as String] = (m['progress'] as num?)?.toInt() ?? 0;
          if (m['claimed'] == true) _boardClaimed.add(m['id'] as String);
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  List<Quest> get dailyQuests => serverEconomy ? _boardList('daily') : QuestBoard.daily(DateTime.now(), catalog);
  List<Quest> get unlockQuests => serverEconomy ? _boardList('unlock') : QuestBoard.unlocks(DateTime.now(), catalog);
  List<Quest> get milestoneQuests => serverEconomy ? _boardList('milestone') : QuestBoard.milestones();

  void questEvent(QuestKind kind, {int amount = 1, int? genreId}) {
    if (serverEconomy) return;
    _resetDailyIfNeeded();
    for (final q in dailyQuests) {
      if (q.kind != kind) continue;
      if (kind == QuestKind.catchGenre && q.genreId != genreId) continue;
      profile.questProgress[q.id] = (profile.questProgress[q.id] ?? 0) + amount;
    }
    profile.changed();
  }

  int questProgress(Quest q) {
    if (serverEconomy && q.kind != QuestKind.albumComplete) return _boardProgress[q.id] ?? 0;
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
  bool questClaimed(Quest q) => serverEconomy ? _boardClaimed.contains(q.id) : profile.questsClaimed.contains(q.id);

  Future<OwnedCard?> claimQuest(Quest q) async {
    if (!questDone(q) || questClaimed(q)) return null;
    if (serverEconomy) {
      final j = await econ.call('POST', '/quests/${Uri.encodeComponent(q.id)}/claim', source: CardSource.quest);
      _boardClaimed.add(q.id);
      unawaited(refreshQuests());
      final c = j['card'];
      return c == null ? null : collection.byUid((c as Map<String, dynamic>)['uid'] as int);
    }
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
  /// The round of [game] the player left unfinished, if any.
  Map<String, dynamic>? pendingMinigame(String game) => profile.minigameRounds[game];

  void savePendingMinigame(String game, Map<String, dynamic>? round) {
    final had = profile.minigameRounds.containsKey(game);
    if (round == null) {
      if (!had) return;
      profile.minigameRounds.remove(game);
    } else {
      profile.minigameRounds[game] = round;
    }
    profile.touch();
  }

  /// Debug: give back today's plays of every minigame.
  Future<void> resetMinigamePlays() async {
    if (serverEconomy) await econ.call('POST', '/admin/econ/minigames/reset');
    profile.minigamePlays.clear();
    profile.minigameRounds.clear();
    profile.changed();
    notifyListeners();
  }

  Future<MinigameQuota?> minigameQuota(String game) async {
    if (serverEconomy) {
      try {
        final j = await econ.market.send('GET', '/minigames/$game', q: {'tz': '${DateTime.now().timeZoneOffset.inMinutes}'}) as Map<String, dynamic>;
        return MinigameQuota((j['left'] as num).toInt(), Duration(milliseconds: (j['resetMs'] as num).toInt()), j['day'] as String);
      } catch (_) {
        return null;
      }
    }
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
    if (serverEconomy) {
      try {
        await econ.call('POST', '/minigames/$game/start', body: {'tz': DateTime.now().timeZoneOffset.inMinutes});
        return true;
      } catch (_) {
        return false;
      }
    }
    final q = await minigameQuota(game);
    if (q == null || q.left <= 0) return false;
    final rec = profile.minigamePlays[game];
    final used = rec != null && rec.$1 == q.day ? rec.$2 : 0;
    profile.minigamePlays[game] = (q.day, used + 1);
    profile.changed();
    return true;
  }

  /// Pays [bits] won in a round of [game] (on the server economy the server
  /// pays them, up to the round's maximum).
  void awardMinigameBits(int bits, {String? game}) {
    if (bits <= 0) return;
    if (serverEconomy) {
      if (game == null) return;
      unawaited(econ.call('POST', '/minigames/$game/award', body: {'bits': bits}).catchError((Object _) => <String, dynamic>{}));
      return;
    }
    profile.bits += bits;
    profile.minigameBits += bits;
    profile.changed();
    notifyListeners();
  }

  // ----------------------------------------------------------------- debug
  Future<void> debugSetBalances({int? coins, int? bits}) async {
    if (serverEconomy) {
      await econ.call('POST', '/admin/econ/balances', body: {'coins': ?coins, 'bits': ?bits});
      return;
    }
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
  Future<Spawn> debugSpawnSong(Song song, {bool shiny = false, Edition edition = Edition.standard}) async {
    catalog.addSongs([song]);
    final known = catalog.songs[song.id] ?? song;
    final rng = math.Random();
    final heading = (location.heading + (rng.nextDouble() - 0.5) * 60) * math.pi / 180;
    final dist = 18 + rng.nextDouble() * 12;
    final p = location.position;
    final lat = p.latitude + math.cos(heading) * dist / 111132.95;
    final lng = p.longitude + math.sin(heading) * dist / (111319.49 * math.cos(p.latitude * math.pi / 180));
    if (serverEconomy) {
      final j = await econ.market.send('POST', '/admin/econ/spawn', body: {'song': known.toInfo().toJson(), 'lat': lat, 'lng': lng, 'shiny': shiny, 'ed': edition.index})
          as Map<String, dynamic>;
      await _fetchServerSpawns();
      final w = WorldSpawn.fromJson(j);
      return spawns.firstWhere((x) => x.id == w.id,
          orElse: () => Spawn(id: w.id, point: LatLng(w.lat, w.lng), song: known, rarity: w.rarity, shiny: w.shiny, expiresAt: DateTime.fromMillisecondsSinceEpoch(w.expiresAt), edition: w.edition));
    }
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
    if (serverEconomy) {
      var added = 0;
      for (var left = n; left > 0; left -= 5000) {
        final j = await econ.call('POST', '/admin/econ/cards', body: {'n': math.min(left, 5000)}, source: CardSource.debug);
        added += (j['added'] as num?)?.toInt() ?? 0;
      }
      return added;
    }
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

  Future<void> debugClearCollection() async {
    if (serverEconomy) await econ.call('POST', '/admin/econ/clear');
    collection.clear();
    for (final p in profile.playlists) {
      p.cardUids.clear();
    }
    profile.showcaseCards.clear();
    profile.changed();
    notifyListeners();
  }

  Future<void> debugRespawn() async {
    if (serverEconomy) await econ.call('POST', '/admin/econ/respawn');
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
    _collectionSync?.cancel();
    _profileSync?.cancel();
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
