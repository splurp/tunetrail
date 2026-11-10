import 'package:tunetrail_core/tunetrail_core.dart';

import '../data/catalog.dart';
import '../data/models.dart';

export 'package:tunetrail_core/tunetrail_core.dart' show Quest, QuestReward, QuestKind, QuestCategory;

/// The quest board, built from the shared rules (packages/tunetrail_core)
/// with this game's song catalogue. With the server economy on, the board
/// comes from the server instead (see Game.questBoard).
class QuestBoard {
  static String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static List<Quest> daily(DateTime day, Catalog catalog) {
    final genres = [
      for (final g in kWorldGenres)
        if (catalog.poolFor(g.id).length > 20) g
    ];
    return QuestRules.daily(dayKey(day), genres);
  }

  static List<Quest> unlocks(DateTime day, Catalog catalog) {
    final byArtist = <int, List<SongInfo>>{};
    for (final s in catalog.songs.values) {
      byArtist.putIfAbsent(s.artistId, () => []).add(s.toInfo());
    }
    return QuestRules.unlocks(QuestRules.weekOf(dayKey(day)), byArtist, (s) => catalog.rarityOf(catalog.songs[s.id] ?? Song.fromInfo(s)));
  }

  static List<Quest> milestones() => QuestRules.milestones();

  /// Album completion quest for a specific album (generated on demand from
  /// the album screen).
  static Quest album(AlbumInfo a, int topSongId) => QuestRules.album(
        albumId: a.id,
        title: a.title,
        recordType: a.recordType,
        trackCount: a.trackIds.length,
        coverMd5: a.coverMd5,
        topSongId: topSongId,
      );
}
