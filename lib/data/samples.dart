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
// spectral alignment against Deezer's I Wonder preview (630827252), where
// the hook loops every 10.03 s (4 bars at 95.7 BPM):
//   "And I wonder…"     source 7.60  ↔ song  6.542 / 16.573 / 26.604
//   "…what it means"    source 12.40 ↔ song 11.39 and again 13.827
// i.e. Kanye plays the line through to "what it means" and repeats
// "what it means" 2.437 s later — exactly what the breakdown re-enacts.
// Timeline (seconds from the start of the breakdown). After the first,
// animated rewind every jump back is instant (no pause, no fade); the only
// other fade is the crossfade from Labi Siffre into I Wonder.
const double _wimGap = 13.827 - 11.39; // "what it means" → repeat, in I Wonder
const double _wimToAiw = 16.573 - 13.827; // repeat → next "And I wonder", in I Wonder
const double _aiw = 7.6; // "And I wonder" onset in the source
// "…what it MEANS" decays until ~14.4 s; the next words start at 14.7 s.
const double _wimCut = 14.65; // cut just before "to find"
const double _wimEnd = 14.55;
const double _xf = 0.015; // de-click at every cut (not an audible fade)
const double _origEnd = 21.0; // past "…dreams come true"
// 1. The original, from 3.0 s. At its end it fades out while the playhead
// visibly rewinds to "And I wonder" (the only animated rewind); every jump
// after that is instant.
const double _rew1 = _origEnd - 3.0;
const double _rewind1 = 0.9;
const double _flip1 = _rew1 + _rewind1;
const double _flip1From = 7.35; // just before "And I wonder"
// The line reaches the cut, and the repeat picks up the quiet breath before
// "what it" so the phrase loops back-to-back, landing on the hook's timing.
const double _flip1Loop = _flip1 + (_wimCut - _flip1From);
const double _flip1Wim2 = _flip1 + (12.4 - _flip1From) + _wimGap;
const double _repeatFrom = 12.4 - (_flip1Wim2 - _flip1Loop);
// 2. Straight after the repeat, back to the line again — starting in the
// quiet before "And" so that "And I wonder" lands where it does in the hook.
const double _flip2 = _flip1Loop + (_wimCut - _repeatFrom);
const double _flip2Aiw = _flip1Wim2 + _wimToAiw;
const double _flip2From = _aiw - (_flip2Aiw - _flip2);
const double _flip2Loop = _flip2 + (_wimCut - _flip2From);
// I Wonder's "And I wonder" (6.542 s into its preview) lines up with Labi's.
const double _songAiw = 6.542;
const double _songFrom = _songAiw - 0.1;
const double _songAt = _flip2Aiw - 0.1;
const double _songEnd = _songAt + (29.9 - _songFrom);

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
    sourceItunesId: 955676429,
    bpm: 95.7,
    alignSource: 12.4,
    alignSong: 13.827,
    clips: [
      // 1. The original: "…And I wonder, if you know, what it means, to find
      //    your dreams come true…"
      SampleClip(SampleTrack.source, at: 0, from: 3.0, to: _origEnd, fadeOut: 0.6),
      // 2. Jump back: "And I wonder, if you know, what it means" — and
      //    "what it means" again, back-to-back, spaced as in the hook.
      SampleClip(SampleTrack.source, at: _flip1, from: _flip1From, to: _wimCut, fadeOut: _xf),
      SampleClip(SampleTrack.source, at: _flip1Loop, from: _repeatFrom, to: _wimCut, fadeOut: _xf),
      // 3. Straight back again, now with I Wonder — the same words — coming
      //    in underneath, matched one-to-one: the single crossfade.
      SampleClip(SampleTrack.source, at: _flip2, from: _flip2From, to: _wimCut, fadeOut: _wimCut - _flip2From),
      SampleClip(SampleTrack.source, at: _flip2Loop, from: _repeatFrom, to: _wimEnd, volume: 0.3, fadeOut: _wimEnd - _repeatFrom),
      SampleClip(SampleTrack.song, at: _songAt, from: _songFrom, fadeIn: _flip2Loop - _songAt, fadeOut: _xf),
    ],
    rewinds: [
      SampleRewind(at: _rew1, duration: _rewind1, from: _origEnd, to: _flip1From),
    ],
    stages: [
      SampleStage('Labi Siffre · My Song (1972)', 0, _rew1),
      SampleStage('Rewind to "And I wonder"', _rew1, _flip1),
      SampleStage('"…what it means, what it means"', _flip1, _flip2),
      SampleStage('Kanye West · I Wonder', _flip2, _songEnd),
    ],
    sourceEnvelope: 'Kic3RTVGMDc5NS4lIB8nKyowKywrJjt6VC4oO09JTWRYd2/X/73Ds6WSgmNRQURTcnJeYWBRQz8zNTcxSltcYWN3cVk+Rj4wKScnNzpKPUEsKC4jLyskJDY0OC4pIiIjHh8cGx87Q05ISls+RjwzMTIuLSolJR4ZGBcYGBUXHkM8REI+MUMxKDEnJygqJiMiIRshGB8aEg8VP0Q8RDk7ND48LjEiMDUsNDIkLiIkHRkVFSRtcXZ0Y2JbVkRUPklQPUQ3QCQhIB0XFxcgTUQ4MSosICglJSMeLEgySEM+ODM7Ky8lKTVIS1ZPQThBPDIzNyswKS4gIiAeHhQTEBMOSj9OPUw2Qiw8LzkrNzMrRDIsKCwfHhgYExw+RDUzLCElIR4WDQ4ZMEJGRTZEPi86MiUsLSRSdGVdUUFEREI5OkVNZWdbWldQS1dPNzk0Z32PdUo+VIRhZUxKLmpbR0dCQzswKSsmIB8sPkM0My1ALiYtIR0pPC0tNzEmIh8cHxsdOTtETT88OjgsODQuOj1dhmI5KiIlGycnIjxIYVhNYlpFT0MwPlKSpristpZjWltUVkdSSml5d3lPUkRZRk9GVkI1NCYlIhweGxgaGSs0P0Q4SzlCOzQzNTNKQzdJOTQtJSclIhwgLC9SOk5EOkM1NjqPg7XM8L6EsKuli4lGQWdnfYV0g0I3OTQ5YGyJspeVpa2koJmbmpmgrKmUhXePhoB/jHF5hE5JT1lMLChDMzMoLzA5QUA3MzU1MjEqLDQ3KiszNiomJh0fHTFARVNFSUs4PT80QC0wWGlkSUI/NEM6PDo5XlteT0NCRTg2NTAwP1pYPUI0LTQqQC8sKEm1vr3AkaaEmIyOh3JwinBscoVtdpSJi2AtLi0+PkdSS1V1XFRYTVJeTU1aVlRCQ0E9NSEhFhMSEx8uMjY9Njs/PDk5OTo1MTAtMzMqKBsUExIMDAsgFBVcpXhBW1JVVyQUFTAfFScuJy4uLS0vMCcoJihRVElLQ0lHVj8wKyEXNWBBQkFKVD8/NionKSYlKyggGxobFxgWFBMfO0BSVUw1RDM6IiwmLCQlJyAlHSEeJRobGCMqMzMyKyUvKSonKSI1Pz84ODc8OzwyNDEwPUI5Ni8vLCgZGhgTLE5IU0lCPDIwIxsUDg1FOj8xOzktKC0kIyQhJR8gIxoZFRgUEhAREhA8Q05OTUpCNCosKScfJyMmJCAkHx0YGxQXGjtCQDs3NDY1My8uLURKS09FPD45OkFFNDMzMjU2KiwlIR0YFBASL1I3NCw6LjAgFhYPDCU9MzgyOCouJjEoHSYkHx4cGhkUEw8SEBISLjVWVlA5OC0rJiUkHSAiJSEaHR0dGRYeFRIqPUw9NC8zNTczLywqLkFEQzg9OkBCQDY5NEA5LzIsJiEkIxcZEw82TUk8Ozw4NTgnIR4TRGVPaGBQTUo+RTk6SDc9PzQ9KiYyHiElGCIjJldfXkRKOD0uMiYoJDiflWSHaEguUCsnLBwbHxMXGBUYRD8kHhmDgoyrbndgVE1gSEZLdKd6cmAvLDIjNBsgICyLp4NiYm1maW1oaFFTUlVXTkxNRENGQ0Y+PYZgf20=',
    note: 'Labi Siffre\'s line "And I wonder if you know what it means" is looped, with "what it means" repeated, as the hook.',
  ),
];
