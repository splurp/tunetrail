import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:tunetrail_core/tunetrail_core.dart';

import '../data/catalog.dart';

/// Market API used by the UI. Implemented locally (offline, with simulated
/// NPC traders) or remotely against the multiplayer server.
abstract class MarketBackend {
  String get label;
  Future<void> register(String id, String name);
  Future<List<Listing>> browse(ListingQuery q);
  Future<List<Listing>> myListings();
  Future<Listing> createListing(List<ListingItem> items, {int? folderPrice, String note = '', bool acceptsTrades = false});
  Future<List<CardPayload>> cancelListing(String listingId);
  Future<CardPayload> withdrawItem(String listingId, int cardUid);
  Future<List<CardPayload>> buy(String listingId, int price);
  Future<CardPayload> buyItem(String listingId, int cardUid, int price);
  Future<List<TradeOffer>> offers();
  Future<TradeOffer> createOffer(String listingId, List<CardPayload> cards, int coins, {String note = ''});
  Future<void> acceptOffer(String offerId);
  Future<void> declineOffer(String offerId);
  Future<List<InboxItem>> claimInbox();
  Future<List<Showcase>> showcases();
  Future<Showcase> setShowcase(String title, List<CardPayload> cards, List<ShowcasePlaylist> playlists, {List<FavoriteArtist> favoriteArtists = const []});
  Future<int> likeShowcase(String ownerId);
  void dispose() {}
}

// ===================================================================== local
/// Offline market backed by an in-process [MarketEngine] plus NPC traders
/// that list songs, buy fairly-priced listings and answer trade offers.
class LocalMarket extends MarketBackend {
  LocalMarket(this.dir, this.catalog, this.playerId, this.playerName);
  final Directory dir;
  final Catalog catalog;
  final String playerId;
  final String playerName;
  final MarketEngine engine = MarketEngine();
  final math.Random _r = math.Random();
  Timer? _tick;
  Timer? _save;
  File get _file => File('${dir.path}/local_market.json');

  @override
  String get label => 'Local market (NPC traders)';

  static const _botNames = [
    'VinylVandal', 'BassDropBetty', 'LoFiLarry', 'SynthSam', 'TrebleTrish', 'MixtapeMo',
    'GrooveGuru', 'EchoEllie', 'RiffRaff', 'DJ Pebble', 'Crescendo', 'SubwooferSue',
    'NeonNoah', 'TempoTina', 'ChorusKid', 'PitchPerfect', 'HookHunter', 'B-Side Bea',
  ];

  Future<void> init() async {
    if (await _file.exists()) {
      try {
        engine.loadJson(jsonDecode(await _file.readAsString()) as Map<String, dynamic>);
      } catch (_) {}
    }
    engine.register(playerId, playerName);
    for (var i = 0; i < _botNames.length; i++) {
      engine.register('bot$i', _botNames[i], bot: true);
    }
    engine.onChanged = () {
      _save?.cancel();
      _save = Timer(const Duration(seconds: 2), () async {
        await _file.writeAsString(jsonEncode(engine.toJson()));
      });
    };
    _simulate(initial: true);
    _tick = Timer.periodic(const Duration(seconds: 20), (_) => _simulate());
  }

