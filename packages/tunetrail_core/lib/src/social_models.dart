import 'card_payload.dart';
import 'market_models.dart';

/// A player in search results.
class PlayerSummary {
  const PlayerSummary({required this.id, required this.name, this.theme = '', this.level = 1, this.cards = 0});
  final String id;
  final String name;
  final String theme;
  final int level;
  final int cards;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'theme': theme, 'level': level, 'cards': cards};
  factory PlayerSummary.fromJson(Map<String, dynamic> j) => PlayerSummary(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        theme: j['theme'] as String? ?? '',
        level: (j['level'] as num?)?.toInt() ?? 1,
        cards: (j['cards'] as num?)?.toInt() ?? 0,
      );
}

/// Everything another player can see on someone's profile page.
class PublicProfile {
  PublicProfile({
    required this.id,
    required this.name,
    this.theme = '',
    this.level = 1,
    this.joinedAt = 0,
    this.stats = const {},
    this.editionShowcase = const [],
    this.favoriteArtists = const [],
    this.showcase,
    this.cardCount = 0,
    this.blockedByMe = false,
    this.isBot = false,
  });
  final String id;
  final String name;
  final String theme;
  final int level;
  final int joinedAt;

  /// Public stats (caught, shinies, distance…), name → value.
  final Map<String, num> stats;

  /// Up to three Canvas/Sample/Live cards.
  final List<CardPayload> editionShowcase;
  final List<FavoriteArtist> favoriteArtists;
  final Showcase? showcase;
  final int cardCount;
  final bool blockedByMe;
  final bool isBot;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'theme': theme,
        'level': level,
        'joinedAt': joinedAt,
        'stats': stats,
        'editions': [for (final c in editionShowcase) c.toJson()],
        'favArtists': [for (final a in favoriteArtists) a.toJson()],
        'showcase': showcase?.toJson(),
        'cardCount': cardCount,
        'blocked': blockedByMe,
        'bot': isBot,
      };

  factory PublicProfile.fromJson(Map<String, dynamic> j) => PublicProfile(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        theme: j['theme'] as String? ?? '',
        level: (j['level'] as num?)?.toInt() ?? 1,
        joinedAt: (j['joinedAt'] as num?)?.toInt() ?? 0,
        stats: {for (final e in (j['stats'] as Map<String, dynamic>? ?? const {}).entries) if (e.value is num) e.key: e.value as num},
        editionShowcase: [for (final c in (j['editions'] as List? ?? const [])) CardPayload.fromJson(c as Map<String, dynamic>)],
        favoriteArtists: [for (final a in (j['favArtists'] as List? ?? const [])) FavoriteArtist.fromJson(a as Map<String, dynamic>)],
        showcase: j['showcase'] == null ? null : Showcase.fromJson(j['showcase'] as Map<String, dynamic>),
        cardCount: (j['cardCount'] as num?)?.toInt() ?? 0,
        blockedByMe: j['blocked'] as bool? ?? false,
        isBot: j['bot'] as bool? ?? false,
      );
}

/// One page of a player's collection.
class CollectionPage {
  const CollectionPage({required this.cards, required this.total});
  final List<CardPayload> cards;

  /// Cards matching the search (not just this page).
  final int total;

  Map<String, dynamic> toJson() => {'cards': [for (final c in cards) c.toJson()], 'total': total};
  factory CollectionPage.fromJson(Map<String, dynamic> j) => CollectionPage(
        cards: [for (final c in (j['cards'] as List? ?? const [])) CardPayload.fromJson(c as Map<String, dynamic>)],
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// A direct message.
class ChatMessage {
  const ChatMessage({required this.id, required this.from, required this.to, required this.text, required this.at});
  final String id;
  final String from;
  final String to;
  final String text;
  final int at;

  Map<String, dynamic> toJson() => {'id': id, 'from': from, 'to': to, 'text': text, 'at': at};
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        from: j['from'] as String,
        to: j['to'] as String,
        text: j['text'] as String? ?? '',
        at: (j['at'] as num?)?.toInt() ?? 0,
      );
}

/// A conversation in the messages list.
class Conversation {
  const Conversation({required this.otherId, required this.otherName, this.otherTheme = '', required this.last, this.unread = 0});
  final String otherId;
  final String otherName;
  final String otherTheme;
  final ChatMessage last;
  final int unread;

  Map<String, dynamic> toJson() => {'other': otherId, 'name': otherName, 'theme': otherTheme, 'last': last.toJson(), 'unread': unread};
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        otherId: j['other'] as String,
        otherName: j['name'] as String? ?? '',
        otherTheme: j['theme'] as String? ?? '',
        last: ChatMessage.fromJson(j['last'] as Map<String, dynamic>),
        unread: (j['unread'] as num?)?.toInt() ?? 0,
      );
}
