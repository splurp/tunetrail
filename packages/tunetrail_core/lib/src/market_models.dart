import 'card_payload.dart';

class MarketPlayer {
  MarketPlayer({required this.id, required this.name, this.isBot = false});
  final String id;
  String name;
  final bool isBot;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'bot': isBot};
  factory MarketPlayer.fromJson(Map<String, dynamic> j) => MarketPlayer(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Player',
      isBot: j['bot'] as bool? ?? false);
}

/// Maximum songs in one listing folder.
const int kMaxListingItems = 20;

/// Maximum length of a listing note.
const int kMaxListingNote = 200;

/// One song inside a listing folder, with its own price.
class ListingItem {
  ListingItem({required this.card, required this.price});
  final CardPayload card;
  final int price;

  Map<String, dynamic> toJson() => {'card': card.toJson(), 'price': price};
  factory ListingItem.fromJson(Map<String, dynamic> j) =>
      ListingItem(card: CardPayload.fromJson(j['card'] as Map<String, dynamic>), price: (j['price'] as num).toInt());
}

/// A "folder" of 1–20 songs escrowed on the market. Buyers can take the
/// whole folder for [folderPrice] or individual songs at their own price.
class Listing {
  Listing({
    required this.id,
    required this.sellerId,
    required this.sellerName,
    required this.items,
    required this.acceptsTrades,
    required this.createdAt,
    this.manualFolderPrice,
    this.note = '',
  });

  final String id;
  final String sellerId;
  final String sellerName;
  final List<ListingItem> items;
  final bool acceptsTrades;
  final int createdAt;
  final String note;

  /// Seller-set folder price (a bundle discount); null = sum of items.
  int? manualFolderPrice;

  int get itemsTotal => items.fold<int>(0, (a, i) => a + i.price);
  int get folderPrice => manualFolderPrice ?? itemsTotal;
  bool get isFolder => items.length > 1;
  int get discount => itemsTotal - folderPrice;

  /// First card (convenience for single-song listings).
  CardPayload get card => items.first.card;

  Iterable<CardPayload> get cards => items.map((i) => i.card);

  Map<String, dynamic> toJson() => {
        'id': id,
        'sellerId': sellerId,
        'sellerName': sellerName,
        'items': [for (final i in items) i.toJson()],
        'folderPrice': manualFolderPrice,
        'note': note,
        'trades': acceptsTrades,
        'createdAt': createdAt,
      };

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        id: j['id'] as String,
        sellerId: j['sellerId'] as String,
        sellerName: j['sellerName'] as String? ?? '',
        items: j['items'] != null
            ? [for (final i in (j['items'] as List)) ListingItem.fromJson(i as Map<String, dynamic>)]
            // Legacy single-card listings.
            : [ListingItem(card: CardPayload.fromJson(j['card'] as Map<String, dynamic>), price: (j['price'] as num).toInt())],
        manualFolderPrice: (j['folderPrice'] as num?)?.toInt(),
        note: j['note'] as String? ?? '',
        acceptsTrades: j['trades'] as bool? ?? false,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );
}

enum TradeStatus { pending, accepted, declined, cancelled }

/// An offer of cards (+coins) in exchange for a whole trade-enabled folder.
class TradeOffer {
  TradeOffer({
    required this.id,
    required this.listingId,
    required this.fromId,
    required this.fromName,
    required this.toId,
    required this.offeredCards,
    required this.offeredCoins,
    required this.requestedCards,
    required this.createdAt,
    this.note = '',
    this.status = TradeStatus.pending,
  });

  final String id;
  final String listingId;
  final String fromId;
  final String fromName;
  final String toId;
  final List<CardPayload> offeredCards;
  final int offeredCoins;

  /// Snapshot of the folder's songs at offer time.
  final List<CardPayload> requestedCards;
  final int createdAt;
  final String note;
  TradeStatus status;

  CardPayload get requestedCard => requestedCards.first;
  String get requestedLabel => requestedCards.length == 1 ? requestedCards.first.title : '${requestedCards.length} songs';

  int get offeredValue => offeredCards.fold<int>(0, (a, c) => a + c.fair) + offeredCoins;
  int get requestedValue => requestedCards.fold<int>(0, (a, c) => a + c.fair);

  Map<String, dynamic> toJson() => {
        'id': id,
        'listingId': listingId,
        'fromId': fromId,
        'fromName': fromName,
        'toId': toId,
        'cards': [for (final c in offeredCards) c.toJson()],
        'coins': offeredCoins,
        'requested': [for (final c in requestedCards) c.toJson()],
        'note': note,
        'createdAt': createdAt,
        'status': status.index,
      };

  factory TradeOffer.fromJson(Map<String, dynamic> j) {
    final req = j['requested'];
    return TradeOffer(
      id: j['id'] as String,
      listingId: j['listingId'] as String,
      fromId: j['fromId'] as String,
      fromName: j['fromName'] as String? ?? '',
      toId: j['toId'] as String,
      offeredCards: [for (final c in (j['cards'] as List? ?? const [])) CardPayload.fromJson(c as Map<String, dynamic>)],
      offeredCoins: (j['coins'] as num?)?.toInt() ?? 0,
      requestedCards: req is List
          ? [for (final c in req) CardPayload.fromJson(c as Map<String, dynamic>)]
          : [CardPayload.fromJson(req as Map<String, dynamic>)],
      note: j['note'] as String? ?? '',
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      status: TradeStatus.values[(j['status'] as num?)?.toInt() ?? 0],
    );
  }
}