  CardPayload? _randomCard() {
    final rng = Rng(_r.nextInt(1 << 31) ^ DateTime.now().microsecondsSinceEpoch);
    final song = catalog.pickSong(rng, rarity: rng.rollRarity(luck: 1.6));
    if (song == null) return null;
    return song.toPayload(
      uid: DateTime.now().microsecondsSinceEpoch * 1000 + _r.nextInt(1000),
      rarity: catalog.rarityOf(song),
      shiny: rng.chance(40),
      acquiredAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _simulate({bool initial = false}) {
    if (catalog.size == 0) return;
    final bots = engine.players.values.where((p) => p.isBot).toList();
    // Bots keep the market stocked.
    final botListings = engine.listings.values.where((l) => l.sellerId.startsWith('bot')).length;
    final want = initial ? 80 : 60;
    const notes = [
      '', '', '', 'Clearing out my crate', 'Bundle deal!', 'Open to offers', 'Taking shinies in trade',
      'Price is firm', 'Looking for Legendaries', 'Quick sale', 'Fresh from the trail',
    ];
    for (var i = botListings; i < want; i++) {
      final bot = bots[_r.nextInt(bots.length)];
      final n = _r.nextInt(10) < 6 ? 1 : 2 + _r.nextInt(_r.nextInt(5) == 0 ? 10 : 4);
      final items = <ListingItem>[];
      for (var k = 0; k < n; k++) {
        final c = _randomCard();
        if (c == null) break;
        items.add(ListingItem(card: c, price: (suggestedPrice(c) * (0.7 + _r.nextDouble() * 0.9)).round().clamp(1, 1 << 30)));
      }
      if (items.isEmpty) break;
      final total = items.fold<int>(0, (a, x) => a + x.price);
      final discounted = items.length > 1 && _r.nextBool() ? (total * (0.75 + _r.nextDouble() * 0.2)).round() : null;
      engine.createListing(bot.id, items,
          folderPrice: discounted, note: notes[_r.nextInt(notes.length)], acceptsTrades: _r.nextInt(3) == 0);
      if (!initial && i > botListings + 3) break;
    }
    // Bots occasionally retire old listings.
    if (!initial && _r.nextInt(3) == 0) {
      final old = engine.listings.values.where((l) => l.sellerId.startsWith('bot')).toList();
      if (old.length > 40) {
        final l = old[_r.nextInt(old.length)];
        engine.cancelListing(l.sellerId, l.id);
      }
    }
    // Bots buy the player's songs or whole folders when priced reasonably.
    double chanceFor(int price, int fair) {
      final ratio = price / math.max(1, fair);
      return ratio <= 0.8 ? 0.6 : ratio <= 1.1 ? 0.3 : ratio <= 1.5 ? 0.1 : 0.02;
    }

    for (final l in engine.listingsOf(playerId)) {
      final ageMin = (DateTime.now().millisecondsSinceEpoch - l.createdAt) / 60000;
      if (ageMin < 0.3) continue;
      final bot = bots[_r.nextInt(bots.length)].id;
      final fairTotal = l.cards.fold<int>(0, (a, c) => a + c.fair);
      if (_r.nextDouble() < chanceFor(l.folderPrice, fairTotal)) {
        engine.buyListing(bot, l.id);
        continue;
      }
      for (final it in List.of(l.items)) {
        if (_r.nextDouble() < chanceFor(it.price, it.card.fair) * 0.6) engine.buyItem(bot, l.id, it.card.uid);
      }
    }
    // Bots respond to the player's trade offers on bot listings.
    for (final o in engine.offersFor(playerId).where((o) => o.fromId == playerId).toList()) {
      if (o.offeredValue >= o.requestedValue * (0.9 + _r.nextDouble() * 0.3)) {
        engine.acceptOffer(o.toId, o.id);
      } else if (_r.nextInt(2) == 0) {
        engine.declineOffer(o.toId, o.id);
      }
    }
    // Bots make trade offers on the player's trade-enabled listings.
    for (final l in engine.listingsOf(playerId).where((l) => l.acceptsTrades)) {
      final pending = engine.offers.values.any((o) => o.listingId == l.id);
      if (pending || _r.nextInt(3) != 0) continue;
      final c = _randomCard();
      if (c == null) continue;
      final need = l.cards.fold<int>(0, (a, x) => a + x.fair);
      final coins = math.max(0, (need * (0.8 + _r.nextDouble() * 0.5)).round() - c.fair);
      engine.createOffer(bots[_r.nextInt(bots.length)].id, l.id, [c], coins, note: _r.nextBool() ? 'Fair trade?' : '');
    }
    // Bot showcases.
    if (engine.showcases.length < 8) {
      for (final b in bots.take(8)) {
        if (engine.showcases.containsKey(b.id)) continue;
        final cards = [for (var i = 0; i < 6; i++) ?_randomCard()];
        engine.setShowcase(b.id, '${b.name}\'s Crate', cards,
            [ShowcasePlaylist(name: 'Heavy Rotation', cards: cards.take(4).toList())]);
        engine.showcases[b.id]!.likes = _r.nextInt(200);
      }
    }
  }

  @override
  Future<void> register(String id, String name) async => engine.register(id, name);
  @override
  Future<List<Listing>> browse(ListingQuery q) async => engine.browse(q);
  @override
  Future<List<Listing>> myListings() async => engine.listingsOf(playerId);
  @override
  Future<Listing> createListing(List<ListingItem> items, {int? folderPrice, String note = '', bool acceptsTrades = false}) async =>
      engine.createListing(playerId, items, folderPrice: folderPrice, note: note, acceptsTrades: acceptsTrades);
  @override
  Future<List<CardPayload>> cancelListing(String listingId) async => engine.cancelListing(playerId, listingId);
  @override
  Future<CardPayload> withdrawItem(String listingId, int cardUid) async => engine.withdrawItem(playerId, listingId, cardUid);
  @override
  Future<List<CardPayload>> buy(String listingId, int price) async => engine.buyListing(playerId, listingId, expectedPrice: price);
  @override
  Future<CardPayload> buyItem(String listingId, int cardUid, int price) async =>
      engine.buyItem(playerId, listingId, cardUid, expectedPrice: price);
  @override
  Future<List<TradeOffer>> offers() async => engine.offersFor(playerId);
  @override
  Future<TradeOffer> createOffer(String listingId, List<CardPayload> cards, int coins, {String note = ''}) async =>
      engine.createOffer(playerId, listingId, cards, coins, note: note);
  @override
  Future<void> acceptOffer(String offerId) async => engine.acceptOffer(playerId, offerId);
  @override
  Future<void> declineOffer(String offerId) async => engine.declineOffer(playerId, offerId);
  @override
  Future<List<InboxItem>> claimInbox() async => engine.claimInbox(playerId);
  @override
  Future<List<Showcase>> showcases() async => engine.browseShowcases();
  @override
  Future<Showcase> setShowcase(String title, List<CardPayload> cards, List<ShowcasePlaylist> playlists, {List<FavoriteArtist> favoriteArtists = const []}) async =>
      engine.setShowcase(playerId, title, cards, playlists, favoriteArtists: favoriteArtists);
  @override
  Future<int> likeShowcase(String ownerId) async => engine.likeShowcase(playerId, ownerId);

  @override
  void dispose() {
    _tick?.cancel();
    _save?.cancel();
    _file.writeAsStringSync(jsonEncode(engine.toJson()));
  }
}

// ==================================================================== remote
/// Online market: talks to `server/bin/server.dart`.
class RemoteMarket extends MarketBackend {
  RemoteMarket(this.baseUrl, this.playerId, this.playerName);
  final String baseUrl;
  final String playerId;
  final String playerName;
  final http.Client _c = http.Client();

  @override
  String get label => 'Online: $baseUrl';

  Map<String, String> get _h => {
        'content-type': 'application/json',
        'x-player-id': playerId,
        'x-player-name': Uri.encodeComponent(playerName),
      };

  Uri _u(String path, [Map<String, String>? q]) {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$b$path').replace(queryParameters: q);
  }

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? q}) async {
    final req = http.Request(method, _u(path, q))..headers.addAll(_h);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _c.send(req).timeout(const Duration(seconds: 12)));
    final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode != 200) {
      throw MarketException(decoded is Map ? '${decoded['error']}' : 'Server error ${res.statusCode}');
    }
    return decoded;
  }

  List<T> _list<T>(dynamic j, T Function(Map<String, dynamic>) f) =>
      [for (final x in (j as List)) f(x as Map<String, dynamic>)];

  @override
  Future<void> register(String id, String name) async => _send('GET', '/listings/mine');
  @override
  Future<List<Listing>> browse(ListingQuery q) async =>
      _list(await _send('GET', '/listings', q: q.toQueryParams()), Listing.fromJson);
  @override
  Future<List<Listing>> myListings() async => _list(await _send('GET', '/listings/mine'), Listing.fromJson);
  @override
  Future<Listing> createListing(List<ListingItem> items, {int? folderPrice, String note = '', bool acceptsTrades = false}) async =>
      Listing.fromJson(await _send('POST', '/listings', body: {
        'items': [for (final i in items) i.toJson()],
        'folderPrice': folderPrice,
        'note': note,
        'trades': acceptsTrades,
      }) as Map<String, dynamic>);
  @override
  Future<List<CardPayload>> cancelListing(String listingId) async =>
      _list(await _send('POST', '/listings/$listingId/cancel'), CardPayload.fromJson);
  @override
  Future<CardPayload> withdrawItem(String listingId, int cardUid) async =>
      CardPayload.fromJson(await _send('POST', '/listings/$listingId/items/$cardUid/withdraw') as Map<String, dynamic>);
  @override
  Future<List<CardPayload>> buy(String listingId, int price) async =>
      _list(await _send('POST', '/listings/$listingId/buy', body: {'price': price}), CardPayload.fromJson);
  @override
  Future<CardPayload> buyItem(String listingId, int cardUid, int price) async =>
      CardPayload.fromJson(await _send('POST', '/listings/$listingId/items/$cardUid/buy', body: {'price': price}) as Map<String, dynamic>);
  @override
  Future<List<TradeOffer>> offers() async => _list(await _send('GET', '/offers'), TradeOffer.fromJson);
  @override
  Future<TradeOffer> createOffer(String listingId, List<CardPayload> cards, int coins, {String note = ''}) async =>
      TradeOffer.fromJson(await _send('POST', '/offers', body: {
        'listingId': listingId,
        'cards': [for (final c in cards) c.toJson()],
        'coins': coins,
        'note': note,
      }) as Map<String, dynamic>);
  @override
  Future<void> acceptOffer(String offerId) async => _send('POST', '/offers/$offerId/accept');
  @override
  Future<void> declineOffer(String offerId) async => _send('POST', '/offers/$offerId/decline');
  @override
  Future<List<InboxItem>> claimInbox() async => _list(await _send('GET', '/inbox'), InboxItem.fromJson);
  @override
  Future<List<Showcase>> showcases() async => _list(await _send('GET', '/showcases'), Showcase.fromJson);
  @override
  Future<Showcase> setShowcase(String title, List<CardPayload> cards, List<ShowcasePlaylist> playlists, {List<FavoriteArtist> favoriteArtists = const []}) async =>
      Showcase.fromJson(await _send('PUT', '/showcases/me', body: {
        'title': title,
        'cards': [for (final c in cards) c.toJson()],
        'playlists': [for (final p in playlists) p.toJson()],
        'favArtists': [for (final a in favoriteArtists) a.toJson()],
      }) as Map<String, dynamic>);
  @override
  Future<int> likeShowcase(String ownerId) async =>
      ((await _send('POST', '/showcases/$ownerId/like') as Map)['likes'] as num).toInt();

  @override
  void dispose() => _c.close();
}
