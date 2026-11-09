import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import 'catalog.dart';
import 'models.dart';

/// Growable typed arrays (amortised O(1) append, no boxing).
class _I64 {
  Int64List data = Int64List(1024);
  int length = 0;
  void add(int v) {
    if (length == data.length) {
      final n = Int64List(data.length * 2)..setRange(0, length, data);
      data = n;
    }
    data[length++] = v;
  }

  int operator [](int i) => data[i];
  void operator []=(int i, int v) => data[i] = v;
  void removeLast() => length--;
}

class _U16 {
  Uint16List data = Uint16List(1024);
  int length = 0;
  void add(int v) {
    if (length == data.length) {
      final n = Uint16List(data.length * 2)..setRange(0, length, data);
      data = n;
    }
    data[length++] = v;
  }

  int operator [](int i) => data[i];
  void operator []=(int i, int v) => data[i] = v;
  void removeLast() => length--;
}

class _U8 {
  Uint8List data = Uint8List(1024);
  int length = 0;
  void add(int v) {
    if (length == data.length) {
      final n = Uint8List(data.length * 2)..setRange(0, length, data);
      data = n;
    }
    data[length++] = v;
  }

  int operator [](int i) => data[i];
  void operator []=(int i, int v) => data[i] = v;
  void removeLast() => length--;
}

/// Where a card came from.
enum CardSource { wild, pack, quest, market, trade, debug }

/// Card flag bits (packed with rarity in one byte).
const int kFlagShiny = 0x08;
const int kFlagFavorite = 0x10;
const int kFlagListed = 0x20; // escrowed on the market (hidden from trades)
const int kRarityMask = 0x07;
const int kEditionShift = 6; // bits 6–7: Edition index

/// Key identifying a card variant: song × rarity × shiny for standard
/// cards, or song × edition for edition cards (editions are exclusive of
/// rarity/shininess). A player owns at most one card per variant.
int variantKey(int songId, Rarity rarity, bool shiny, Edition edition) =>
    edition == Edition.standard ? songId << 6 | rarity.index << 3 | (shiny ? 4 : 0) : songId << 6 | edition.index;

/// A lightweight view of one owned card.
class OwnedCard {
  OwnedCard(this.uid, this.song, this.rarity, this.shiny, this.favorite,
      this.acquiredAt, this.source, [this.edition = Edition.standard, this.serial = 0]);
  final int uid;
  final Song song;
  final Rarity rarity;
  final bool shiny;
  final bool favorite;
  final DateTime acquiredAt;
  final CardSource source;
  final Edition edition;

  /// Serial number (#1–#10 Canvas, #1–#5 Sample); 0 = unnumbered.
  final int serial;

  int get variant => variantKey(song.id, rarity, shiny, edition);

  CardPayload toPayload() => song.toPayload(
      uid: uid,
      rarity: rarity,
      shiny: shiny,
      edition: edition,
      serial: serial,
      acquiredAt: acquiredAt.millisecondsSinceEpoch);
}

enum CollectionSort { dateAcquired, title, artist, rarity, album, popularity }

class CollectionQuery {
  const CollectionQuery({
    this.text = '',
    this.rarityMask = 0x1F,
    this.shinyOnly = false,
    this.favoritesOnly = false,
    this.normalOnly = false,
    this.genres = const {},
    this.artistId,
    this.albumId,
    this.sort = CollectionSort.dateAcquired,
    this.descending = true,
    this.uniqueSongs = false,
    this.editionMask = 0xF,
  });

  /// Bit i set ⇒ include Edition index i.
  final int editionMask;

  final String text;

  /// Bit i set ⇒ include rarity index i.
  final int rarityMask;
  final bool shinyOnly;
  final bool favoritesOnly;

  /// Only non-shiny cards.
  final bool normalOnly;

  /// Genre ids to include (empty = all).
  final Set<int> genres;
  final int? artistId;
  final int? albumId;
  final CollectionSort sort;
  final bool descending;

