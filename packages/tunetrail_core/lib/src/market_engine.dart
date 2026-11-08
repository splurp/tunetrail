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
  Listing createListing(String sellerId, CardPayload card, int price,
      {bool acceptsTrades = false}) {
    if (price < 1) throw MarketException('Price must be at least 1 coin');
    if (price > 100000000) throw MarketException('Price too high');
    if (listings.values.any((l) => l.sellerId == sellerId && l.card.uid == card.uid)) {
      throw MarketException('That card is already listed');
    }
    final l = Listing(
      id: _id('l'),
      sellerId: sellerId,
      sellerName: nameOf(sellerId),
      card: card,
      price: price,
      acceptsTrades: acceptsTrades,
      createdAt: now(),
    );
    listings[l.id] = l;
    _changed();
    return l;
  }

  /// Removes a listing and returns the escrowed card to the seller.
  CardPayload cancelListing(String sellerId, String listingId) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing not found');
    if (l.sellerId != sellerId) throw MarketException('Not your listing');
    listings.remove(listingId);
    _declineOffersFor(listingId, 'The listing was cancelled');
    _changed();
    return l.card;
  }

  /// Buys a listing. The buyer must have already debited [price] coins.
  CardPayload buyListing(String buyerId, String listingId, {int? expectedPrice}) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing no longer available');
    if (l.sellerId == buyerId) throw MarketException("You can't buy your own listing");
    if (expectedPrice != null && expectedPrice != l.price) {
      throw MarketException('Price changed');
    }
    listings.remove(listingId);
    _declineOffersFor(listingId, 'The card was sold to another player');
    _deliver(l.sellerId,
        '${nameOf(buyerId)} bought your ${l.card.title} for ${l.price} coins',
        coins: l.price);
    _changed();
    return l.card;
  }

  List<Listing> browse(ListingQuery q) {
    final text = q.text.trim().toLowerCase();
    final results = listings.values.where((l) {
      if (q.excludeSellerId != null && l.sellerId == q.excludeSellerId) {
        return false;
      }
      if (q.rarities.isNotEmpty && !q.rarities.contains(l.card.rarity.index)) {
        return false;
      }
      if (q.shinyOnly && !l.card.shiny) return false;
      if (q.normalOnly && l.card.shiny) return false;
      if (q.genres.isNotEmpty && !q.genres.contains(l.card.genreId)) return false;
      if (q.tradesOnly && !l.acceptsTrades) return false;
      if (text.isNotEmpty &&
          !l.card.title.toLowerCase().contains(text) &&
          !l.card.artistName.toLowerCase().contains(text) &&
          !l.card.albumTitle.toLowerCase().contains(text) &&
          !l.sellerName.toLowerCase().contains(text)) {
        return false;
      }
      return true;
    }).toList();
    switch (q.sort) {
      case ListingSort.newest:
        results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case ListingSort.priceLow:
        results.sort((a, b) => a.price.compareTo(b.price));
      case ListingSort.priceHigh:
        results.sort((a, b) => b.price.compareTo(a.price));
      case ListingSort.rarity:
        results.sort((a, b) {
          final c = b.card.rarity.index.compareTo(a.card.rarity.index);
          if (c != 0) return c;
          return (b.card.shiny ? 1 : 0).compareTo(a.card.shiny ? 1 : 0);
        });
    }
    if (q.offset >= results.length) return const [];
    return results.sublist(
        q.offset, math.min(results.length, q.offset + q.limit));
  }

  List<Listing> listingsOf(String sellerId) =>
      listings.values.where((l) => l.sellerId == sellerId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  // ----------------------------------------------------------------- trades
  TradeOffer createOffer(String fromId, String listingId,
      List<CardPayload> offeredCards, int offeredCoins) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing not found');
    if (!l.acceptsTrades) throw MarketException('This listing does not accept trades');
    if (l.sellerId == fromId) throw MarketException("You can't trade with yourself");
    if (offeredCards.isEmpty && offeredCoins <= 0) {
      throw MarketException('Offer at least one card or some coins');
    }
    if (offeredCards.length > 10) throw MarketException('Max 10 cards per offer');
    final o = TradeOffer(
      id: _id('t'),
      listingId: listingId,
      fromId: fromId,
      fromName: nameOf(fromId),
      toId: l.sellerId,
      offeredCards: offeredCards,
      offeredCoins: offeredCoins,
      requestedCard: l.card,
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
    _deliver(o.fromId, '${nameOf(o.toId)} accepted your trade for ${l.card.title}',
        cards: [l.card]);
    offers.remove(offerId);
    _declineOffersFor(o.listingId, 'The card was traded to another player');
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
    _deliver(o.fromId, '$why for ${o.requestedCard.title}; items returned',
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
      List<ShowcasePlaylist> playlists) {
    if (cards.length > 24) throw MarketException('Showcase holds up to 24 cards');
    final s = Showcase(
      playerId: playerId,
      playerName: nameOf(playerId),
      title: title.isEmpty ? "${nameOf(playerId)}'s Showcase" : title,
      cards: cards,
      playlists: playlists,
      updatedAt: now(),
      likes: showcases[playerId]?.likes ?? 0,
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
      };

  void loadJson(Map<String, dynamic> j) {
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
