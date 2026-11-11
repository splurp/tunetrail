import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// Which preview a breakdown step plays.
enum SampleTrack { source, song }

/// One clip on a breakdown timeline: play [track] from [from] to [to]
/// (preview seconds), starting [at] seconds into the breakdown.
class SampleClip {
  const SampleClip(this.track, {required this.at, required this.from, this.to, this.fadeIn = 0, this.fadeOut = 0.06, this.volume = 0.9});
  final SampleTrack track;

  /// Peak volume (0–1). A clip fades in to it over [fadeIn] and out to
  /// silence over the last [fadeOut] seconds — so a [fadeOut] as long as
  /// the clip makes it fade across its whole length (a crossfade).
  final double volume;
  final double at, from;

  /// End position in the preview (null = play to the end of the clip).
  final double? to;
  final double fadeIn, fadeOut;

  double get duration => (to ?? 29.9) - from;
  double get end => at + duration;
}

/// The playhead visibly scrubbing back on the source waveform.
class SampleRewind {
  const SampleRewind({required this.at, required this.duration, required this.from, required this.to});
  final double at, duration, from, to;
}

/// A labelled section of the breakdown timeline.
class SampleStage {
  const SampleStage(this.label, this.start, this.end);
  final String label;
  final double start, end;
}

/// One "song samples record" relationship plus a scripted, Tracklib-style
/// breakdown that lines the two previews up.
///
/// There's no free API for sample data (WhoSampled has none, MusicBrainz
/// rarely records samples), so entries are curated and their timings are
/// measured offline by aligning the two previews' spectra. The debug sync
/// tuner can shift either track and saves overrides locally.
class SampleInfo {
  const SampleInfo({
    required this.song,
    required this.source,
    required this.sourceYear,
    required this.clips,
    required this.stages,
    this.rewinds = const [],
    required this.alignSource,
    required this.alignSong,
    this.sourceItunesId,
    this.sourceEnvelope,
    this.bpm = 0,
    this.note = '',
    this.sourceShift = 0,
    this.songShift = 0,
  });

  /// The modern song (the collected card).
  final Song song;

  /// The sampled original.
  final Song source;
  final int sourceYear;

  final List<SampleClip> clips;
  final List<SampleStage> stages;
  final List<SampleRewind> rewinds;

  /// A source/song position pair where the sampled audio coincides; the
  /// waveform panel aligns the two tracks on it.
  final double alignSource, alignSong;

  /// When set, the source audio is Apple's iTunes preview of this track id
  /// (some records' Deezer previews don't contain the sampled passage).
  final int? sourceItunesId;

  /// Pre-computed loudness envelope of the source preview (40 values/s,
  /// base64 bytes) for sources the audio engine can't decode itself.
  final String? sourceEnvelope;

  final double bpm;
  final String note;

  /// Tuner offsets (seconds) added to every source / song position.
  final double sourceShift, songShift;

  double get length => stages.isEmpty ? 0 : stages.last.end;

  Float32List? decodedSourceEnvelope() {
    final e = sourceEnvelope;
    if (e == null) return null;
    final b = base64.decode(e);
    return Float32List.fromList([for (final v in b) v / 255]);
  }

  SampleInfo shifted(double src, double song) => SampleInfo(
        song: this.song,
        source: source,
        sourceYear: sourceYear,
        clips: clips,
        stages: stages,
        rewinds: rewinds,
        alignSource: alignSource,
        alignSong: alignSong,
        sourceItunesId: sourceItunesId,
        sourceEnvelope: sourceEnvelope,
        bpm: bpm,
        note: note,
        sourceShift: src,
        songShift: song,
      );
}

/// Curated sample relationships, keyed by the modern song's Deezer id.
class SampleLibrary {
  SampleLibrary._();

  static final Map<int, SampleInfo> _entries = {for (final e in _curated) e.song.id: e};

  /// Local timing overrides from the sync tuner: songId → (sourceShift, songShift).
  static final Map<int, (double, double)> overrides = {};

  static bool has(int songId) => _entries.containsKey(songId);

  static SampleInfo? of(int songId) {
    final e = _entries[songId];
    if (e == null) return null;
    final o = overrides[songId];
    return o == null ? e : e.shifted(o.$1, o.$2);
  }

