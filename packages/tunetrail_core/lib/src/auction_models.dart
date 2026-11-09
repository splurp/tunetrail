import 'card_payload.dart';

/// Bid increment floor (coins).
const int kMinBidIncrement = 100;

/// Auction lengths a seller can choose.
const List<Duration> kAuctionDurations = [
  Duration(hours: 1),
  Duration(hours: 3),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(hours: 24),
];

/// Bids in the last [kSnipeWindow] push the end back by [kSnipeExtension].
const Duration kSnipeWindow = Duration(minutes: 5);
const Duration kSnipeExtension = Duration(seconds: 30);

/// Songs (1–20) sold to the highest bidder. Bids are escrowed: the bidder's
/// coins are held until they're outbid (refunded) or win.
class Auction {
  Auction({
    required this.id,
    required this.sellerId,
    required this.sellerName,
    required this.cards,
    required this.startPrice,
    required this.increment,
    required this.createdAt,
    required this.endsAt,
    this.buyNow,
    this.note = '',
    this.highBid = 0,
    this.highBidderId,
    this.highBidderName = '',
    this.bids = 0,
  });

  final String id;
  final String sellerId;
  String sellerName;
  final List<CardPayload> cards;
  final int startPrice;
  final int increment;
  final int? buyNow;
  final String note;
  final int createdAt;
  int endsAt;
  int highBid;
  String? highBidderId;
  String highBidderName;
  int bids;

  /// The smallest bid that would be accepted now.
  int get minBid => highBidderId == null ? startPrice : highBid + increment;

  /// Buy It Now is offered until the bidding reaches it.
  bool get buyNowOpen => buyNow != null && highBid < buyNow!;

  String get label => cards.length == 1 ? cards.first.title : '${cards.length} songs';

  Map<String, dynamic> toJson() => {
        'id': id,
        'sellerId': sellerId,
        'sellerName': sellerName,
        'cards': [for (final c in cards) c.toJson()],
        'start': startPrice,
        'inc': increment,
        'buyNow': buyNow,
        'note': note,
        'createdAt': createdAt,
        'endsAt': endsAt,
        'high': highBid,
        'highId': highBidderId,
        'highName': highBidderName,
        'bids': bids,
      };

  factory Auction.fromJson(Map<String, dynamic> j) => Auction(
        id: j['id'] as String,
        sellerId: j['sellerId'] as String,
        sellerName: j['sellerName'] as String? ?? '',
        cards: [for (final c in (j['cards'] as List? ?? const [])) CardPayload.fromJson(c as Map<String, dynamic>)],
        startPrice: (j['start'] as num).toInt(),
        increment: (j['inc'] as num?)?.toInt() ?? kMinBidIncrement,
        buyNow: (j['buyNow'] as num?)?.toInt(),
        note: j['note'] as String? ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        endsAt: (j['endsAt'] as num).toInt(),
        highBid: (j['high'] as num?)?.toInt() ?? 0,
        highBidderId: j['highId'] as String?,
        highBidderName: j['highName'] as String? ?? '',
        bids: (j['bids'] as num?)?.toInt() ?? 0,
      );
}

enum ReportKind { song, player }

/// A player's report of a song card or another player, for admins to review.
class Report {
  Report({
    required this.id,
    required this.kind,
    required this.reporterId,
    required this.reporterName,
    required this.targetId,
    required this.targetLabel,
    required this.reason,
    required this.details,
    required this.createdAt,
    this.card,
    this.resolved = false,
  });

  final String id;
  final ReportKind kind;
  final String reporterId;
  final String reporterName;

  /// Song id (as text) or player id.
  final String targetId;
  final String targetLabel;
  final String reason;
  final String details;
  final int createdAt;
  final CardPayload? card;
  bool resolved;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'by': reporterId,
        'byName': reporterName,
        'target': targetId,
        'label': targetLabel,
        'reason': reason,
        'details': details,
        'at': createdAt,
        'card': card?.toJson(),
        'resolved': resolved,
      };

  factory Report.fromJson(Map<String, dynamic> j) => Report(
        id: j['id'] as String,
        kind: ReportKind.values.byName(j['kind'] as String),
        reporterId: j['by'] as String,
        reporterName: j['byName'] as String? ?? '',
        targetId: j['target'] as String,
        targetLabel: j['label'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        details: j['details'] as String? ?? '',
        createdAt: (j['at'] as num?)?.toInt() ?? 0,
        card: j['card'] == null ? null : CardPayload.fromJson(j['card'] as Map<String, dynamic>),
        resolved: j['resolved'] as bool? ?? false,
      );
}

/// Reasons a song card can be reported.
const kSongReportReasons = ['Explicit sexual content', 'Graphic violence or gore', 'Malicious link or advertising', 'Other'];

/// Reasons a player can be reported.
const kPlayerReportReasons = ['Cheating', 'Harassment', 'Spam', 'Malicious links', 'Evading a block', 'Other'];
