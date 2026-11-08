import 'dart:math' as math;

import 'card_payload.dart';
import 'market_models.dart';
import 'rarity.dart';

/// Authoritative, in-memory player market.
///
/// Holds escrowed listings, trade offers, showcases and per-player inboxes.
/// The same engine powers:
///  * the offline "local market" inside the app (with NPC traders), and
///  * the multiplayer HTTP server in `server/`.
///
/// Coin balances live on the client; the engine credits coins to sellers via
/// their inbox and expects buyers to have debited themselves. A production
/// deployment should move balances server-side (see README).
class MarketEngine {
  MarketEngine({int? seed}) : _rand = math.Random(seed);

  final math.Random _rand;
  final Map<String, MarketPlayer> players = {};
  final Map<String, Listing> listings = {};
  final Map<String, TradeOffer> offers = {};
  final Map<String, Showcase> showcases = {};

  /// Serial numbers handed out per "songId:edition" (the next number is
  /// count + 1). Editions have a hard cap per song.
  final Map<String, int> serials = {};

  /// Claims the next serial number of [edition] for [songId], or null once
  /// all of them have been claimed.
  int? claimSerial(int songId, Edition edition) {
    if (!edition.serialized) return null;
    final key = '$songId:${edition.index}';
    final n = serials[key] ?? 0;
    if (n >= edition.maxSerials) return null;
    serials[key] = n + 1;
    onChanged?.call();
    return n + 1;
  }

  /// How many serials of [edition] for [songId] are still unclaimed.
  int serialsLeft(int songId, Edition edition) =>
      edition.serialized ? edition.maxSerials - (serials['$songId:${edition.index}'] ?? 0) : 0;
  final Map<String, List<InboxItem>> inboxes = {};
  final Map<String, Set<String>> showcaseLikes = {};
  int _counter = 0;

  /// Called whenever state changes (used by the server to persist).
  void Function()? onChanged;

  int now() => DateTime.now().millisecondsSinceEpoch;

  String _id(String prefix) {
    _counter++;
    final r = _rand.nextInt(1 << 30).toRadixString(36);
    return '$prefix${now().toRadixString(36)}$_counter$r';
  }

  void _changed() => onChanged?.call();

  // ---------------------------------------------------------------- players
  MarketPlayer register(String id, String name, {bool bot = false}) {
    final p = players.putIfAbsent(
        id, () => MarketPlayer(id: id, name: name, isBot: bot));
    p.name = name;
    _changed();
    return p;
  }

  String nameOf(String id) => players[id]?.name ?? 'Unknown';

  void _deliver(String playerId, String message,
      {int coins = 0, List<CardPayload> cards = const []}) {
    inboxes.putIfAbsent(playerId, () => []).add(InboxItem(
        id: _id('i'),
        message: message,
        coins: coins,
        cards: cards,
        createdAt: now()));
  }

  List<InboxItem> peekInbox(String playerId) =>
      List.unmodifiable(inboxes[playerId] ?? const []);

  /// Returns and clears everything waiting for [playerId].
  List<InboxItem> claimInbox(String playerId) {
    final items = inboxes.remove(playerId) ?? const [];
    if (items.isNotEmpty) _changed();
    return items;
  }

  // --------------------------------------------------------------- listings
  /// Lists a folder of 1–20 songs. [folderPrice] (optional) is a bundle
  /// price; when null the folder costs the sum of the item prices.
  Listing createListing(String sellerId, List<ListingItem> items,
      {int? folderPrice, String note = '', bool acceptsTrades = false}) {
    if (items.isEmpty) throw MarketException('Add at least one song');
    if (items.length > kMaxListingItems) throw MarketException('A listing holds up to $kMaxListingItems songs');
    if (note.length > kMaxListingNote) throw MarketException('Notes are limited to $kMaxListingNote characters');
    final uids = <int>{};
    for (final i in items) {
      if (i.price < 1) throw MarketException('Every song needs a price of at least 1 coin');
      if (i.price > 100000000) throw MarketException('Price too high');
      if (!uids.add(i.card.uid)) throw MarketException('A song appears twice');
    }
    final listed = {for (final l in listings.values.where((l) => l.sellerId == sellerId)) ...l.cards.map((c) => c.uid)};
    if (uids.any(listed.contains)) throw MarketException('One of those songs is already listed');
    final total = items.fold<int>(0, (a, i) => a + i.price);
    if (folderPrice != null) {
      if (folderPrice < 1) throw MarketException('Folder price must be at least 1 coin');
      if (folderPrice > total) throw MarketException('Folder price can\'t be more than the songs\' total ($total)');
      if (folderPrice == total || items.length == 1) folderPrice = null;
    }
    final l = Listing(
      id: _id('l'),
      sellerId: sellerId,
      sellerName: nameOf(sellerId),
      items: List.of(items),
      manualFolderPrice: folderPrice,
      note: note.trim(),
      acceptsTrades: acceptsTrades,
      createdAt: now(),
    );
    listings[l.id] = l;
    _changed();
    return l;
  }

