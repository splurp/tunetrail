import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tunetrail/data/catalog.dart';
import 'package:tunetrail/data/collection.dart';
import 'package:tunetrail/data/deezer_api.dart';
import 'package:tunetrail/data/models.dart';
import 'package:tunetrail/game/audio_service.dart';
import 'package:tunetrail/game/spawns.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

Future<Catalog> _catalog(Directory dir, int songs) async {
  final c = Catalog(DeezerApi(), dir);
  await c.load();
  final genres = [for (final g in kGenres) g.id];
  c.addSongs([
    for (var i = 1; i <= songs; i++)
      Song(
        id: i,
        title: 'Song ${(i * 7919) % songs}',
        artistId: i % 500,
        artistName: 'Artist ${i % 500}',
        albumId: i % 3000,
        albumTitle: 'Album ${i % 3000}',
        coverMd5: '',
        genreId: genres[i % genres.length],
        rank: (i * 104729) % 1000000,
      )
  ]);
  return c;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tt'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('100k-card collection: query, sort, persist', () async {
    final cat = await _catalog(dir, 20000);
    final col = CollectionStore(cat, dir);
    final rng = Rng(1);
    final now = DateTime.now();
    col.addMany([
      for (var i = 0; i < 100000; i++)
        // One card per variant (song × rarity × shiny).
        (1 + i % 20000, Rarity.values[(i ~/ 20000) % 5], i % 128 == 0, CardSource.debug, now.subtract(Duration(seconds: rng.nextInt(1 << 25))))
    ]);
    expect(col.length, 100000);

    final sw = Stopwatch()..start();
    final byDate = col.query(const CollectionQuery());
    final tDate = sw.elapsedMilliseconds;
    expect(byDate.length, 100000);
    for (var i = 1; i < byDate.length; i++) {
      expect(col.at(byDate[i - 1]).acquiredAt.millisecondsSinceEpoch ~/ 1000 >= col.at(byDate[i]).acquiredAt.millisecondsSinceEpoch ~/ 1000, isTrue);
      if (i > 2000) break;
    }

    sw.reset();
    final byTitle = col.query(const CollectionQuery(sort: CollectionSort.title, descending: false));
    final tTitle = sw.elapsedMilliseconds;
    for (var i = 1; i < 2000; i++) {
      expect(col.at(byTitle[i - 1]).song.title.toLowerCase().compareTo(col.at(byTitle[i]).song.title.toLowerCase()) <= 0, isTrue);
    }

    sw.reset();
    final legends = col.query(const CollectionQuery(rarityMask: 1 << 4, sort: CollectionSort.artist, descending: false));
    final tFilter = sw.elapsedMilliseconds;
    expect(legends.every((i) => col.rarityAt(i) == 4), isTrue);
    expect(legends.length, col.rarityCounts[4]);

    sw.reset();
    final search = col.query(const CollectionQuery(text: 'artist 42'));
    final tSearch = sw.elapsedMilliseconds;
    expect(search, isNotEmpty);

    final unique = col.query(const CollectionQuery(uniqueSongs: true));
    expect(unique.length, col.uniqueSongCount);

    // ignore: avoid_print
    print('100k cards: date ${tDate}ms, title ${tTitle}ms, rarity+artist ${tFilter}ms, search ${tSearch}ms');

    await col.save();
    final col2 = CollectionStore(cat, dir);
    await col2.load();
    expect(col2.length, 100000);
    expect(col2.rarityCounts, col.rarityCounts);
    expect(col2.shinyCount, col.shinyCount);

    // Removal keeps stats consistent.
    final uid = col2.at(0).uid;
    expect(col2.remove(uid), isTrue);
    expect(col2.length, 99999);
    expect(col2.contains(uid), isFalse);
  });

  test('spawns are deterministic for a place and time', () async {
    final cat = await _catalog(dir, 5000);
    final e = SpawnEngine(cat);
    final t = DateTime(2026, 6, 1, 12, 3);
    final a = e.around(const LatLng(40.758, -73.9855), now: t);
    final b = e.around(const LatLng(40.758, -73.9855), now: t);
    expect(a, isNotEmpty);
    expect([for (final s in a) '${s.id}:${s.song.id}:${s.rarity}'], [for (final s in b) '${s.id}:${s.song.id}:${s.rarity}']);
    final later = e.around(const LatLng(40.758, -73.9855), now: t.add(const Duration(hours: 1)));
    expect(later.map((s) => s.id).toSet().intersection(a.map((s) => s.id).toSet()), isEmpty);
  });

  test('spawn positions do not move as the player walks', () async {
    final cat = await _catalog(dir, 3000);
    final e = SpawnEngine(cat);
    final t = DateTime(2026, 6, 1, 12, 3);
    final a = {for (final s in e.around(const LatLng(40.7580, -73.9855), now: t)) s.id: s.point};
    // Walk ~150 m north and a little east.
    final b = {for (final s in e.around(const LatLng(40.7594, -73.9850), now: t)) s.id: s.point};
    final common = a.keys.toSet().intersection(b.keys.toSet());
    expect(common.length, greaterThan(5));
    for (final id in common) {
      expect(a[id]!.latitude, b[id]!.latitude);
      expect(a[id]!.longitude, b[id]!.longitude);
    }
  });

  test('rarity spread: tiny artists Common–Rare, superstars mostly Epic/Legendary', () {
    List<Rarity> spread(double tier) => [for (var i = 0; i < 20; i++) Catalog.rarityFor(tier, i / 19)];
    final tiny = spread(0);
    expect(tiny.toSet(), {Rarity.common, Rarity.uncommon, Rarity.rare});
    final star = spread(1);
    expect(star.where((r) => r.index >= Rarity.epic.index).length, greaterThanOrEqualTo(16));
    expect(star.first, Rarity.rare);
    expect(star.last, Rarity.legendary);
  });

  test('play counts decide a superstar\'s rarities (Stronger beats Bound 2)', () async {
    final c = Catalog(DeezerApi(), dir);
    await c.load();
    Song k(int id, String t, int rank, int plays) =>
        Song(id: id, title: t, artistId: 230, artistName: 'Kanye West', albumId: 1, albumTitle: 'A', coverMd5: '', genreId: 116, rank: rank, plays: plays);
    c.addSongs([
      k(1, 'Stronger', 649848, 31000000),
      k(2, 'Runaway', 870128, 21000000),
      k(3, 'Bound 2', 777130, 22000000),
      for (var i = 0; i < 17; i++) k(10 + i, 'Song $i', 500000 + i * 1000, 3000000 + i * 500000),
      k(40, 'Stronger (Radio Edit)', 300000, 150000),
    ]);
    expect(c.rarityOf(c.songs[1]!), Rarity.legendary);
    expect(c.rarityOf(c.songs[3]!), Rarity.legendary);
    expect(c.rarityOf(c.songs[40]!), Rarity.rare);
  });

  test('favourite artists spawn ~10x more often as a whole', () async {
    // Realistically sized pools: 24k songs, 600 artists × 40 songs.
    final cat = Catalog(DeezerApi(), dir);
    await cat.load();
    final genres = [for (final g in kGenres) g.id];
    cat.addSongs([
      for (var i = 1; i <= 24000; i++)
        Song(
          id: i,
          title: 'S$i',
          artistId: i % 600,
          artistName: 'A${i % 600}',
          albumId: 1,
          albumTitle: '',
          coverMd5: '',
          genreId: genres[i % genres.length],
          rank: (i * 104729) % 1000000,
        )
    ]);
    final e = SpawnEngine(cat);
    (int, int) sample() {
      var fav = 0, total = 0;
      // Enough spawns that the (rare) baseline isn't dominated by noise.
      for (var w = 0; w < 2500; w++) {
        for (final s in e.around(const LatLng(40.758, -73.9855), now: DateTime(2026, 1, 1).add(Duration(minutes: 15 * w)))) {
          total++;
          if (s.song.artistId == 7) fav++;
        }
      }
      return (fav, total);
    }

    final (before, n1) = sample();
    cat.favoriteArtists = {7};
    final (after, n2) = sample();
    final ratio = (after / n2) / (before / n1);
    expect(ratio, greaterThan(6));
    expect(ratio, lessThan(14));

    // Many favourites: the *list* is ~10x as likely, not each artist, and
    // picks are spread across the listed artists.
    final many = {for (var a = 100; a < 130; a++) a};
    var favN = 0, total = 0;
    final hits = <int, int>{};
    cat.favoriteArtists = {};
    for (var w = 0; w < 300; w++) {
      for (final s in e.around(const LatLng(40.758, -73.9855), now: DateTime(2026, 1, 1).add(Duration(minutes: 15 * w)))) {
        total++;
        if (many.contains(s.song.artistId)) favN++;
      }
    }
    final baseShare = favN / total;
    cat.favoriteArtists = many;
    favN = 0;
    total = 0;
    for (var w = 0; w < 300; w++) {
      for (final s in e.around(const LatLng(40.758, -73.9855), now: DateTime(2026, 1, 1).add(Duration(minutes: 15 * w)))) {
        total++;
        if (many.contains(s.song.artistId)) {
          favN++;
          hits[s.song.artistId] = (hits[s.song.artistId] ?? 0) + 1;
        }
      }
    }
    final boosted = favN / total;
    final expected = 10 * baseShare / (1 + 9 * baseShare);
    expect(boosted / expected, inInclusiveRange(0.7, 1.3));
    expect(hits.length, greaterThan(20));
  });

  test('song json round trip and cdn urls', () {
    const s = Song(id: 5, title: 'T', artistId: 1, artistName: 'A', albumId: 2, albumTitle: 'B', coverMd5: '0123456789abcdef0123456789abcdef', genreId: 132, rank: 9);
    final r = Song.fromJson(s.toJson());
    expect(r.title, 'T');
    expect(r.genreId, 132);
    expect(s.cover(), contains('/images/cover/0123456789abcdef0123456789abcdef/250x250'));
    expect(md5FromUrl('https://cdn-images.dzcdn.net/images/artist/71eeb9e2eeb375df35a3c0654a5a01ab/56x56-000000-80-0-0.jpg'), '71eeb9e2eeb375df35a3c0654a5a01ab');
  });

  test('one copy per variant; editions are separate variants', () async {
    final cat = await _catalog(dir, 50);
    final col = CollectionStore(cat, dir);
    col.add(1, Rarity.rare, false, CardSource.wild);
    col.add(1, Rarity.rare, true, CardSource.wild);
    col.add(1, Rarity.rare, false, CardSource.wild, edition: Edition.movie);
    col.add(1, Rarity.rare, false, CardSource.wild, edition: Edition.sample);
    expect(col.ownsVariant(1, Rarity.rare, false, Edition.standard), isTrue);
    expect(col.ownsVariant(1, Rarity.rare, true, Edition.movie), isFalse);
    expect(col.editionCounts, [2, 1, 1]);
    // Duplicates from older saves are folded away (earliest kept).
    col.add(1, Rarity.rare, false, CardSource.pack, at: DateTime(2020));
    col.add(1, Rarity.rare, false, CardSource.pack);
    expect(col.length, 6);
    final removed = col.removeDuplicateVariants();
    expect(removed.length, 2);
    expect(col.length, 4);
    final kept = col.byUid(col.uidAt(col.query(const CollectionQuery(editionMask: 1, normalOnly: true)).first))!;
    expect(kept.acquiredAt.year, 2020);
    expect(col.query(const CollectionQuery(editionMask: 1 << 2)).length, 1);
    // Persisted with the edition bits.
    await col.save();
    final again = CollectionStore(cat, dir);
    await again.load();
    expect(again.editionCounts, [2, 1, 1]);
    expect(again.ownsVariant(1, Rarity.rare, false, Edition.sample), isTrue);
    // Payload round trip keeps the edition.
    final p = CardPayload.fromJson(again.byUid(again.uidAt(again.query(const CollectionQuery(editionMask: 2)).first))!.toPayload().toJson());
    expect(p.edition, Edition.movie);
  });

  test('beat analysis finds tempo and phase of a click track', () {
    const fs = 8000;
    const bpm = 96.0, phase = 0.37;
    final x = Float32List(fs * 20);
    final rnd = math.Random(2);
    for (var i = 0; i < x.length; i++) {
      x[i] = (rnd.nextDouble() - 0.5) * 0.02;
    }
    for (var t = phase; t < 20; t += 60 / bpm) {
      final s = (t * fs).round();
      for (var k = 0; k < 400 && s + k < x.length; k++) {
        x[s + k] += math.exp(-k / 60) * math.sin(k * 0.9) * 0.8;
      }
    }
    final known = analyzeBeats((x, fs, bpm))!;
    expect((known.phase - phase).abs(), lessThan(0.02));
    final est = analyzeBeats((x, fs, 0))!;
    expect((est.bpm - bpm).abs(), lessThan(1.5));
    final d = ((est.phase - phase) / est.period);
    expect((d - d.roundToDouble()).abs() * est.period, lessThan(0.03));
  });
}
