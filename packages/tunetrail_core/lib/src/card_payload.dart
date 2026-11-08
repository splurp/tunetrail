import 'rarity.dart';

/// A self-contained snapshot of one owned song card.
///
/// Used whenever a card leaves a player's local collection (market listings,
/// trades, showcases) so the receiver gets full song metadata even if that
/// song is not yet in their local catalog.
class CardPayload {
  CardPayload({
    required this.uid,
    required this.songId,
    required this.title,
    required this.artistId,
    required this.artistName,
    required this.albumId,
    required this.albumTitle,
    required this.coverMd5,
    required this.rarity,
    required this.shiny,
    this.genreId = 0,
    this.rank = 0,
    this.duration = 0,
    this.artistPicMd5 = '',
    this.acquiredAt = 0,
    this.edition = Edition.standard,
  });

  final int uid;
  final int songId;
  final String title;
  final int artistId;
  final String artistName;
  final int albumId;
  final String albumTitle;
  final String coverMd5;
  final String artistPicMd5;
  final Rarity rarity;
  final bool shiny;
  final int genreId;
  final int rank;
  final int duration;
  final int acquiredAt;
  final Edition edition;

  int get fair => fairValue(rarity, shiny, popularity: rank, edition: edition);

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'songId': songId,
        'title': title,
        'artistId': artistId,
        'artistName': artistName,
        'albumId': albumId,
        'albumTitle': albumTitle,
        'cover': coverMd5,
        'artistPic': artistPicMd5,
        'rarity': rarity.index,
        'shiny': shiny,
        'genre': genreId,
        'rank': rank,
        'duration': duration,
        'acq': acquiredAt,
        if (edition != Edition.standard) 'ed': edition.index,
      };

  factory CardPayload.fromJson(Map<String, dynamic> j) => CardPayload(
        uid: (j['uid'] as num).toInt(),
        songId: (j['songId'] as num).toInt(),
        title: j['title'] as String? ?? '',
        artistId: (j['artistId'] as num?)?.toInt() ?? 0,
        artistName: j['artistName'] as String? ?? '',
        albumId: (j['albumId'] as num?)?.toInt() ?? 0,
        albumTitle: j['albumTitle'] as String? ?? '',
        coverMd5: j['cover'] as String? ?? '',
        artistPicMd5: j['artistPic'] as String? ?? '',
        rarity: Rarity.fromIndex((j['rarity'] as num?)?.toInt() ?? 0),
        shiny: j['shiny'] as bool? ?? false,
        genreId: (j['genre'] as num?)?.toInt() ?? 0,
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        acquiredAt: (j['acq'] as num?)?.toInt() ?? 0,
        edition: Edition.fromIndex((j['ed'] as num?)?.toInt() ?? 0),
      );

  CardPayload withUid(int newUid) => CardPayload(
        uid: newUid,
        songId: songId,
        title: title,
        artistId: artistId,
        artistName: artistName,
        albumId: albumId,
        albumTitle: albumTitle,
        coverMd5: coverMd5,
        artistPicMd5: artistPicMd5,
        rarity: rarity,
        shiny: shiny,
        genreId: genreId,
        rank: rank,
        duration: duration,
        acquiredAt: acquiredAt,
        edition: edition,
      );
}