  static Iterable<SampleInfo> get all => _entries.values;
}

// ---------------------------------------------------------------- I Wonder
// Source: Apple's preview of Labi Siffre – "My Song" (iTunes 955676429);
// Deezer's preview of it starts after the sampled line. Measured by
// spectral alignment against Deezer's I Wonder preview (630827252):
//   "And I wonder…"   source 7.60  ↔ song 6.542 / 16.573 / 26.604
// Beat grids (onset comb fit): the source runs at 93.92 BPM with beats at
// 3.216 + n·0.6388 s; I Wonder at 95.68 BPM, beats at 3.528 + n·0.6271 s.
// In both, "And I wonder" is a pickup just before a downbeat (source 7.688,
// song 16.697).
//
// The breakdown: Labi Siffre's hook line from a bar before it, then a hard
// cut so that I Wonder's "And I wonder" (16.573, opening Kanye's verse)
// lands exactly 16 of Labi's beats after his — on his next bar line, with
// the drums carrying straight on. Then the verse, the following
// "And I wonder" (26.604), and a fade out.
const double _xf = 0.015; // de-click at the cut (not an audible fade)
const double _srcBeat = 0.6388;
const double _srcDownbeat = 7.688; // the beat "And I wonder" leads into
const double _srcFrom = _srcDownbeat - 4 * _srcBeat - 0.08; // a bar before
const double _aiwAt = 7.6 - _srcFrom; // "And I wonder" in breakdown time
const double _songDownbeat = 16.697; // the beat I Wonder's "And I wonder" leads into
const double _songFrom = 16.573 - 0.1; // a hair before "And"
const double _songNextAiw = 26.604;
// I Wonder's downbeat on Labi's 16th beat after his.
const double _cut = (_srcDownbeat + 16 * _srcBeat - _srcFrom) - (_songDownbeat - _songFrom);
const double _songEnd = _cut + (29.9 - _songFrom);
double _src(double p) => p - _srcFrom; // source preview time → breakdown time
double _song(double p) => _cut + (p - _songFrom); // song preview time → breakdown time

/// The lyric box during the I Wonder breakdown, one entry per line, in
/// order (the slots below set when each shows). Lyrics aren't bundled: an
/// empty entry shows the playing track's artist and title instead.
const List<String> kIWonderLyrics = [
  '', // 1. Labi Siffre: the hook line, first phrase
  '', // 2.
  '', // 3.
  '', // 4. last phrase before the cut
  '', // 5. I Wonder: the sampled hook that opens the verse
  '', // 6. Kanye West's verse, first line
  '', // 7.
  '', // 8.
  '', // 9.
  '', // 10. last verse line
  '', // 11. the sampled hook again, fading out
];

// (lyric index, start, end) in breakdown time.
final _iWonderLines = <(int, double, double)>[
  (0, _aiwAt - 0.05, _src(8.95)),
  (1, _src(8.95), _src(11.4)),
  (2, _src(11.4), _src(14.45)),
  (3, _src(14.45), _cut),
  (4, _cut, _song(17.35)),
  (5, _song(17.35), _song(18.85)),
  (6, _song(18.85), _song(19.9)),
  (7, _song(19.9), _song(20.95)),
  (8, _song(20.95), _song(23.9)),
  (9, _song(23.9), _song(26.5)),
  (10, _song(26.5), _songEnd),
];

