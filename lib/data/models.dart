import 'package:tunetrail_core/tunetrail_core.dart';

/// Deezer image CDN helpers. Only the md5 hash is stored per song/artist,
/// which keeps the catalog compact even with hundreds of thousands of songs.
String coverUrl(String md5, {int size = 250}) => md5.isEmpty
    ? ''
    : 'https://cdn-images.dzcdn.net/images/cover/$md5/${size}x$size-000000-80-0-0.jpg';

String artistPicUrl(String md5, {int size = 250}) => md5.isEmpty
    ? ''
    : 'https://cdn-images.dzcdn.net/images/artist/$md5/${size}x$size-000000-80-0-0.jpg';

final _md5Re = RegExp(r'/images/(?:artist|cover)/([0-9a-f]{32})/');

/// Extracts the md5 hash from a Deezer CDN image URL.
String md5FromUrl(String? url) {
  if (url == null) return '';
  return _md5Re.firstMatch(url)?.group(1) ?? '';
}

/// Immutable song metadata.
class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artistId,
    required this.artistName,
    required this.albumId,
    required this.albumTitle,
    required this.coverMd5,
    this.artistPicMd5 = '',
    this.genreId = 0,
    this.rank = 0,
    this.duration = 0,
    this.plays = 0,
  });

  final int id;
  final String title;
  final int artistId;
  final String artistName;
  final int albumId;
  final String albumTitle;
  final String coverMd5;
  final String artistPicMd5;
  final int genreId;
  final int rank;
  final int duration;

  /// All-time play count from Last.fm (0 = unknown). Used for rarity when
  /// available; Deezer's [rank] is the fallback popularity signal.
  final int plays;

  Song withPlays(int p) => Song(
        id: id,
        title: title,
        artistId: artistId,
        artistName: artistName,
        albumId: albumId,
        albumTitle: albumTitle,
        coverMd5: coverMd5,
        artistPicMd5: artistPicMd5,
        genreId: genreId,
        rank: rank,
        duration: duration,
        plays: p,
      );

  String cover([int size = 250]) => coverUrl(coverMd5, size: size);

  Map<String, dynamic> toJson() => {
        'i': id,
        't': title,
        'a': artistId,
        'an': artistName,
        'b': albumId,
        'bn': albumTitle,
        'c': coverMd5,
        if (artistPicMd5.isNotEmpty) 'p': artistPicMd5,
        if (genreId != 0) 'g': genreId,
        if (rank != 0) 'r': rank,
        if (duration != 0) 'd': duration,
        if (plays != 0) 'pl': plays,
      };

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: (j['i'] as num).toInt(),
        title: j['t'] as String? ?? '',
        artistId: (j['a'] as num?)?.toInt() ?? 0,
        artistName: j['an'] as String? ?? '',
        albumId: (j['b'] as num?)?.toInt() ?? 0,
        albumTitle: j['bn'] as String? ?? '',
        coverMd5: j['c'] as String? ?? '',
        artistPicMd5: j['p'] as String? ?? '',
        genreId: (j['g'] as num?)?.toInt() ?? 0,
        rank: (j['r'] as num?)?.toInt() ?? 0,
        duration: (j['d'] as num?)?.toInt() ?? 0,
        plays: (j['pl'] as num?)?.toInt() ?? 0,
      );

  /// Parses a Deezer track object (from charts, top tracks, albums...).
  static Song? fromDeezer(Map<String, dynamic> t,
      {int genreId = 0, int? albumId, String? albumTitle, String? albumMd5}) {
    final id = (t['id'] as num?)?.toInt();
    if (id == null || id <= 0) return null;
    if (t['readable'] == false) return null;
    final artist = t['artist'] as Map<String, dynamic>? ?? const {};
    final album = t['album'] as Map<String, dynamic>? ?? const {};
    return Song(
      id: id,
      title: (t['title_short'] as String?)?.isNotEmpty == true
          ? t['title_short'] as String
          : t['title'] as String? ?? 'Unknown',
      artistId: (artist['id'] as num?)?.toInt() ?? 0,
      artistName: artist['name'] as String? ?? 'Unknown Artist',
      albumId: albumId ?? (album['id'] as num?)?.toInt() ?? 0,
      albumTitle: albumTitle ?? album['title'] as String? ?? '',
      coverMd5: (t['md5_image'] as String?) ??
          albumMd5 ??
          (album['md5_image'] as String?) ??
          md5FromUrl(album['cover_small'] as String?),
      artistPicMd5: md5FromUrl(artist['picture_small'] as String?),
      genreId: genreId,
      rank: (t['rank'] as num?)?.toInt() ?? 0,
      duration: (t['duration'] as num?)?.toInt() ?? 0,
    );
  }

  CardPayload toPayload(
          {required int uid,
          required Rarity rarity,
          required bool shiny,
          int acquiredAt = 0}) =>
      CardPayload(
        uid: uid,
        songId: id,
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
      );

  factory Song.fromPayload(CardPayload c) => Song(
        id: c.songId,
        title: c.title,
        artistId: c.artistId,
        artistName: c.artistName,
        albumId: c.albumId,
        albumTitle: c.albumTitle,
        coverMd5: c.coverMd5,
        artistPicMd5: c.artistPicMd5,
        genreId: c.genreId,
        rank: c.rank,
        duration: c.duration,
      );
}

