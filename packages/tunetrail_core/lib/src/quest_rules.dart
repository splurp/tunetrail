import 'rarity.dart';
import 'rng.dart';
import 'song_catalog.dart';

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

  Map<String, dynamic> toJson() => {
        if (coins != 0) 'c': coins,
        if (bits != 0) 'b': bits,
        if (xp != 0) 'x': xp,
        if (songId != null) 's': songId,
        if (rarity != null) 'r': rarity!.index,
        if (shiny) 'sh': true,
      };

  factory QuestReward.fromJson(Map<String, dynamic> j) => QuestReward(
        coins: (j['c'] as num?)?.toInt() ?? 0,
        bits: (j['b'] as num?)?.toInt() ?? 0,
        xp: (j['x'] as num?)?.toInt() ?? 0,
        songId: (j['s'] as num?)?.toInt(),
        rarity: j['r'] == null ? null : Rarity.fromIndex((j['r'] as num).toInt()),
        shiny: j['sh'] as bool? ?? false,
      );
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
    this.rewardSong,
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

  /// The reward song's details (so a game that doesn't know it yet can
  /// show it).
  final SongInfo? rewardSong;

  Map<String, dynamic> toJson() => {
        'id': id,
        'cat': category.index,
        'kind': kind.name,
        'title': title,
        'desc': description,
        'target': target,
        'reward': reward.toJson(),
        if (genreId != null) 'g': genreId,
        if (artistId != null) 'a': artistId,
        if (albumId != null) 'al': albumId,
        if (imageMd5.isNotEmpty) 'img': imageMd5,
        if (imageIsArtist) 'imgA': true,
        if (rewardSong != null) 'song': rewardSong!.toJson(),
      };

  factory Quest.fromJson(Map<String, dynamic> j) => Quest(
        id: j['id'] as String,
        category: QuestCategory.values[((j['cat'] as num?)?.toInt() ?? 0).clamp(0, QuestCategory.values.length - 1)],
        kind: QuestKind.values.asNameMap()[j['kind']] ?? QuestKind.catchAny,
        title: j['title'] as String? ?? '',
        description: j['desc'] as String? ?? '',
        target: (j['target'] as num?)?.toInt() ?? 1,
        reward: QuestReward.fromJson(j['reward'] as Map<String, dynamic>? ?? const {}),
        genreId: (j['g'] as num?)?.toInt(),
        artistId: (j['a'] as num?)?.toInt(),
        albumId: (j['al'] as num?)?.toInt(),
        imageMd5: j['img'] as String? ?? '',
        imageIsArtist: j['imgA'] as bool? ?? false,
        rewardSong: j['song'] == null ? null : SongInfo.fromJson(j['song'] as Map<String, dynamic>),
      );
}

/// The quest board: the same for the game and the server.
class QuestRules {
  /// Week number of a day key ("2026-11-9").
  static int weekOf(String dayKey) {
    final p = dayKey.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]).difference(DateTime.utc(2024)).inDays ~/ 7;
  }

  /// Four daily quests. [genres] are the genres with enough songs for a
  /// genre quest.
  static List<Quest> daily(String dayKey, List<GenreInfo> genres) {
    final rng = Rng(hashString('daily-$dayKey'));
    final real = [for (final g in genres) if (g.id != 0) g];
    final g = real.isEmpty ? kWorldGenres[1] : real[rng.nextInt(real.length)];
    final pool = <Quest>[
      Quest(id: 'd_catch', category: QuestCategory.daily, kind: QuestKind.catchAny, title: 'Crate Digger', description: 'Catch 10 songs in the wild', target: 10, reward: const QuestReward(coins: 150, xp: 100)),
      Quest(id: 'd_genre_${g.id}', category: QuestCategory.daily, kind: QuestKind.catchGenre, genreId: g.id, title: '${g.name} Hunter', description: 'Catch 5 ${g.name} songs', target: 5, reward: const QuestReward(coins: 200, xp: 120)),
      Quest(id: 'd_rare', category: QuestCategory.daily, kind: QuestKind.catchRarePlus, title: 'Rare Groove', description: 'Catch 2 Rare-or-better songs', target: 2, reward: const QuestReward(coins: 250, bits: 5, xp: 150)),
      Quest(id: 'd_walk', category: QuestCategory.daily, kind: QuestKind.walkMeters, title: 'On the Trail', description: 'Walk 2 km', target: 2000, reward: const QuestReward(coins: 200, bits: 5, xp: 150)),
      Quest(id: 'd_pack', category: QuestCategory.daily, kind: QuestKind.openPack, title: 'Unboxing', description: 'Open a song pack', target: 1, reward: const QuestReward(coins: 100, xp: 60)),
      Quest(id: 'd_market', category: QuestCategory.daily, kind: QuestKind.listOnMarket, title: 'Merchant', description: 'List a song on the market', target: 1, reward: const QuestReward(coins: 100, xp: 60)),
    ];
    final order = List.generate(pool.length, (i) => i);
    for (var i = order.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = order[i];
      order[i] = order[j];
      order[j] = t;
    }
    return [for (final i in order.take(4)) pool[i]];
  }

  /// Weekly artist "spotlight" quests: collect N distinct songs by an
  /// artist to unlock a quest-exclusive card of their biggest song.
  static List<Quest> unlocks(int week, Map<int, List<SongInfo>> byArtist, Rarity Function(SongInfo) rarityOf) {
    final rng = Rng(hashString('unlock-$week'));
    final eligible = byArtist.entries.where((e) => e.value.length >= 8).toList()..sort((a, b) => a.key.compareTo(b.key));
    final out = <Quest>[];
    for (var i = 0; i < 3 && eligible.isNotEmpty; i++) {
      final e = eligible.removeAt(rng.nextInt(eligible.length));
      final songs = List.of(e.value)..sort((a, b) => b.rank.compareTo(a.rank));
      final top = songs.first;
      final need = 5 + rng.nextInt(4);
      final epic = i < 2;
      final rarity = rarityOf(top);
      out.add(Quest(
        id: 'u_${e.key}_$week',
        category: QuestCategory.unlock,
        kind: QuestKind.artistSongs,
        artistId: e.key,
        title: 'Spotlight: ${top.artistName}',
        description: 'Collect $need different songs by ${top.artistName} to unlock '
            'an exclusive ${rarity.label} "${top.title}" card',
        target: need,
        imageMd5: top.artistPicMd5.isNotEmpty ? top.artistPicMd5 : top.coverMd5,
        imageIsArtist: top.artistPicMd5.isNotEmpty,
        reward: QuestReward(coins: epic ? 300 : 600, xp: 400, songId: top.id, rarity: rarity),
        rewardSong: top,
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

  /// Album completion quest for one album.
  static Quest album({required int albumId, required String title, required String recordType, required int trackCount, required String coverMd5, required int topSongId}) =>
      Quest(
        id: 'a_$albumId',
        category: QuestCategory.unlock,
        kind: QuestKind.albumComplete,
        albumId: albumId,
        title: 'Complete "$title"',
        description: 'Own every track on this $recordType to unlock a shiny card of its biggest song',
        target: trackCount,
        imageMd5: coverMd5,
        reward: QuestReward(coins: 250 * trackCount, xp: 500, songId: topSongId, shiny: true),
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
