import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tunetrail/data/catalog.dart';
import 'package:tunetrail/data/collection.dart';
import 'package:tunetrail/data/deezer_api.dart';
import 'package:tunetrail/data/models.dart';
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
        (1 + rng.nextInt(20000), rng.rollRarity(), rng.chance(128), CardSource.debug, now.subtract(Duration(seconds: rng.nextInt(1 << 25))))
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

  test('song json round trip and cdn urls', () {
    const s = Song(id: 5, title: 'T', artistId: 1, artistName: 'A', albumId: 2, albumTitle: 'B', coverMd5: '0123456789abcdef0123456789abcdef', genreId: 132, rank: 9);
    final r = Song.fromJson(s.toJson());
    expect(r.title, 'T');
    expect(r.genreId, 132);
    expect(s.cover(), contains('/images/cover/0123456789abcdef0123456789abcdef/250x250'));
    expect(md5FromUrl('https://cdn-images.dzcdn.net/images/artist/71eeb9e2eeb375df35a3c0654a5a01ab/56x56-000000-80-0-0.jpg'), '71eeb9e2eeb375df35a3c0654a5a01ab');
  });
}