  /// Show only the best copy of each song.
  final bool uniqueSongs;

  CollectionQuery copyWith({
    String? text,
    int? rarityMask,
    bool? shinyOnly,
    bool? favoritesOnly,
    bool? normalOnly,
    Set<int>? genres,
    int? Function()? artistId,
    int? Function()? albumId,
    CollectionSort? sort,
    bool? descending,
    bool? uniqueSongs,
    int? editionMask,
  }) =>
      CollectionQuery(
        text: text ?? this.text,
        rarityMask: rarityMask ?? this.rarityMask,
        shinyOnly: shinyOnly ?? this.shinyOnly,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
        normalOnly: normalOnly ?? this.normalOnly,
        genres: genres ?? this.genres,
        artistId: artistId != null ? artistId() : this.artistId,
        albumId: albumId != null ? albumId() : this.albumId,
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        uniqueSongs: uniqueSongs ?? this.uniqueSongs,
        editionMask: editionMask ?? this.editionMask,
      );
}

/// High-performance owned-card store.
///
/// Cards are kept column-wise in typed arrays (≈26 bytes per card), so a
/// 100,000-card collection costs ~2.6 MB of RAM, loads from disk in a few
/// milliseconds and can be filtered + sorted in tens of milliseconds using
/// packed 64-bit integer sort keys.
class CollectionStore extends ChangeNotifier {
  CollectionStore(this.catalog, this.dir);

  final Catalog catalog;
  final Directory dir;

  final _uids = _I64();
  final _songIds = _I64();
  final _acquired = _I64(); // ms since epoch
  final _flags = _U8(); // rarity | shiny | favourite | listed
  final _source = _U8();
  final _serial = _U16();
  final Map<int, int> _indexOfUid = {};
  final Map<int, int> _songCounts = {};
  final Map<int, int> _variants = {}; // variant key → uid
  final List<int> editionCounts = List.filled(Edition.values.length, 0);
  final List<int> rarityCounts = List.filled(5, 0);
  int shinyCount = 0;
  int version = 0;
  Timer? _saveTimer;

  File get _file => File('${dir.path}/collection.bin');
  int get length => _uids.length;
  int get uniqueSongCount => _songCounts.length;
  bool ownsSong(int songId) => (_songCounts[songId] ?? 0) > 0;
  int copiesOf(int songId) => _songCounts[songId] ?? 0;

  /// Whether this exact variant is already owned.
  bool ownsVariant(int songId, Rarity rarity, bool shiny, Edition edition) =>
      _variants.containsKey(variantKey(songId, rarity, shiny, edition));

  int _variantAt(int i) => _editionBits(_flags[i]) != 0
      ? _songIds[i] << 6 | _editionBits(_flags[i])
      : _songIds[i] << 6 | (_flags[i] & kRarityMask) << 3 | (_flags[i] & kFlagShiny != 0 ? 4 : 0);
  static int _editionBits(int f) => (f >> kEditionShift) & 0x3;

  /// Ordering of variants: rarity, then edition, then shiny.
  static int _rankOf(int f) => (f & kRarityMask) * 8 + _editionBits(f) * 2 + (f & kFlagShiny != 0 ? 1 : 0);

  /// Re-rates every card from [rarityOf] (a song has exactly one rarity).
  /// Returns how many cards changed.
  int normalizeRarities(Rarity? Function(int songId) rarityOf) {
    var changed = 0;
    for (var i = 0; i < length; i++) {
      final r = rarityOf(_songIds[i]);
      if (r == null) continue;
      final f = _flags[i];
      if ((f & kRarityMask) == r.index) continue;
      rarityCounts[f & kRarityMask]--;
      rarityCounts[r.index]++;
      _flags[i] = (f & ~kRarityMask) | r.index;
      changed++;
    }
    if (changed > 0) {
      _variants.clear();
      for (var i = 0; i < length; i++) {
        _variants[_variantAt(i)] = _uids[i];
      }
      _changed();
    }
    return changed;
  }