final _curated = <SampleInfo>[
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
    sourceItunesId: 955676429,
    bpm: 95.7,
    alignSource: 12.4,
    alignSong: 13.827,
    clips: [
      // Labi Siffre's hook line, from a bar before it to the cut.
      SampleClip(SampleTrack.source, at: 0, from: _srcFrom, to: _srcFrom + _cut, fadeIn: 0.3, fadeOut: _xf),
      // Hard cut on the bar line into I Wonder's verse; it fades out after
      // the next "And I wonder".
      SampleClip(SampleTrack.song, at: _cut, from: _songFrom, fadeIn: _xf, fadeOut: 29.9 - (_songNextAiw + 0.9)),
    ],
    // One stage per lyric line (see [kIWonderLyrics]). Onsets measured
    // from the vocals' energy in each preview.
    stages: [
      SampleStage('', 0, _aiwAt - 0.05),
      for (final (i, start, end) in _iWonderLines) SampleStage(kIWonderLyrics[i], start, end),
    ],
    sourceEnvelope: 'Kic3RTVGMDc5NS4lIB8nKyowKywrJjt6VC4oO09JTWRYd2/X/73Ds6WSgmNRQURTcnJeYWBRQz8zNTcxSltcYWN3cVk+Rj4wKScnNzpKPUEsKC4jLyskJDY0OC4pIiIjHh8cGx87Q05ISls+RjwzMTIuLSolJR4ZGBcYGBUXHkM8REI+MUMxKDEnJygqJiMiIRshGB8aEg8VP0Q8RDk7ND48LjEiMDUsNDIkLiIkHRkVFSRtcXZ0Y2JbVkRUPklQPUQ3QCQhIB0XFxcgTUQ4MSosICglJSMeLEgySEM+ODM7Ky8lKTVIS1ZPQThBPDIzNyswKS4gIiAeHhQTEBMOSj9OPUw2Qiw8LzkrNzMrRDIsKCwfHhgYExw+RDUzLCElIR4WDQ4ZMEJGRTZEPi86MiUsLSRSdGVdUUFEREI5OkVNZWdbWldQS1dPNzk0Z32PdUo+VIRhZUxKLmpbR0dCQzswKSsmIB8sPkM0My1ALiYtIR0pPC0tNzEmIh8cHxsdOTtETT88OjgsODQuOj1dhmI5KiIlGycnIjxIYVhNYlpFT0MwPlKSpristpZjWltUVkdSSml5d3lPUkRZRk9GVkI1NCYlIhweGxgaGSs0P0Q4SzlCOzQzNTNKQzdJOTQtJSclIhwgLC9SOk5EOkM1NjqPg7XM8L6EsKuli4lGQWdnfYV0g0I3OTQ5YGyJspeVpa2koJmbmpmgrKmUhXePhoB/jHF5hE5JT1lMLChDMzMoLzA5QUA3MzU1MjEqLDQ3KiszNiomJh0fHTFARVNFSUs4PT80QC0wWGlkSUI/NEM6PDo5XlteT0NCRTg2NTAwP1pYPUI0LTQqQC8sKEm1vr3AkaaEmIyOh3JwinBscoVtdpSJi2AtLi0+PkdSS1V1XFRYTVJeTU1aVlRCQ0E9NSEhFhMSEx8uMjY9Njs/PDk5OTo1MTAtMzMqKBsUExIMDAsgFBVcpXhBW1JVVyQUFTAfFScuJy4uLS0vMCcoJihRVElLQ0lHVj8wKyEXNWBBQkFKVD8/NionKSYlKyggGxobFxgWFBMfO0BSVUw1RDM6IiwmLCQlJyAlHSEeJRobGCMqMzMyKyUvKSonKSI1Pz84ODc8OzwyNDEwPUI5Ni8vLCgZGhgTLE5IU0lCPDIwIxsUDg1FOj8xOzktKC0kIyQhJR8gIxoZFRgUEhAREhA8Q05OTUpCNCosKScfJyMmJCAkHx0YGxQXGjtCQDs3NDY1My8uLURKS09FPD45OkFFNDMzMjU2KiwlIR0YFBASL1I3NCw6LjAgFhYPDCU9MzgyOCouJjEoHSYkHx4cGhkUEw8SEBISLjVWVlA5OC0rJiUkHSAiJSEaHR0dGRYeFRIqPUw9NC8zNTczLywqLkFEQzg9OkBCQDY5NEA5LzIsJiEkIxcZEw82TUk8Ozw4NTgnIR4TRGVPaGBQTUo+RTk6SDc9PzQ9KiYyHiElGCIjJldfXkRKOD0uMiYoJDiflWSHaEguUCsnLBwbHxMXGBUYRD8kHhmDgoyrbndgVE1gSEZLdKd6cmAvLDIjNBsgICyLp4NiYm1maW1oaFFTUlVXTkxNRENGQ0Y+PYZgf20=',
    note: 'Labi Siffre\'s line "And I wonder if you know what it means" is looped, with "what it means" repeated, as the hook.',
  ),
];