/// An artist a player has marked as a favourite (shown on their profile).
class FavoriteArtist {
  const FavoriteArtist({required this.id, required this.name, this.picMd5 = ''});
  final int id;
  final String name;
  final String picMd5;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pic': picMd5};
  factory FavoriteArtist.fromJson(Map<String, dynamic> j) =>
      FavoriteArtist(id: (j['id'] as num).toInt(), name: j['name'] as String? ?? '', picMd5: j['pic'] as String? ?? '');
}

/// Maximum favourite artists per player.
const int kMaxFavoriteArtists = 10;

/// A public display of a player's favourite cards, playlists and artists.
class Showcase {
  Showcase({
    required this.playerId,
    required this.playerName,
    required this.title,
    required this.cards,
    required this.playlists,
    required this.updatedAt,
    this.likes = 0,
    this.favoriteArtists = const [],
  });

  final List<FavoriteArtist> favoriteArtists;

  final String playerId;
  final String playerName;
  final String title;
  final List<CardPayload> cards;
  final List<ShowcasePlaylist> playlists;
  final int updatedAt;
  int likes;

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'playerName': playerName,
        'title': title,
        'cards': [for (final c in cards) c.toJson()],
        'playlists': [for (final p in playlists) p.toJson()],
        'updatedAt': updatedAt,
        'likes': likes,
        'favArtists': [for (final a in favoriteArtists) a.toJson()],
      };

  factory Showcase.fromJson(Map<String, dynamic> j) => Showcase(
        playerId: j['playerId'] as String,
        playerName: j['playerName'] as String? ?? '',
        title: j['title'] as String? ?? '',
        cards: [
          for (final c in (j['cards'] as List? ?? const []))
            CardPayload.fromJson(c as Map<String, dynamic>)
        ],
        playlists: [
          for (final p in (j['playlists'] as List? ?? const []))
            ShowcasePlaylist.fromJson(p as Map<String, dynamic>)
        ],
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        likes: (j['likes'] as num?)?.toInt() ?? 0,
        favoriteArtists: [
          for (final a in (j['favArtists'] as List? ?? const [])) FavoriteArtist.fromJson(a as Map<String, dynamic>)
        ],
      );
}

class ShowcasePlaylist {
  ShowcasePlaylist({required this.name, required this.cards});
  final String name;
  final List<CardPayload> cards;

  Map<String, dynamic> toJson() =>
      {'name': name, 'cards': [for (final c in cards) c.toJson()]};
  factory ShowcasePlaylist.fromJson(Map<String, dynamic> j) => ShowcasePlaylist(
        name: j['name'] as String? ?? 'Playlist',
        cards: [
          for (final c in (j['cards'] as List? ?? const []))
            CardPayload.fromJson(c as Map<String, dynamic>)
        ],
      );
}

/// Items waiting to be claimed by a player (sale proceeds, traded cards,
/// returned escrow).
class InboxItem {
  InboxItem({
    required this.id,
    required this.message,
    this.coins = 0,
    this.cards = const [],
    required this.createdAt,
  });
  final String id;
  final String message;
  final int coins;
  final List<CardPayload> cards;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'message': message,
        'coins': coins,
        'cards': [for (final c in cards) c.toJson()],
        'createdAt': createdAt,
      };
  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
        id: j['id'] as String,
        message: j['message'] as String? ?? '',
        coins: (j['coins'] as num?)?.toInt() ?? 0,
        cards: [
          for (final c in (j['cards'] as List? ?? const []))
            CardPayload.fromJson(c as Map<String, dynamic>)
        ],
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      );
}

enum ListingSort { newest, priceLow, priceHigh, rarity }

class ListingQuery {
  const ListingQuery({
    this.text = '',
    this.rarities = const {},
    this.shinyOnly = false,
    this.normalOnly = false,
    this.genres = const {},
    this.tradesOnly = false,
    this.sort = ListingSort.newest,
    this.offset = 0,
    this.limit = 50,
    this.excludeSellerId,
  });
  final String text;
  final Set<int> rarities;
  final bool shinyOnly;
  final bool normalOnly;
  final Set<int> genres;
  final bool tradesOnly;
  final ListingSort sort;
  final int offset;
  final int limit;
  final String? excludeSellerId;

  Map<String, String> toQueryParams() => {
        if (text.isNotEmpty) 'q': text,
        if (rarities.isNotEmpty) 'rarities': rarities.join(','),
        if (shinyOnly) 'shiny': '1',
        if (normalOnly) 'normal': '1',
        if (genres.isNotEmpty) 'genres': genres.join(','),
        if (tradesOnly) 'trades': '1',
        'sort': sort.name,
        'offset': '$offset',
        'limit': '$limit',
        'exclude': ?excludeSellerId,
      };

  factory ListingQuery.fromQueryParams(Map<String, String> p) => ListingQuery(
        text: p['q'] ?? '',
        rarities: (p['rarities'] ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .map(int.parse)
            .toSet(),
        shinyOnly: p['shiny'] == '1',
        normalOnly: p['normal'] == '1',
        genres: (p['genres'] ?? '').split(',').where((s) => s.isNotEmpty).map(int.parse).toSet(),
        tradesOnly: p['trades'] == '1',
        sort: ListingSort.values.firstWhere((s) => s.name == p['sort'],
            orElse: () => ListingSort.newest),
        offset: int.tryParse(p['offset'] ?? '') ?? 0,
        limit: (int.tryParse(p['limit'] ?? '') ?? 50).clamp(1, 200),
        excludeSellerId: p['exclude'],
      );
}

class MarketException implements Exception {
  MarketException(this.message);
  final String message;
  @override
  String toString() => message;
}
