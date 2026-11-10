import 'dart:math' as math;

import 'auction_models.dart';
import 'card_payload.dart';
import 'market_models.dart';
import 'rarity.dart';
import 'social_models.dart';
import 'song_catalog.dart';
import 'text_safety.dart';

/// Authoritative, in-memory player market.
///
/// Holds escrowed listings, trade offers, showcases and per-player inboxes.
/// The same engine powers:
///  * the offline "local market" inside the app (with NPC traders), and
///  * the multiplayer HTTP server in `server/`.
///
/// The engine credits coins and cards via inboxes and expects buyers to have
/// been debited already: by their game (local market), or by the server's
/// economy, which holds balances and collections ([onDeliver]).
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
  /// [song] and [playerId] (when known) go into [recentPulls].
  int? claimSerial(int songId, Edition edition, {SongInfo? song, String? playerId}) {
    if (!edition.serialized) return null;
    final key = '$songId:${edition.index}';
    final n = serials[key] ?? 0;
    if (n >= edition.maxSerials) return null;
    serials[key] = n + 1;
    if (song != null) {
      recentPulls.insert(0, {
        'song': song.toJson(),
        'ed': edition.index,
        'sn': n + 1,
        'at': now(),
        if (playerId != null) 'by': nameOf(playerId),
      });
      if (recentPulls.length > kRecentPulls) recentPulls.removeRange(kRecentPulls, recentPulls.length);
    }
    onChanged?.call();
    return n + 1;
  }

  /// The latest Canvas / Sample / Live editions pulled anywhere, newest
  /// first: {song, ed, sn, at, by}.
  final List<Map<String, dynamic>> recentPulls = [];
  static const kRecentPulls = 90;

  /// Recent pulls of [edition] (up to [limit]).
  List<Map<String, dynamic>> recentPullsOf(Edition edition, {int limit = 30}) =>
      recentPulls.where((p) => p['ed'] == edition.index).take(limit).toList();

  /// How many serials of [edition] for [songId] are still unclaimed.
  int serialsLeft(int songId, Edition edition) =>
      edition.serialized ? edition.maxSerials - (serials['$songId:${edition.index}'] ?? 0) : 0;
  final Map<String, List<InboxItem>> inboxes = {};
  final Map<String, Set<String>> showcaseLikes = {};
  int _counter = 0;

  /// Called whenever state changes (used by the server to persist).
  void Function()? onChanged;

  /// Something happened that [playerId] should hear about even when the
  /// game is closed (the server sends it as a push notification).
  void Function(String playerId, String title, String body)? onNotify;

  /// Push-notification tokens per player (a few devices each).
  final Map<String, List<String>> pushTokens = {};

  void _notify(String playerId, String title, String body) {
    if (players[playerId]?.isBot ?? false) return;
    onNotify?.call(playerId, title, body.length > 140 ? '${body.substring(0, 137)}…' : body);
  }

  /// Registers a device for [playerId]'s notifications (a token belongs to
  /// one player: signing in on a shared device moves it).
  void registerPushToken(String playerId, String token) {
    if (token.isEmpty || token.length > 4096) throw MarketException('Invalid push token');
    for (final l in pushTokens.values) {
      l.remove(token);
    }
    final list = pushTokens.putIfAbsent(playerId, () => [])..add(token);
    if (list.length > 5) list.removeAt(0);
    pushTokens.removeWhere((_, v) => v.isEmpty);
    _changed();
  }

  /// Forgets a token the push service rejected (app uninstalled etc.).
  void dropPushToken(String token) {
    for (final l in pushTokens.values) {
      l.remove(token);
    }
    pushTokens.removeWhere((_, v) => v.isEmpty);
    _changed();
  }

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
        id, () => MarketPlayer(id: id, name: name, isBot: bot, joinedAt: now()));
    // A chosen username only changes through [setUsername].
    if (!p.named) p.name = name;
    _changed();
    return p;
  }

  String nameOf(String id) => players[id]?.name ?? 'Unknown';

  /// Credits coins and cards straight to [playerId]'s server-side account
  /// (when balances live on the server). Returns true when it did, and the
  /// inbox item is then only a notice.
  bool Function(String playerId, int coins, List<CardPayload> cards)? onDeliver;

  void _deliver(String playerId, String message,
      {int coins = 0, List<CardPayload> cards = const []}) {
    final credited = (coins > 0 || cards.isNotEmpty) && (onDeliver?.call(playerId, coins, cards) ?? false);
    inboxes.putIfAbsent(playerId, () => []).add(InboxItem(
        id: _id('i'),
        message: message,
        coins: coins,
        cards: cards,
        createdAt: now(),
        credited: credited));
  }

  /// A message for [playerId] (in their inbox and as a notification).
  void notice(String playerId, String message, {String title = 'Tunetrail'}) {
    _deliver(playerId, message);
    _notify(playerId, title, message);
    _changed();
  }

  List<InboxItem> peekInbox(String playerId) =>
      List.unmodifiable(inboxes[playerId] ?? const []);

  /// Returns and clears everything waiting for [playerId].
  List<InboxItem> claimInbox(String playerId) {
    expireListings();
    settleAuctions();
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
    if (uids.any(_escrowedUids(sellerId).contains)) throw MarketException('One of those songs is already listed');
    _checkTradeable(items.map((i) => i.card));
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
      note: cleanUserText(note, maxLength: kMaxListingNote, multiline: true),
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
    _notify(l.sellerId, 'Sold!', '${nameOf(buyerId)} bought your $what for $price coins');
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
    _notify(l.sellerId, 'Sold!', '${nameOf(buyerId)} bought ${item.card.title} for ${item.price} coins');
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

  /// Returns listings older than [Listing.lifetime] to their sellers.
  int expireListings() {
    final t = now();
    final old = listings.values.where((l) => t >= l.expiresAt).toList();
    for (final l in old) {
      listings.remove(l.id);
      _declineOffersFor(l.id, 'The listing expired');
      final what = l.items.length == 1 ? l.card.title : 'folder of ${l.items.length} songs';
      _deliver(l.sellerId, 'Your listing of $what expired after 7 days — the songs are back in your collection', cards: l.cards.toList());
    }
    if (old.isNotEmpty) _changed();
    return old.length;
  }

  /// Sends a listing back to the top of the market.
  Listing bumpListing(String sellerId, String listingId) {
    final l = listings[listingId];
    if (l == null) throw MarketException('Listing not found');
    if (l.sellerId != sellerId) throw MarketException('Not your listing');
    final t = now();
    if (t < l.nextBumpAt) {
      final mins = ((l.nextBumpAt - t) / 60000).ceil();
      throw MarketException('You can bump this again in ${mins >= 60 ? '${(mins / 60).ceil()} h' : '$mins min'}');
    }
    l.bumpedAt = t;
    _changed();
    return l;
  }

  List<Listing> browse(ListingQuery q) {
    expireListings();
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
        results.sort((a, b) => b.bumpedAt.compareTo(a.bumpedAt));
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

  List<Listing> listingsOf(String sellerId) {
    expireListings();
    return listings.values.where((l) => l.sellerId == sellerId).toList()..sort((a, b) => b.bumpedAt.compareTo(a.bumpedAt));
  }

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
      note: cleanUserText(note, maxLength: kMaxListingNote, multiline: true),
      createdAt: now(),
    );
    offers[o.id] = o;
    _notify(o.toId, 'New trade offer', '${o.fromName} made an offer for your ${o.requestedLabel}');
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
    if (o.direct) {
      _acceptDirect(o);
      return;
    }
    final l = listings.remove(o.listingId);
    if (l == null) throw MarketException('Listing no longer exists');
    o.status = TradeStatus.accepted;
    _deliver(o.toId, 'Trade with ${o.fromName} complete',
        coins: o.offeredCoins, cards: o.offeredCards);
    _deliver(o.fromId, '${nameOf(o.toId)} accepted your trade for ${o.requestedLabel}', cards: l.cards.toList());
    _notify(o.fromId, 'Offer accepted', '${nameOf(o.toId)} accepted your trade for ${o.requestedLabel}');
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

  // ----------------------------------------------------------------- social
  /// Each player's public collection (uploaded by their game). Kept apart
  /// from [toJson]: the server stores collections one row per player.
  final Map<String, List<CardPayload>> collections = {};

  /// Called when a player's collection changes (the server saves it).
  void Function(String playerId)? onCollectionChanged;

  /// Direct messages per conversation ([_conv] key), oldest first.
  final Map<String, List<ChatMessage>> messages = {};

  /// When each player last read each conversation: player → other → ms.
  final Map<String, Map<String, int>> lastRead = {};
  final Map<String, List<int>> _recentSends = {};
  final Map<String, int> _collectionUploads = {};

  static const kMaxMessagesPerConversation = 300;
  static const kMaxCollection = 50000;
  static const kMaxPendingDirectOffers = 30;

  static String _conv(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  MarketPlayer _player(String id) {
    final p = players[id];
    if (p == null) throw MarketException('Player not found');
    return p;
  }

  bool _blockedBetween(String a, String b) =>
      (players[a]?.blocked.contains(b) ?? false) || (players[b]?.blocked.contains(a) ?? false);

  /// Whether [id] owns [name] (or nobody does).
  bool usernameAvailable(String name, {String? forId}) {
    final key = usernameKey(name.trim());
    return !players.values.any((p) => p.id != forId && (p.named || p.isBot) && usernameKey(p.name) == key);
  }

  /// Sets [id]'s unique username after checking the rules in
  /// [usernameError] and that no other player has the same (or a
  /// look-alike) name.
  MarketPlayer setUsername(String id, String raw) {
    final p = _player(id);
    final name = raw.trim();
    final err = usernameError(name);
    if (err != null) throw MarketException(err);
    if (!usernameAvailable(name, forId: id)) throw MarketException('That username is taken');
    final old = p.name;
    p
      ..name = name
      ..named = true;
    for (final l in listings.values) {
      if (l.sellerId == id) l.sellerName = name;
    }
    for (final o in offers.values) {
      if (o.fromId == id) o.fromName = name;
    }
    for (final a in auctions.values) {
      if (a.sellerId == id) a.sellerName = name;
      if (a.highBidderId == id) a.highBidderName = name;
    }
    final s = showcases[id];
    if (s != null) {
      s.playerName = name;
      if (s.title == "$old's Showcase") s.title = "$name's Showcase";
    }
    _changed();
    return p;
  }

  /// Updates [id]'s public profile details.
  void setPublicProfile(String id,
      {String? theme, int? level, Map<String, num>? stats, List<CardPayload>? editionShowcase, List<FavoriteArtist>? favoriteArtists, Map<String, dynamic>? look}) {
    final p = _player(id);
    if (look != null) {
      final id = RegExp(r'^[a-z]{2,10}_[a-z0-9_]{1,30}$');
      String? item(Object? v) => v is String && id.hasMatch(v) ? v : null;
      p.look = {
        if (look['color'] is num) 'color': (look['color'] as num).toInt() & 0xFFFFFFFF,
        for (final k in const ['hat', 'shirt', 'backpack', 'pet'])
          if (item(look[k]) != null) k: item(look[k]),
      };
    }
    if (favoriteArtists != null) {
      if (favoriteArtists.length > 5000) throw MarketException('Too many favourite artists');
      p.favoriteArtists = favoriteArtists;
    }
    if (theme != null) {
      if (theme.isNotEmpty && !RegExp(r'^pt_[a-z0-9_]{1,30}$').hasMatch(theme)) throw MarketException('Unknown profile theme');
      p.theme = theme;
    }
    if (level != null) p.level = level.clamp(1, 100000);
    if (stats != null) {
      p.stats = {
        for (final e in stats.entries.take(20))
          if (RegExp(r'^[a-zA-Z]{1,24}$').hasMatch(e.key) && e.value.isFinite) e.key: e.value,
      };
    }
    if (editionShowcase != null) p.editionShowcase = editionShowcase.take(3).toList();
    _changed();
  }

  /// Replaces [id]'s public collection. Pending direct offers for songs
  /// that are no longer in it are returned to their senders.
  void setCollection(String id, List<CardPayload> cards) {
    _player(id);
    if (cards.length > kMaxCollection) throw MarketException('Collection too large');
    final last = _collectionUploads[id] ?? 0;
    if (now() - last < 3000) throw MarketException('Collection updated too often');
    _collectionUploads[id] = now();
    final seen = <int>{};
    final clean = [for (final c in cards) if (seen.add(c.uid)) c];
    collections[id] = clean;
    final have = {for (final c in clean) c.uid};
    final stale = offers.values
        .where((o) => o.direct && o.toId == id && o.status == TradeStatus.pending && o.requestedCards.any((c) => !have.contains(c.uid)))
        .toList();
    for (final o in stale) {
      o.status = TradeStatus.declined;
      _returnOffer(o, '${nameOf(id)} no longer has those songs');
      offers.remove(o.id);
    }
    onCollectionChanged?.call(id);
    if (stale.isNotEmpty) _changed();
  }

  /// Players whose username contains [query] (exact and prefix matches
  /// first).
  List<PlayerSummary> searchPlayers(String query, {int limit = 30, String? excludeId}) {
    final q = usernameKey(query.trim());
    if (q.isEmpty) return const [];
    final hits = [
      for (final p in players.values)
        if (p.id != excludeId && (p.named || p.isBot) && usernameKey(p.name).contains(q)) p
    ];
    int score(MarketPlayer p) {
      final k = usernameKey(p.name);
      return k == q ? 0 : (k.startsWith(q) ? 1 : 2);
    }

    hits.sort((a, b) {
      final c = score(a).compareTo(score(b));
      return c != 0 ? c : a.name.length.compareTo(b.name.length);
    });
    return [for (final p in hits.take(limit)) _summary(p)];
  }

  PlayerSummary _summary(MarketPlayer p) =>
      PlayerSummary(id: p.id, name: p.name, theme: p.theme, level: p.level, cards: collections[p.id]?.length ?? 0);

  PublicProfile publicProfile(String id, {String? viewerId}) {
    final p = _player(id);
    return PublicProfile(
      id: p.id,
      name: p.name,
      theme: p.theme,
      level: p.level,
      joinedAt: p.joinedAt,
      stats: p.stats,
      editionShowcase: p.editionShowcase,
      favoriteArtists: p.favoriteArtists.isNotEmpty ? p.favoriteArtists : (showcases[id]?.favoriteArtists ?? const []),
      showcase: showcases[id],
      cardCount: collections[id]?.length ?? 0,
      blockedByMe: viewerId != null && (players[viewerId]?.blocked.contains(id) ?? false),
      isBot: p.isBot,
      look: p.look,
    );
  }

  /// A page of [id]'s collection, filtered by [text] (title, artist,
  /// album) and sorted by rarity (best first).
  CollectionPage collectionPage(String id, {String text = '', int offset = 0, int limit = 60}) {
    _player(id);
    final t = text.trim().toLowerCase();
    final all = [
      for (final c in collections[id] ?? const <CardPayload>[])
        if (t.isEmpty ||
            c.title.toLowerCase().contains(t) ||
            c.artistName.toLowerCase().contains(t) ||
            c.albumTitle.toLowerCase().contains(t))
          c
    ];
    int score(CardPayload c) => c.edition.index * 100 + c.rarity.index * 2 + (c.shiny ? 1 : 0);
    all.sort((a, b) {
      final s = score(b).compareTo(score(a));
      return s != 0 ? s : a.title.compareTo(b.title);
    });
    final from = offset.clamp(0, all.length);
    return CollectionPage(cards: all.sublist(from, math.min(all.length, from + limit.clamp(1, 200))), total: all.length);
  }

  /// Offers cards and/or coins for songs in another player's collection.
  /// The offered items are held (the sender's game has already removed
  /// them); the receiver hands the songs over by accepting.
  TradeOffer createDirectOffer(String fromId, String toId, List<int> requestedUids, List<CardPayload> offeredCards, int offeredCoins,
      {String note = ''}) {
    if (fromId == toId) throw MarketException("You can't trade with yourself");
    final to = _player(toId);
    if (to.isBot) throw MarketException('This trader only trades through the market');
    if (_blockedBetween(fromId, toId)) throw MarketException("You can't send offers to this player");
    if (requestedUids.isEmpty) throw MarketException('Pick at least one of their songs');
    if (requestedUids.length > kMaxListingItems || offeredCards.length > kMaxListingItems) {
      throw MarketException('Up to $kMaxListingItems songs on each side');
    }
    if (offeredCards.isEmpty && offeredCoins <= 0) throw MarketException('Offer at least one card or some coins');
    if (offeredCoins < 0 || offeredCoins > 1000000000) throw MarketException('Invalid coin amount');
    final pending = offers.values.where((o) => o.direct && o.fromId == fromId && o.status == TradeStatus.pending).length;
    if (pending >= kMaxPendingDirectOffers) throw MarketException('You have too many open offers — wait for replies first');
    final owned = {for (final c in collections[toId] ?? const <CardPayload>[]) c.uid: c};
    final requested = <CardPayload>[];
    for (final u in requestedUids.toSet()) {
      final c = owned[u];
      if (c == null) throw MarketException('${to.name} no longer has one of those songs');
      requested.add(c);
    }
    final o = TradeOffer(
      id: _id('d'),
      listingId: '',
      fromId: fromId,
      fromName: nameOf(fromId),
      toId: toId,
      offeredCards: offeredCards,
      offeredCoins: offeredCoins,
      requestedCards: requested,
      note: cleanUserText(note, maxLength: kMaxListingNote, multiline: true),
      createdAt: now(),
      direct: true,
    );
    offers[o.id] = o;
    _notify(toId, 'New trade offer', '${o.fromName} made an offer for your ${o.requestedLabel}');
    _changed();
    return o;
  }

  /// Takes cards out of [playerId]'s server-side account (a direct trade
  /// hands over songs from their collection). Returns false if they no
  /// longer have them all; nothing is taken then.
  bool Function(String playerId, List<CardPayload> cards)? onTake;

  void _acceptDirect(TradeOffer o) {
    if (onTake != null && !onTake!(o.toId, o.requestedCards)) {
      throw MarketException('You no longer have one of those songs');
    }
    o.status = TradeStatus.accepted;
    offers.remove(o.id);
    _deliver(o.toId, 'Trade with ${o.fromName} complete', coins: o.offeredCoins, cards: o.offeredCards);
    _deliver(o.fromId, '${nameOf(o.toId)} accepted your trade for ${o.requestedLabel}', cards: o.requestedCards);
    _notify(o.fromId, 'Offer accepted', '${nameOf(o.toId)} accepted your trade for ${o.requestedLabel}');
    final gone = {for (final c in o.requestedCards) c.uid};
    collections[o.toId]?.removeWhere((c) => gone.contains(c.uid));
    // Other offers for the same songs can't be completed any more.
    final clash = offers.values
        .where((x) => x.direct && x.toId == o.toId && x.status == TradeStatus.pending && x.requestedCards.any((c) => gone.contains(c.uid)))
        .toList();
    for (final x in clash) {
      x.status = TradeStatus.declined;
      _returnOffer(x, 'Those songs were traded to another player');
      offers.remove(x.id);
    }
    onCollectionChanged?.call(o.toId);
    _changed();
  }

  /// Blocks (or unblocks) [otherId] for [id]: no messages or offers either way.
  void setBlocked(String id, String otherId, bool blocked) {
    final p = _player(id);
    _player(otherId);
    if (id == otherId) throw MarketException("You can't block yourself");
    blocked ? p.blocked.add(otherId) : p.blocked.remove(otherId);
    if (blocked) {
      final open = offers.values
          .where((o) => o.direct && o.status == TradeStatus.pending && ((o.fromId == id && o.toId == otherId) || (o.fromId == otherId && o.toId == id)))
          .toList();
      for (final o in open) {
        o.status = TradeStatus.declined;
        _returnOffer(o, 'The offer was closed');
        offers.remove(o.id);
      }
    }
    _changed();
  }

  ChatMessage sendMessage(String fromId, String toId, String raw) {
    if (fromId == toId) throw MarketException("You can't message yourself");
    final to = _player(toId);
    _player(fromId);
    if (to.isBot) throw MarketException('This trader doesn\'t read messages');
    if (_blockedBetween(fromId, toId)) throw MarketException("You can't message this player");
    final text = cleanUserText(raw, maxLength: kMaxMessageLength, multiline: true);
    if (text.isEmpty) throw MarketException('Type a message');
    final t = now();
    final recent = _recentSends.putIfAbsent(fromId, () => [])..removeWhere((x) => t - x > 60000);
    if (recent.length >= 20) throw MarketException('You\'re sending messages too fast — wait a moment');
    recent.add(t);
    final m = ChatMessage(id: _id('m'), from: fromId, to: toId, text: text, at: t);
    final list = messages.putIfAbsent(_conv(fromId, toId), () => [])..add(m);
    if (list.length > kMaxMessagesPerConversation) list.removeRange(0, list.length - kMaxMessagesPerConversation);
    lastRead.putIfAbsent(fromId, () => {})[toId] = t;
    _notify(toId, nameOf(fromId), text);
    _changed();
    return m;
  }

  /// [id]'s conversations, most recent first.
  List<Conversation> conversations(String id) {
    final out = <Conversation>[];
    for (final e in messages.entries) {
      final parts = e.key.split('|');
      if (parts.length != 2 || !parts.contains(id) || e.value.isEmpty) continue;
      final other = parts[0] == id ? parts[1] : parts[0];
      final read = lastRead[id]?[other] ?? 0;
      final unread = e.value.where((m) => m.to == id && m.at > read).length;
      final o = players[other];
      out.add(Conversation(otherId: other, otherName: o?.name ?? 'Unknown', otherTheme: o?.theme ?? '', last: e.value.last, unread: unread));
    }
    out.sort((a, b) => b.last.at.compareTo(a.last.at));
    return out;
  }

  int unreadCount(String id) => conversations(id).fold(0, (a, c) => a + c.unread);

  /// Messages between [id] and [otherId] (oldest first); marks them read.
  List<ChatMessage> thread(String id, String otherId) {
    final list = messages[_conv(id, otherId)] ?? const <ChatMessage>[];
    if (list.isNotEmpty) {
      final r = lastRead.putIfAbsent(id, () => {});
      if ((r[otherId] ?? 0) < list.last.at) {
        r[otherId] = list.last.at;
        _changed();
      }
    }
    return List.of(list);
  }

  // --------------------------------------------------------------- auctions
  final Map<String, Auction> auctions = {};

  /// Songs an admin has blocked (reported content): they can't be listed,
  /// auctioned or showcased, and games show cover art instead of video.
  final Set<int> blockedSongs = {};

  void _checkTradeable(Iterable<CardPayload> cards) {
    for (final c in cards) {
      if (blockedSongs.contains(c.songId)) throw MarketException('${c.title} can\'t be traded or showcased right now');
    }
  }

  Set<int> _escrowedUids(String sellerId) => {
        for (final l in listings.values.where((l) => l.sellerId == sellerId)) ...l.cards.map((c) => c.uid),
        for (final a in auctions.values.where((a) => a.sellerId == sellerId)) ...a.cards.map((c) => c.uid),
      };

  /// Puts 1–20 songs up for auction. The seller's game has already removed
  /// them from its collection (they're held until the auction ends).
  Auction createAuction(String sellerId, List<CardPayload> cards,
      {required int startPrice, int increment = kMinBidIncrement, int? buyNow, Duration duration = const Duration(hours: 24), String note = ''}) {
    if (cards.isEmpty) throw MarketException('Add at least one song');
    if (cards.length > kMaxListingItems) throw MarketException('An auction holds up to $kMaxListingItems songs');
    if (startPrice < 1 || startPrice > 100000000) throw MarketException('Starting price must be at least 1 coin');
    if (increment < kMinBidIncrement || increment > 100000000) throw MarketException('The bid increment is at least $kMinBidIncrement coins');
    if (buyNow != null && (buyNow <= startPrice || buyNow > 1000000000)) throw MarketException('Buy It Now must be more than the starting price');
    if (!kAuctionDurations.contains(duration)) throw MarketException('Choose 1, 3, 6, 12 or 24 hours');
    final uids = <int>{};
    for (final c in cards) {
      if (!uids.add(c.uid)) throw MarketException('A song appears twice');
    }
    if (uids.any(_escrowedUids(sellerId).contains)) throw MarketException('One of those songs is already on the market');
    _checkTradeable(cards);
    final t = now();
    final a = Auction(
      id: _id('a'),
      sellerId: sellerId,
      sellerName: nameOf(sellerId),
      cards: List.of(cards),
      startPrice: startPrice,
      increment: increment,
      buyNow: buyNow,
      note: cleanUserText(note, maxLength: kMaxListingNote, multiline: true),
      createdAt: t,
      endsAt: t + duration.inMilliseconds,
    );
    auctions[a.id] = a;
    _changed();
    return a;
  }

  void _refundHighBid(Auction a, String why) {
    final prev = a.highBidderId;
    if (prev == null) return;
    _deliver(prev, '$why — your ${a.highBid} coins were returned', coins: a.highBid);
    _notify(prev, 'Outbid', '$why (${a.label})');
  }

  /// Bids [amount] coins (already held by the bidder's game). In the last
  /// five minutes, every bid adds 30 seconds.
  Auction bid(String bidderId, String auctionId, int amount) {
    settleAuctions();
    final a = auctions[auctionId];
    if (a == null) throw MarketException('This auction has ended');
    if (a.sellerId == bidderId) throw MarketException("You can't bid on your own auction");
    if (a.highBidderId == bidderId) throw MarketException('You\'re already the highest bidder');
    if (amount < a.minBid) throw MarketException('Bid at least ${a.minBid} coins');
    if (amount > 1000000000) throw MarketException('That bid is too high');
    final t = now();
    _refundHighBid(a, 'You were outbid on ${a.label}');
    a
      ..highBid = amount
      ..highBidderId = bidderId
      ..highBidderName = nameOf(bidderId)
      ..bids += 1;
    if (a.endsAt - t < kSnipeWindow.inMilliseconds) a.endsAt += kSnipeExtension.inMilliseconds;
    _notify(a.sellerId, 'New bid', '${nameOf(bidderId)} bid $amount coins on your ${a.label}');
    if (a.buyNow != null && amount >= a.buyNow!) _finishAuction(a);
    _changed();
    return a;
  }

  /// Buys the auction outright at its Buy It Now price (already held by
  /// the buyer's game).
  List<CardPayload> buyAuctionNow(String buyerId, String auctionId, {int? expectedPrice}) {
    settleAuctions();
    final a = auctions[auctionId];
    if (a == null) throw MarketException('This auction has ended');
    if (a.sellerId == buyerId) throw MarketException("You can't buy your own auction");
    if (!a.buyNowOpen) throw MarketException('Buy It Now is no longer available');
    if (expectedPrice != null && expectedPrice != a.buyNow) throw MarketException('Price changed');
    _refundHighBid(a, 'Someone bought ${a.label} outright');
    auctions.remove(a.id);
    _deliver(a.sellerId, '${nameOf(buyerId)} bought your ${a.label} for ${a.buyNow} coins (Buy It Now)', coins: a.buyNow!);
    _notify(a.sellerId, 'Sold!', '${nameOf(buyerId)} bought your ${a.label} for ${a.buyNow} coins');
    _changed();
    return a.cards.toList();
  }

  /// Takes an auction down (only while nobody has bid).
  List<CardPayload> cancelAuction(String sellerId, String auctionId) {
    final a = auctions[auctionId];
    if (a == null) throw MarketException('Auction not found');
    if (a.sellerId != sellerId) throw MarketException('Not your auction');
    if (a.highBidderId != null) throw MarketException('Auctions with bids can\'t be cancelled');
    auctions.remove(a.id);
    _changed();
    return a.cards.toList();
  }

  void _finishAuction(Auction a) {
    auctions.remove(a.id);
    final winner = a.highBidderId;
    if (winner == null) {
      _deliver(a.sellerId, 'Your auction of ${a.label} ended without bids — the songs are back in your collection', cards: a.cards.toList());
      _notify(a.sellerId, 'Auction ended', 'No bids on your ${a.label}');
      return;
    }
    _deliver(winner, 'You won ${a.label} for ${a.highBid} coins', cards: a.cards.toList());
    _notify(winner, 'You won!', 'You won ${a.label} for ${a.highBid} coins');
    _deliver(a.sellerId, '${a.highBidderName} won your ${a.label} for ${a.highBid} coins', coins: a.highBid);
    _notify(a.sellerId, 'Sold at auction', '${a.highBidderName} won your ${a.label} for ${a.highBid} coins');
  }

  /// Ends auctions whose time is up. Returns how many ended.
  int settleAuctions() {
    final t = now();
    final done = auctions.values.where((a) => t >= a.endsAt).toList();
    for (final a in done) {
      _finishAuction(a);
    }
    if (done.isNotEmpty) _changed();
    return done.length;
  }

  /// Auctions matching [q] (song filters, text also matches the seller),
  /// ending soonest first.
  List<Auction> browseAuctions(ListingQuery q) {
    settleAuctions();
    final text = q.text.trim().toLowerCase();
    final out = auctions.values.where((a) {
      if (q.excludeSellerId != null && a.sellerId == q.excludeSellerId) return false;
      final sellerHit = text.isNotEmpty && (a.sellerName.toLowerCase().contains(text) || a.note.toLowerCase().contains(text));
      return a.cards.any((c) => _matches(c, q, sellerHit ? '' : text));
    }).toList()
      ..sort((a, b) => a.endsAt.compareTo(b.endsAt));
    if (q.offset >= out.length) return const [];
    return out.sublist(q.offset, math.min(out.length, q.offset + q.limit));
  }

  /// [playerId]'s auctions, and auctions they're currently winning.
  List<Auction> auctionsOf(String playerId) {
    settleAuctions();
    return auctions.values.where((a) => a.sellerId == playerId || a.highBidderId == playerId).toList()
      ..sort((a, b) => a.endsAt.compareTo(b.endsAt));
  }

  // ---------------------------------------------------------------- reports
  final List<Report> reports = [];

  /// Files a report for admins to review.
  Report fileReport(String reporterId, ReportKind kind, String targetId, String targetLabel, String reason, String details, {CardPayload? card}) {
    _player(reporterId);
    final allowed = kind == ReportKind.song ? kSongReportReasons : kPlayerReportReasons;
    if (!allowed.contains(reason)) throw MarketException('Choose a reason');
    if (kind == ReportKind.player) {
      if (targetId == reporterId) throw MarketException("You can't report yourself");
      _player(targetId);
    }
    final t = now();
    final today = reports.where((r) => r.reporterId == reporterId && t - r.createdAt < const Duration(days: 1).inMilliseconds).length;
    if (today >= 20) throw MarketException('You\'ve sent a lot of reports today — try again tomorrow');
    if (reports.any((r) => !r.resolved && r.reporterId == reporterId && r.kind == kind && r.targetId == targetId)) {
      throw MarketException('You\'ve already reported this — we\'ll look at it soon');
    }
    final r = Report(
      id: _id('r'),
      kind: kind,
      reporterId: reporterId,
      reporterName: nameOf(reporterId),
      targetId: targetId,
      targetLabel: cleanUserText(targetLabel, maxLength: 120),
      reason: reason,
      details: cleanUserText(details, maxLength: 1000, multiline: true),
      createdAt: t,
      card: card,
    );
    reports.add(r);
    if (reports.length > 5000) reports.removeWhere((x) => x.resolved);
    _changed();
    return r;
  }

  void resolveReport(String id) {
    for (final r in reports) {
      if (r.id == id) r.resolved = true;
    }
    _changed();
  }

  /// Blocks (or unblocks) a song: no trading or showcasing, no video.
  void setSongBlocked(int songId, bool blocked) {
    blocked ? blockedSongs.add(songId) : blockedSongs.remove(songId);
    if (blocked) {
      for (final r in reports) {
        if (r.kind == ReportKind.song && r.targetId == '$songId') r.resolved = true;
      }
    }
    _changed();
  }

  // -------------------------------------------------------------- showcases
  Showcase setShowcase(String playerId, String title, List<CardPayload> cards,
      List<ShowcasePlaylist> playlists, {List<FavoriteArtist> favoriteArtists = const []}) {
    if (favoriteArtists.length > kMaxFavoriteArtists) throw MarketException('Up to $kMaxFavoriteArtists favourite artists');
    if (cards.length > kMaxShowcaseCards) throw MarketException('A showcase holds up to $kMaxShowcaseCards cards');
    if (cards.isEmpty) throw MarketException('Add at least one card to your showcase');
    title = cleanUserText(title, maxLength: 60);
    _checkTradeable(cards);
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

  /// Showcases, newest first.
  List<Showcase> browseShowcases({int offset = 0, int limit = 30}) {
    final all = showcases.values.where((s) => s.cards.isNotEmpty).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (offset >= all.length) return const [];
    return all.sublist(offset, math.min(all.length, offset + limit));
  }

  /// Takes [playerId]'s showcase down.
  void removeShowcase(String playerId) {
    if (showcases.remove(playerId) != null) _changed();
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
        'pulls': recentPulls,
        'messages': {
          for (final e in messages.entries) e.key: [for (final m in e.value) m.toJson()]
        },
        'lastRead': lastRead,
        'push': pushTokens,
        'auctions': [for (final a in auctions.values) a.toJson()],
        'reports': [for (final r in reports) r.toJson()],
        'blockedSongs': blockedSongs.toList(),
      };

  void loadJson(Map<String, dynamic> j) {
    serials
      ..clear()
      ..addAll({for (final e in (j['serials'] as Map<String, dynamic>? ?? const {}).entries) e.key: (e.value as num).toInt()});
    recentPulls
      ..clear()
      ..addAll([for (final p in (j['pulls'] as List? ?? const [])) Map<String, dynamic>.from(p as Map)]);
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
    messages.clear();
    (j['messages'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      messages[k] = [for (final m in (v as List)) ChatMessage.fromJson(m as Map<String, dynamic>)];
    });
    auctions
      ..clear()
      ..addEntries([
        for (final a in (j['auctions'] as List? ?? const [])) MapEntry((a as Map<String, dynamic>)['id'] as String, Auction.fromJson(a)),
      ]);
    reports
      ..clear()
      ..addAll([for (final r in (j['reports'] as List? ?? const [])) Report.fromJson(r as Map<String, dynamic>)]);
    blockedSongs
      ..clear()
      ..addAll([for (final x in (j['blockedSongs'] as List? ?? const [])) (x as num).toInt()]);
    pushTokens.clear();
    (j['push'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      pushTokens[k] = [for (final t in v as List) t as String];
    });
    lastRead.clear();
    (j['lastRead'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      lastRead[k] = {for (final e in (v as Map<String, dynamic>).entries) e.key: (e.value as num).toInt()};
    });
  }
}

/// Suggested listing price for a card (rounded to a "nice" number).
int suggestedPrice(CardPayload c) {
  final v = fairValue(c.rarity, c.shiny, popularity: c.rank);
  if (v < 50) return v;
  if (v < 500) return (v / 5).round() * 5;
  return (v / 50).round() * 50;
}
