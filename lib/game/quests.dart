import 'package:tunetrail_core/tunetrail_core.dart';

import '../data/catalog.dart';
import '../data/models.dart';

enum QuestKind {
  catchAny,
  catchGenre,
  catchRarePlus,
  walkMeters,
  openPack,
  listOnMarket,
  catchShiny,
  artistSongs, // collect N distinct songs by an artist → unlock reward song
  albumComplete, // own every track of an album → unlock reward song
  collectionSize,
}

enum QuestCategory { daily, unlock, milestone }

class QuestReward {
  const QuestReward({this.coins = 0, this.bits = 0, this.xp = 0, this.songId, this.rarity, this.shiny = false});
  final int coins;
  final int bits;
  final int xp;

  /// Quest-exclusive song card unlocked by completing the quest.
  final int? songId;
  final Rarity? rarity;
  final bool shiny;
}

class Quest {
  Quest({
    required this.id,
    required this.category,
    required this.kind,
    required this.title,
    required this.description,
    required this.target,
    required this.reward,
    this.genreId,
    this.artistId,
    this.albumId,
    this.imageMd5 = '',
    this.imageIsArtist = false,
  });
  final String id;
  final QuestCategory category;
  final QuestKind kind;
  final String title;
  final String description;
  final int target;
  final QuestReward reward;
  final int? genreId;
  final int? artistId;
  final int? albumId;
  final String imageMd5;
  final bool imageIsArtist;
}

/// Generates the current quest board.
class QuestBoard {
  static String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static List<Quest> daily(DateTime day, Catalog catalog) {
    final rng = Rng(hashString('daily-${dayKey(day)}'));
    final genres = [for (final g in kGenres) if (catalog.poolFor(g.id).length > 20) g];
    final g = genres.isEmpty ? kGenres[1] : genres[rng.nextInt(genres.length)];
    final pool = <Quest>[
      Quest(id: 'd_catch', category: QuestCategory.daily, kind: QuestKind.catchAny, title: 'Crate Digger', description: 'Catch 10 songs in the wild', target: 10, reward: const QuestReward(coins: 150, xp: 100)),
      Quest(id: 'd_genre_${g.id}', category: QuestCategory.daily, kind: QuestKind.catchGenre, genreId: g.id, title: '${g.name} Hunter', description: 'Catch 5 ${g.name} songs', target: 5, reward: const QuestReward(coins: 200, xp: 120)),
      Quest(id: 'd_rare', category: QuestCategory.daily, kind: QuestKind.catchRarePlus, title: 'Rare Groove', description: 'Catch 2 Rare-or-better songs', target: 2, reward: const QuestReward(coins: 250, bits: 5, xp: 150)),
      Quest(id: 'd_walk', category: QuestCategory.daily, kind: QuestKind.walkMeters, title: 'On the Trail', description: 'Walk 2 km', target: 2000, reward: const QuestReward(coins: 200, bits: 5, xp: 150)),
      Quest(id: 'd_pack', category: QuestCategory.daily, kind: QuestKind.openPack, title: 'Unboxing', description: 'Open a song pack', target: 1, reward: const QuestReward(coins: 100, xp: 60)),
      Quest(id: 'd_market', category: QuestCategory.daily, kind: QuestKind.listOnMarket, title: 'Merchant', description: 'List a song on the market', target: 1, reward: const QuestReward(coins: 100, xp: 60)),
    ];
    // Pick 4 distinct dailies.
    final picked = <Quest>[];
    final order = List.generate(pool.length, (i) => i);
    for (var i = order.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = order[i];
      order[i] = order[j];
      order[j] = t;
    }
    for (final i in order.take(4)) {
      picked.add(pool[i]);
    }
    return picked;
  }

  /// Weekly artist "spotlight" quests: collect N distinct songs by an
  /// artist to unlock a quest-exclusive Epic card of their biggest song.
  static List<Quest> unlocks(DateTime day, Catalog catalog) {
    final week = day.difference(DateTime(2024)).inDays ~/ 7;
    final rng = Rng(hashString('unlock-$week'));
    final byArtist = <int, List<Song>>{};
    for (final s in catalog.songs.values) {
      byArtist.putIfAbsent(s.artistId, () => []).add(s);
    }
    final eligible = byArtist.entries.where((e) => e.value.length >= 8).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final out = <Quest>[];
    for (var i = 0; i < 3 && eligible.isNotEmpty; i++) {
      final e = eligible.removeAt(rng.nextInt(eligible.length));
      final songs = e.value..sort((a, b) => b.rank.compareTo(a.rank));
      final top = songs.first;
      final need = 5 + rng.nextInt(4);
      final epic = i < 2;
      out.add(Quest(
        id: 'u_${e.key}_$week',
        category: QuestCategory.unlock,
        kind: QuestKind.artistSongs,
        artistId: e.key,
        title: 'Spotlight: ${top.artistName}',
        description: 'Collect $need different songs by ${top.artistName} to unlock '
            'an exclusive ${catalog.rarityOf(top).label} "${top.title}" card',
        target: need,
        imageMd5: top.artistPicMd5.isNotEmpty ? top.artistPicMd5 : top.coverMd5,
        imageIsArtist: top.artistPicMd5.isNotEmpty,
        reward: QuestReward(
            coins: epic ? 300 : 600,
            xp: 400,
            songId: top.id,
            rarity: catalog.rarityOf(top)),
      ));
    }
    return out;
  }

  static List<Quest> milestones() => [
        for (final n in [10, 50, 100, 500, 1000, 5000, 10000])
          Quest(
            id: 'm_size_$n',
            category: QuestCategory.milestone,
            kind: QuestKind.collectionSize,
            title: 'Collector ${_roman(n)}',
            description: 'Own $n song cards',
            target: n,
            reward: QuestReward(coins: n * 3, bits: n >= 100 ? n ~/ 20 : 0, xp: n * 2),
          ),
        for (final n in [1, 5, 25])
          Quest(
            id: 'm_shiny_$n',
            category: QuestCategory.milestone,
            kind: QuestKind.catchShiny,
            title: 'Glimmer ${_roman(n)}',
            description: 'Catch $n shiny songs in the wild',
            target: n,
            reward: QuestReward(coins: 500 * n, bits: 25 * n, xp: 300 * n),
          ),
      ];

  /// Album completion quest for a specific album (generated on demand from
  /// the album screen).
  static Quest album(AlbumInfo a, int topSongId) => Quest(
        id: 'a_${a.id}',
        category: QuestCategory.unlock,
        kind: QuestKind.albumComplete,
        albumId: a.id,
        title: 'Complete "${a.title}"',
        description: 'Own every track on this ${a.recordType} to unlock a shiny card of its biggest song',
        target: a.trackIds.length,
        imageMd5: a.coverMd5,
        reward: QuestReward(coins: 250 * a.trackIds.length, xp: 500, songId: topSongId, shiny: true),
      );

  static String _roman(int n) => switch (n) {
        1 => 'I',
        5 => 'II',
        10 => 'I',
        25 => 'III',
        50 => 'II',
        100 => 'III',
        500 => 'IV',
        1000 => 'V',
        5000 => 'VI',
        _ => 'VII',
      };
}