  /// Removes a whole listing and returns every escrowed card to the seller.
  List<CardPayload> cancelListing(String sellerId, String listingId) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing not found');
    if (l.sellerId != sellerId) throw MarketException('Not your listing');
    listings.remove(listingId);
    _declineOffersFor(listingId, 'The listing was cancelled');
    _changed();
    return l.cards.toList();
  }

  /// Removes one song from a seller's folder (returned to the seller).
  CardPayload withdrawItem(String sellerId, String listingId, int cardUid) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing not found');
    if (l.sellerId != sellerId) throw MarketException('Not your listing');
    final item = l.items.where((i) => i.card.uid == cardUid).firstOrNull;
    if (item == null) throw MarketException('That song is no longer in the listing');
    _removeItem(l, item, 'The seller changed the listing');
    _changed();
    return item.card;
  }

  /// Buys a whole folder. The buyer must already have debited the price.
  List<CardPayload> buyListing(String buyerId, String listingId, {int? expectedPrice}) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing no longer available');
    if (l.sellerId == buyerId) throw MarketException("You can't buy your own listing");
    final price = l.folderPrice;
    if (expectedPrice != null && expectedPrice != price) throw MarketException('Price changed');
    listings.remove(listingId);
    _declineOffersFor(listingId, 'The listing was sold to another player');
    final what = l.items.length == 1 ? l.card.title : 'folder of ${l.items.length} songs';
    _deliver(l.sellerId, '${nameOf(buyerId)} bought your $what for $price coins', coins: price);
    _changed();
    return l.cards.toList();
  }

  /// Buys a single song out of a folder at its own price.
  CardPayload buyItem(String buyerId, String listingId, int cardUid, {int? expectedPrice}) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing no longer available');
    if (l.sellerId == buyerId) throw MarketException("You can't buy your own listing");
    final item = l.items.where((i) => i.card.uid == cardUid).firstOrNull;
    if (item == null) throw MarketException('That song was already sold');
    if (expectedPrice != null && expectedPrice != item.price) throw MarketException('Price changed');
    _removeItem(l, item, 'A song in the folder was sold');
    _deliver(l.sellerId, '${nameOf(buyerId)} bought ${item.card.title} for ${item.price} coins', coins: item.price);
    _changed();
    return item.card;
  }

  /// Removes one item; a manual folder price shrinks proportionally, and
  /// pending trade offers (which were for the whole folder) are returned.
  void _removeItem(Listing l, ListingItem item, String why) {
    final before = l.itemsTotal;
    l.items.remove(item);
    if (l.items.isEmpty) {
      listings.remove(l.id);
    } else if (l.manualFolderPrice != null) {
      final scaled = (l.manualFolderPrice! * l.itemsTotal / before).round();
      l.manualFolderPrice = l.items.length == 1 || scaled >= l.itemsTotal ? null : scaled.clamp(1, l.itemsTotal);
    }
    _declineOffersFor(l.id, why);
  }

  bool _matches(CardPayload c, ListingQuery q, String text) {
    if (q.rarities.isNotEmpty && !q.rarities.contains(c.rarity.index)) return false;
    if (q.shinyOnly && !c.shiny) return false;
    if (q.normalOnly && c.shiny) return false;
    if (q.editions.isNotEmpty && !q.editions.contains(c.edition.index)) return false;
    if (q.serials.isNotEmpty && !q.serials.contains(c.serial)) return false;
    if (q.genres.isNotEmpty && !q.genres.contains(c.genreId)) return false;
    if (text.isNotEmpty &&
        !c.title.toLowerCase().contains(text) &&
        !c.artistName.toLowerCase().contains(text) &&
        !c.albumTitle.toLowerCase().contains(text)) {
      return false;
    }
    return true;
  }

  List<Listing> browse(ListingQuery q) {
    final text = q.text.trim().toLowerCase();
    final results = listings.values.where((l) {
      if (q.excludeSellerId != null && l.sellerId == q.excludeSellerId) return false;
      if (q.tradesOnly && !l.acceptsTrades) return false;
      final sellerHit = text.isNotEmpty && (l.sellerName.toLowerCase().contains(text) || l.note.toLowerCase().contains(text));
      final cardText = sellerHit ? '' : text;
      return l.cards.any((c) => _matches(c, q, cardText));
    }).toList();
    int best(Listing l) => l.cards.map((c) => c.rarity.index * 2 + (c.shiny ? 1 : 0)).reduce(math.max);
    switch (q.sort) {
      case ListingSort.newest:
        results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case ListingSort.priceLow:
        results.sort((a, b) => a.folderPrice.compareTo(b.folderPrice));
      case ListingSort.priceHigh:
        results.sort((a, b) => b.folderPrice.compareTo(a.folderPrice));
      case ListingSort.rarity:
        results.sort((a, b) => best(b).compareTo(best(a)));
    }
    if (q.offset >= results.length) return const [];
    return results.sublist(q.offset, math.min(results.length, q.offset + q.limit));
  }

  List<Listing> listingsOf(String sellerId) =>
      listings.values.where((l) => l.sellerId == sellerId).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  // ----------------------------------------------------------------- trades
  /// Offers cards and/or coins for a whole trade-enabled folder.
  TradeOffer createOffer(String fromId, String listingId, List<CardPayload> offeredCards, int offeredCoins, {String note = ''}) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing not found');
    if (!l.acceptsTrades) throw MarketException('This listing does not accept trades');
    if (l.sellerId == fromId) throw MarketException("You can't trade with yourself");
    if (offeredCards.isEmpty && offeredCoins <= 0) throw MarketException('Offer at least one card or some coins');
    if (offeredCards.length > kMaxListingItems) throw MarketException('Max $kMaxListingItems cards per offer');
    if (note.length > kMaxListingNote) throw MarketException('Notes are limited to $kMaxListingNote characters');
    final o = TradeOffer(
      id: _id('t'),
      listingId: listingId,
      fromId: fromId,
      fromName: nameOf(fromId),
      toId: l.sellerId,
      offeredCards: offeredCards,
      offeredCoins: offeredCoins,
      requestedCards: l.cards.toList(),
      note: note.trim(),
      createdAt: now(),
    );
    offers[o.id] = o;
    _changed();
    return o;
  }

  List<TradeOffer> offersFor(String playerId) => offers.values
      .where((o) =>
          (o.toId == playerId || o.fromId == playerId) &&
          o.status == TradeStatus.pending)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  void acceptOffer(String playerId, String offerId) {
    final o = offers[offerId];
    if (o == null || o.status != TradeStatus.pending) {
      throw MarketException('Offer is no longer pending');
    }
    if (o.toId != playerId) throw MarketException('Not your offer to accept');
    final l = listings.remove(o.listingId);
    if (l == null) throw MarketException('Listing no longer exists');
    o.status = TradeStatus.accepted;
    _deliver(o.toId, 'Trade with ${o.fromName} complete',
        coins: o.offeredCoins, cards: o.offeredCards);
    _deliver(o.fromId, '${nameOf(o.toId)} accepted your trade for ${o.requestedLabel}', cards: l.cards.toList());
    offers.remove(offerId);
    _declineOffersFor(o.listingId, 'The listing was traded to another player');
    _changed();
  }

  void declineOffer(String playerId, String offerId) {
    final o = offers[offerId];
    if (o == null || o.status != TradeStatus.pending) {
      throw MarketException('Offer is no longer pending');
    }
    if (o.toId != playerId && o.fromId != playerId) {
      throw MarketException('Not your offer');
    }
    o.status = o.fromId == playerId ? TradeStatus.cancelled : TradeStatus.declined;
    _returnOffer(o,
        o.status == TradeStatus.cancelled ? 'You cancelled your offer' : '${nameOf(o.toId)} declined your offer');
    offers.remove(offerId);
    _changed();
  }

  void _returnOffer(TradeOffer o, String why) {
    _deliver(o.fromId, '$why (${o.requestedLabel}); your offer was returned',
        coins: o.offeredCoins, cards: o.offeredCards);
  }

  void _declineOffersFor(String listingId, String why) {
    final toRemove = offers.values
        .where((o) => o.listingId == listingId && o.status == TradeStatus.pending)
        .toList();
    for (final o in toRemove) {
      o.status = TradeStatus.declined;
      _returnOffer(o, why);
      offers.remove(o.id);
    }
  }

  // -------------------------------------------------------------- showcases
  Showcase setShowcase(String playerId, String title, List<CardPayload> cards,
      List<ShowcasePlaylist> playlists, {List<FavoriteArtist> favoriteArtists = const []}) {
    if (favoriteArtists.length > kMaxFavoriteArtists) throw MarketException('Up to $kMaxFavoriteArtists favourite artists');
    if (cards.length > 24) throw MarketException('Showcase holds up to 24 cards');
    final s = Showcase(
      playerId: playerId,
      playerName: nameOf(playerId),
      title: title.isEmpty ? "${nameOf(playerId)}'s Showcase" : title,
      cards: cards,
      playlists: playlists,
      updatedAt: now(),
      likes: showcases[playerId]?.likes ?? 0,
      favoriteArtists: favoriteArtists,
    );
    showcases[playerId] = s;
    _changed();
    return s;
  }

  List<Showcase> browseShowcases({int offset = 0, int limit = 30}) {
    final all = showcases.values.toList()
      ..sort((a, b) {
        final c = b.likes.compareTo(a.likes);
        return c != 0 ? c : b.updatedAt.compareTo(a.updatedAt);
      });
    if (offset >= all.length) return const [];
    return all.sublist(offset, math.min(all.length, offset + limit));
  }

  int likeShowcase(String playerId, String ownerId) {
    final s = showcases[ownerId];
    if (s == null) throw MarketException('Showcase not found');
    final likes = showcaseLikes.putIfAbsent(ownerId, () => {});
    if (likes.add(playerId)) {
      s.likes++;
      _changed();
    }
    return s.likes;
  }

  // ------------------------------------------------------------ persistence
  Map<String, dynamic> toJson() => {
        'players': [for (final p in players.values) p.toJson()],
        'listings': [for (final l in listings.values) l.toJson()],
        'offers': [for (final o in offers.values) o.toJson()],
        'showcases': [for (final s in showcases.values) s.toJson()],
        'inboxes': {
          for (final e in inboxes.entries)
            e.key: [for (final i in e.value) i.toJson()]
        },
        'likes': {
          for (final e in showcaseLikes.entries) e.key: e.value.toList()
        },
        'counter': _counter,
        'serials': serials,
      };

  void loadJson(Map<String, dynamic> j) {
    serials
      ..clear()
      ..addAll({for (final e in (j['serials'] as Map<String, dynamic>? ?? const {}).entries) e.key: (e.value as num).toInt()});
    players
      ..clear()
      ..addEntries([
        for (final p in (j['players'] as List? ?? const []))
          MapEntry((p as Map<String, dynamic>)['id'] as String,
              MarketPlayer.fromJson(p))
      ]);
    listings
      ..clear()
      ..addEntries([
        for (final l in (j['listings'] as List? ?? const []))
          MapEntry((l as Map<String, dynamic>)['id'] as String,
              Listing.fromJson(l))
      ]);
    offers
      ..clear()
      ..addEntries([
        for (final o in (j['offers'] as List? ?? const []))
          MapEntry((o as Map<String, dynamic>)['id'] as String,
              TradeOffer.fromJson(o))
      ]);
    showcases
      ..clear()
      ..addEntries([
        for (final s in (j['showcases'] as List? ?? const []))
          MapEntry((s as Map<String, dynamic>)['playerId'] as String,
              Showcase.fromJson(s))
      ]);
    inboxes.clear();
    (j['inboxes'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      inboxes[k] = [
        for (final i in (v as List)) InboxItem.fromJson(i as Map<String, dynamic>)
      ];
    });
    showcaseLikes.clear();
    (j['likes'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      showcaseLikes[k] = {for (final x in (v as List)) x as String};
    });
    _counter = (j['counter'] as num?)?.toInt() ?? 0;
  }
}

/// Suggested listing price for a card (rounded to a "nice" number).
int suggestedPrice(CardPayload c) {
  final v = fairValue(c.rarity, c.shiny, popularity: c.rank);
  if (v < 50) return v;
  if (v < 500) return (v / 5).round() * 5;
  return (v / 50).round() * 50;
}