  /// Removes extra copies of any variant (keeps the earliest). Returns the
  /// removed cards so they can be compensated.
  List<OwnedCard> removeDuplicateVariants() {
    final seen = <int, int>{};
    final extra = <int>[];
    for (var i = 0; i < length; i++) {
      final k = _variantAt(i);
      final prev = seen[k];
      if (prev == null) {
        seen[k] = i;
      } else if (_acquired[i] < _acquired[prev]) {
        extra.add(_uids[prev]);
        seen[k] = i;
      } else {
        extra.add(_uids[i]);
      }
    }
    final out = <OwnedCard>[];
    for (final uid in extra) {
      final c = byUid(uid);
      if (c != null) out.add(c);
      remove(uid);
    }
    // Re-index variants from scratch.
    _variants.clear();
    for (var i = 0; i < length; i++) {
      _variants[_variantAt(i)] = _uids[i];
    }
    return out;
  }

  // -------------------------------------------------------------- persist
  static const _magicV1 = 0x54544331; // "TTC1"
  static const _magic = 0x54544332; // "TTC2": + serial (u16)
  static const _recordSizeV1 = 8 + 8 + 8 + 1 + 1;
  static const _recordSize = _recordSizeV1 + 2;

  Future<void> load() async {
    if (!await _file.exists()) return;
    final bytes = await _file.readAsBytes();
    if (bytes.length < 8) return;
    final bd = ByteData.sublistView(bytes);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != _magic && magic != _magicV1) return;
    final size = magic == _magic ? _recordSize : _recordSizeV1;
    final count = bd.getUint32(4, Endian.little);
    var o = 8;
    var repaired = 0;
    for (var i = 0; i < count && o + size <= bytes.length; i++) {
      final uid = bd.getInt64(o, Endian.little);
      final song = bd.getInt64(o + 8, Endian.little);
      final acq = bd.getInt64(o + 16, Endian.little);
      final flags = bytes[o + 24];
      final src = bytes[o + 25];
      final serial = size == _recordSize ? bd.getUint16(o + 26, Endian.little) : 0;
      o += size;
      // Older builds could give two cards the same uid (tapping one opened
      // the other); give any repeat a fresh one.
      if (_indexOfUid.containsKey(uid)) {
        _append(newUid(), song, acq, flags, src, serial);
        repaired++;
      } else {
        _append(uid, song, acq, flags, src, serial);
      }
    }
    version++;
    if (repaired > 0) _scheduleSave();
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    final n = length;
    final bytes = Uint8List(8 + n * _recordSize);
    final bd = ByteData.sublistView(bytes);
    bd.setUint32(0, _magic, Endian.little);
    bd.setUint32(4, n, Endian.little);
    var o = 8;
    for (var i = 0; i < n; i++) {
      bd.setInt64(o, _uids[i], Endian.little);
      bd.setInt64(o + 8, _songIds[i], Endian.little);
      bd.setInt64(o + 16, _acquired[i], Endian.little);
      bytes[o + 24] = _flags[i];
      bytes[o + 25] = _source[i];
      bd.setUint16(o + 26, _serial[i], Endian.little);
      o += _recordSize;
    }
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(_file.path);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), save);
  }

  /// Cancels any pending debounced save (call [save] first to keep changes).
  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
    super.dispose();
  }

  // ------------------------------------------------------------ mutation
  /// A uid no other card has. Time-based but strictly increasing, so cards
  /// created in a burst (packs, the debug generator) never share one even
  /// when the clock is coarse (Windows / Android tick in ~ms steps).
  int newUid() {
    var id = math.max(DateTime.now().microsecondsSinceEpoch * 1000, _lastUid + 1);
    while (_indexOfUid.containsKey(id)) {
      id++;
    }
    return _lastUid = id;
  }

  int _lastUid = 0;

  void _append(int uid, int songId, int acquired, int flags, int source, [int serial = 0]) {
    _indexOfUid[uid] = _uids.length;
    _uids.add(uid);
    _songIds.add(songId);
    _acquired.add(acquired);
    _flags.add(flags);
    _source.add(source);
    _serial.add(serial);
    _songCounts[songId] = (_songCounts[songId] ?? 0) + 1;
    rarityCounts[flags & kRarityMask]++;
    editionCounts[_editionBits(flags)]++;
    if (flags & kFlagShiny != 0) shinyCount++;
    _variants[_variantAt(_uids.length - 1)] = uid;
  }

  /// Adds a new card and returns its uid.
  int add(int songId, Rarity rarity, bool shiny, CardSource source,
      {int? uid, DateTime? at, bool notify = true, Edition edition = Edition.standard, int serial = 0}) {
    final id = uid != null && !_indexOfUid.containsKey(uid) ? uid : newUid();
    // Editions are exclusive: never shiny.
    final sh = shiny && edition == Edition.standard;
    _append(id, songId, (at ?? DateTime.now()).millisecondsSinceEpoch,
        rarity.index | (sh ? kFlagShiny : 0) | edition.index << kEditionShift, source.index, serial);
    if (notify) _changed();
    return id;
  }

  /// Bulk insert (used by packs, inbox claims and the debug generator).
  /// Variants already owned are skipped; returns how many were added.
  int addMany(Iterable<(int songId, Rarity rarity, bool shiny, CardSource src, DateTime at)> cards) {
    var n = 0;
    for (final c in cards) {
      if (ownsVariant(c.$1, c.$2, c.$3, Edition.standard)) continue;
      _append(newUid(), c.$1, c.$5.millisecondsSinceEpoch,
          c.$2.index | (c.$3 ? kFlagShiny : 0), c.$4.index);
      n++;
    }
    _changed();
    return n;
  }

  int addPayload(CardPayload p, CardSource source) {
    catalog.ensureFromPayload(p);
    return add(p.songId, p.rarity, p.shiny, source, uid: p.uid, edition: p.edition, serial: p.serial);
  }

  /// Removes a card (sold, traded, listed). Returns false if not owned.
  bool remove(int uid) {
    final i = _indexOfUid.remove(uid);
    if (i == null) return false;
    final songId = _songIds[i];
    final f = _flags[i];
    final c = (_songCounts[songId] ?? 1) - 1;
    if (c <= 0) {
      _songCounts.remove(songId);
    } else {
      _songCounts[songId] = c;
    }
    rarityCounts[f & kRarityMask]--;
    editionCounts[_editionBits(f)]--;
    if (f & kFlagShiny != 0) shinyCount--;
    final vk = _variantAt(i);
    if (_variants[vk] == uid) _variants.remove(vk);
    final last = length - 1;
    if (i != last) {
      _uids[i] = _uids[last];
      _songIds[i] = _songIds[last];
      _acquired[i] = _acquired[last];
      _flags[i] = _flags[last];
      _source[i] = _source[last];
      _serial[i] = _serial[last];
      _indexOfUid[_uids[i]] = i;
    }
    _uids.removeLast();
    _songIds.removeLast();
    _acquired.removeLast();
    _flags.removeLast();
    _source.removeLast();
    _serial.removeLast();
    _changed();
    return true;
  }

  void setFavorite(int uid, bool fav) {
    final i = _indexOfUid[uid];
    if (i == null) return;
    _flags[i] = fav ? (_flags[i] | kFlagFavorite) : (_flags[i] & ~kFlagFavorite);
    _changed();
  }

  void clear() {
    _indexOfUid.clear();
    _songCounts.clear();
    _variants.clear();
    editionCounts.fillRange(0, editionCounts.length, 0);
    _uids.length = 0;
    _songIds.length = 0;
    _acquired.length = 0;
    _flags.length = 0;
    _source.length = 0;
    _serial.length = 0;
    rarityCounts.fillRange(0, 5, 0);
    shinyCount = 0;
    _changed();
  }

  /// Call after adding cards with `notify: false` (packs): refreshes every
  /// view of the collection and saves.
  void commit() => _changed();

  void _changed() {
    version++;
    _scheduleSave();
    notifyListeners();
  }

  // ---------------------------------------------------------------- reads
  bool contains(int uid) => _indexOfUid.containsKey(uid);

  OwnedCard? byUid(int uid) {
    final i = _indexOfUid[uid];
    return i == null ? null : at(i);
  }

  /// Materialises the card at storage index [i]. Cheap: called only for the
  /// handful of rows actually visible on screen.
  OwnedCard at(int i) {
    final f = _flags[i];
    final songId = _songIds[i];
    final song = catalog.songs[songId] ??
        Song(
            id: songId,
            title: 'Unknown song',
            artistId: 0,
            artistName: '',
            albumId: 0,
            albumTitle: '',
            coverMd5: '');
    return OwnedCard(
      _uids[i],
      song,
      Rarity.fromIndex(f & kRarityMask),
      f & kFlagShiny != 0,
      f & kFlagFavorite != 0,
      DateTime.fromMillisecondsSinceEpoch(_acquired[i]),
      CardSource.values[_source[i].clamp(0, CardSource.values.length - 1)],
      Edition.fromIndex(_editionBits(f)),
      _serial[i],
    );
  }

  int songIdAt(int i) => _songIds[i];
  int uidAt(int i) => _uids[i];
  int rarityAt(int i) => _flags[i] & kRarityMask;
  bool shinyAt(int i) => _flags[i] & kFlagShiny != 0;
  Edition editionAt(int i) => Edition.fromIndex(_editionBits(_flags[i]));

  /// Distinct owned song ids.
  Iterable<int> get ownedSongIds => _songCounts.keys;

  /// Number of distinct songs owned for each artist.
  int distinctSongsByArtist(int artistId) {
    var n = 0;
    for (final id in _songCounts.keys) {
      if (catalog.songs[id]?.artistId == artistId) n++;
    }
    return n;
  }

  /// Best (rarest) owned copy of a song, or null.
  OwnedCard? bestCopyOf(int songId) {
    if (!ownsSong(songId)) return null;
    var best = -1;
    var bestScore = -1;
    for (var i = 0; i < length; i++) {
      if (_songIds[i] != songId) continue;
      final score = _rankOf(_flags[i]);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best < 0 ? null : at(best);
  }

  // ---------------------------------------------------------------- query
  /// Returns storage indices matching [q], in display order.
  ///
  /// Implementation notes (why this is fast for 100k+ cards):
  ///  * filtering touches only the typed arrays and a song lookup;
  ///  * text matching uses a per-song lowercase cache computed once;
  ///  * sorting packs (primary key, secondary key, index) into one 63-bit
  ///    integer and sorts an Int64List — no closures over objects, no
  ///    string comparisons.
  Int32List query(CollectionQuery q) {
    final sw = Stopwatch()..start();
    final n = length;
    final text = q.text.trim().toLowerCase();
    final songs = catalog.songs;
    final hits = Int32List(n);
    var count = 0;
    final needSong = text.isNotEmpty || q.genres.isNotEmpty || q.artistId != null || q.albumId != null;
    if (text.isNotEmpty) _ensureSearchCache();
    for (var i = 0; i < n; i++) {
      final f = _flags[i];
      if ((q.rarityMask >> (f & kRarityMask)) & 1 == 0) continue;
      if (q.shinyOnly && f & kFlagShiny == 0) continue;
      if (q.favoritesOnly && f & kFlagFavorite == 0) continue;
      if (q.normalOnly && f & kFlagShiny != 0) continue;
      if ((q.editionMask >> _editionBits(f)) & 1 == 0) continue;
      if (needSong) {
        final sid = _songIds[i];
        final s = songs[sid];
        if (s == null) continue;
        if (q.genres.isNotEmpty && !q.genres.contains(s.genreId)) continue;
        if (q.artistId != null && s.artistId != q.artistId) continue;
        if (q.albumId != null && s.albumId != q.albumId) continue;
        if (text.isNotEmpty && !(_searchCache[sid]?.contains(text) ?? false)) continue;
      }
      hits[count++] = i;
    }

    var idx = Int32List.sublistView(hits, 0, count);
    if (q.uniqueSongs) idx = _dedupe(idx);

    final keys = Int64List(idx.length);
    final (titleRank, artistRank) =
        (q.sort == CollectionSort.title || q.sort == CollectionSort.artist || q.sort == CollectionSort.album)
            ? catalog.sortRanks()
            : (const <int, int>{}, const <int, int>{});
    const idxBits = 21; // up to ~2M cards
    for (var k = 0; k < idx.length; k++) {
      final i = idx[k];
      int primary;
      switch (q.sort) {
        case CollectionSort.dateAcquired:
          primary = _acquired[i] ~/ 1000; // seconds: fits in 31 bits
        case CollectionSort.rarity:
          final f = _flags[i];
          primary = _rankOf(f) << 31 |
              (_acquired[i] ~/ 1000) & 0x7FFFFFFF;
        case CollectionSort.title:
          primary = (titleRank[_songIds[i]] ?? 0x1FFFFF) << 3 | (_flags[i] & kRarityMask);
        case CollectionSort.artist:
          final s = songs[_songIds[i]];
          primary = (artistRank[s?.artistId] ?? 0x1FFFFF) << 21 |
              ((titleRank[_songIds[i]] ?? 0x1FFFFF) & 0x1FFFFF);
        case CollectionSort.album:
          final s = songs[_songIds[i]];
          primary = ((s?.albumId ?? 0) & 0xFFFFFFFFF) << 3 | (_flags[i] & kRarityMask);
        case CollectionSort.popularity:
          primary = songs[_songIds[i]]?.rank ?? 0;
      }
      keys[k] = (primary << idxBits) | (k & ((1 << idxBits) - 1));
    }
    keys.sort();
    final out = Int32List(keys.length);
    final mask = (1 << idxBits) - 1;
    if (q.descending) {
      for (var k = 0; k < keys.length; k++) {
        out[k] = idx[keys[keys.length - 1 - k] & mask];
      }
    } else {
      for (var k = 0; k < keys.length; k++) {
        out[k] = idx[keys[k] & mask];
      }
    }
    lastQueryMicros = sw.elapsedMicroseconds;
    return out;
  }

  int lastQueryMicros = 0;

  Int32List _dedupe(Int32List idx) {
    final best = <int, int>{};
    for (final i in idx) {
      final sid = _songIds[i];
      final cur = best[sid];
      if (cur == null) {
        best[sid] = i;
      } else {
        final a = _rankOf(_flags[i]);
        final b = _rankOf(_flags[cur]);
        if (a > b) best[sid] = i;
      }
    }
    return Int32List.fromList(best.values.toList());
  }

  final Map<int, String> _searchCache = {};
  int _searchCacheVersion = -1;
  void _ensureSearchCache() {
    if (_searchCacheVersion == catalog.version && _searchCache.length >= _songCounts.length) {
      return;
    }
    for (final sid in _songCounts.keys) {
      if (_searchCache.containsKey(sid)) continue;
      final s = catalog.songs[sid];
      if (s == null) continue;
      _searchCache[sid] = '${s.title}\u0000${s.artistName}\u0000${s.albumTitle}'.toLowerCase();
    }
    _searchCacheVersion = catalog.version;
  }
}
