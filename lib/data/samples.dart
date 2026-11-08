import 'models.dart';

/// How a producer transformed a sample before using it.
enum SampleTransform {
  /// Used as-is.
  none,

  /// Played faster/slower (pitch moves with speed, like a sped-up record).
  speed,

  /// Cut into pieces and re-sequenced.
  chopped,
}

/// One "song A samples song B" relationship, with timings that line the
/// two 30-second previews up.
///
/// There is no free API for sample data (WhoSampled has none, and
/// MusicBrainz rarely records samples), so entries are curated here. The
/// in-app sync tuner (debug menu → card) can refine the timings and saves
/// overrides locally.
class SampleInfo {
  const SampleInfo({
    required this.song,
    required this.source,
    required this.sourceYear,
    required this.sourceAt,
    required this.songAt,
    this.rate = 1.0,
    this.transform = SampleTransform.none,
    this.chopBeats = const [],
    this.bpm = 0,
    this.note = '',
  });

  /// The modern song (the one that is collected).
  final Song song;

  /// The sampled original.
  final Song source;
  final int sourceYear;

  /// Seconds into the source's preview where the sampled passage starts.
  final double sourceAt;

  /// Seconds into the modern song's preview where that passage is heard.
  final double songAt;

  /// Playback-rate change applied by the producer (1.0 = untouched;
  /// 1.08 = sped up 8%).
  final double rate;
  final SampleTransform transform;

  /// For chopped samples: the order in which beat-length slices of the
  /// source passage are replayed (slice indices).
  final List<int> chopBeats;

  /// Tempo of the modern song (for chop timing); 0 = unknown.
  final double bpm;
  final String note;

  SampleInfo copyWith({double? sourceAt, double? songAt, double? rate}) => SampleInfo(
        song: song,
        source: source,
        sourceYear: sourceYear,
        sourceAt: sourceAt ?? this.sourceAt,
        songAt: songAt ?? this.songAt,
        rate: rate ?? this.rate,
        transform: transform,
        chopBeats: chopBeats,
        bpm: bpm,
        note: note,
      );
}

/// Curated sample relationships, keyed by the modern song's Deezer id.
class SampleLibrary {
  SampleLibrary._();

  static final Map<int, SampleInfo> _entries = {
    for (final e in _curated) e.song.id: e,
  };

  /// Local timing overrides from the sync tuner: songId → (sourceAt, songAt, rate).
  static final Map<int, (double, double, double)> overrides = {};

  static bool has(int songId) => _entries.containsKey(songId);

  static SampleInfo? of(int songId) {
    final e = _entries[songId];
    if (e == null) return null;
    final o = overrides[songId];
    return o == null ? e : e.copyWith(sourceAt: o.$1, songAt: o.$2, rate: o.$3);
  }

  static Iterable<SampleInfo> get all => _entries.values;
}

const _curated = <SampleInfo>[
  SampleInfo(
    song: Song(
      id: 630827252,
      title: 'I Wonder',
      artistId: 230,
      artistName: 'Kanye West',
      albumId: 86994002,
      albumTitle: 'Graduation',
      coverMd5: '8c6578a2099561992fb7544e6826f767',
      genreId: 116,
      rank: 763200,
      duration: 243,
    ),
    source: Song(
      id: 93329626,
      title: 'My Song',
      artistId: 3537,
      artistName: 'Labi Siffre',
      albumId: 9479122,
      albumTitle: 'Crying Laughing Loving Lying',
      coverMd5: '7c6b55e8f83276097d4d0727775cf890',
      genreId: 152,
      rank: 617793,
      duration: 284,
    ),
    sourceYear: 1972,
    sourceAt: 14.11,
    songAt: 7.66,
    rate: 1.0,
    transform: SampleTransform.chopped,
    // Two-beat phrases re-sequenced, as in the hook.
    chopBeats: [0, 1, 0, 1, 2, 3, 2, 3],
    bpm: 95.7,
    note: 'Piano and vocal from "My Song", chopped into the hook.',
  ),
];