class ArtistInfo {
  ArtistInfo({
    required this.id,
    required this.name,
    this.picMd5 = '',
    this.fans = 0,
    this.albumCount = 0,
    this.genreId = 0,
  });
  final int id;
  final String name;
  String picMd5;
  int fans;
  int albumCount;
  int genreId;

  String picture([int size = 250]) => artistPicUrl(picMd5, size: size);

  Map<String, dynamic> toJson() => {
        'i': id,
        'n': name,
        'p': picMd5,
        if (fans != 0) 'f': fans,
        if (albumCount != 0) 'ac': albumCount,
        if (genreId != 0) 'g': genreId,
      };
  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
        id: (j['i'] as num).toInt(),
        name: j['n'] as String? ?? '',
        picMd5: j['p'] as String? ?? '',
        fans: (j['f'] as num?)?.toInt() ?? 0,
        albumCount: (j['ac'] as num?)?.toInt() ?? 0,
        genreId: (j['g'] as num?)?.toInt() ?? 0,
      );
}

class AlbumInfo {
  AlbumInfo({
    required this.id,
    required this.title,
    required this.coverMd5,
    required this.artistId,
    required this.artistName,
    this.releaseDate = '',
    this.recordType = 'album',
    this.trackIds = const [],
    this.genreId = 0,
    this.fans = 0,
  });
  final int id;
  final String title;
  final String coverMd5;
  final int artistId;
  final String artistName;
  final String releaseDate;
  final String recordType;
  final int genreId;
  final int fans;

  /// Track ids in official album order (empty until loaded).
  List<int> trackIds;

  String cover([int size = 250]) => coverUrl(coverMd5, size: size);
  String get year => releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
}

class Playlist {
  Playlist({required this.id, required this.name, List<int>? cardUids})
      : cardUids = cardUids ?? [];
  final String id;
  String name;
  final List<int> cardUids;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'cards': cardUids};
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Playlist',
        cardUids: [for (final x in (j['cards'] as List? ?? const [])) (x as num).toInt()],
      );
}

/// Genre definitions used for spawning, packs and filters.
class GenreDef {
  const GenreDef(this.id, this.name, this.weight, {this.nonEnglish = false});
  final int id;
  final String name;

  /// Relative spawn weight (English-language genres dominate).
  final int weight;

  /// Non-English genres only admit very popular artists.
  final bool nonEnglish;
}

const List<GenreDef> kGenres = [
  GenreDef(0, 'Top Hits', 14),
  GenreDef(132, 'Pop', 20),
  GenreDef(116, 'Hip Hop', 18),
  GenreDef(152, 'Rock', 14),
  GenreDef(165, 'R&B', 10),
  GenreDef(85, 'Alternative', 10),
  GenreDef(113, 'Dance', 8),
  GenreDef(106, 'Electronic', 8),
  GenreDef(84, 'Country', 6),
  GenreDef(464, 'Metal', 4),
  GenreDef(169, 'Soul & Funk', 4),
  GenreDef(466, 'Folk', 3),
  GenreDef(144, 'Reggae', 2),
  GenreDef(129, 'Jazz', 2),
  GenreDef(153, 'Blues', 1),
  GenreDef(173, 'Film & Games', 2),
  GenreDef(98, 'Classical', 1),
  GenreDef(197, 'Latin', 5, nonEnglish: true),
  GenreDef(122, 'Reggaeton', 4, nonEnglish: true),
  GenreDef(16, 'K-Pop & Asian', 3, nonEnglish: true),
  GenreDef(75, 'Brazilian', 1, nonEnglish: true),
  GenreDef(2, 'African', 1, nonEnglish: true),
  GenreDef(81, 'Indian', 1, nonEnglish: true),
];

String genreName(int id) =>
    kGenres.firstWhere((g) => g.id == id, orElse: () => const GenreDef(-1, 'Other', 0)).name;
