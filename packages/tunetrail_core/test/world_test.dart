import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

void main() {
  final songs = [
    for (var a = 0; a < 40; a++)
      for (var k = 0; k < 10; k++)
        SongInfo(id: a * 100 + k, title: 'S$a-$k', artistId: a, artistName: 'A$a', genreId: kWorldGenres[1 + a % 8].id, rank: 100000 + a * 20000 + k * 5000),
  ];
  final pool = SongPool(songs, fansOf: (a) => a * 50000);

  test('rarities span common to legendary', () {
    expect(pool.rarities.values.toSet().length, greaterThanOrEqualTo(4));
  });

  test('spawns are deterministic and can be looked up by id', () {
    final w = WorldSpawner(pool, seed: 42);
    final now = DateTime.utc(2026, 11, 9, 12).millisecondsSinceEpoch;
    final a = w.around(40.758, -73.985, nowMs: now);
    final b = w.around(40.758, -73.985, nowMs: now);
    expect(a.map((s) => s.id).toList(), b.map((s) => s.id).toList());
    expect(a.map((s) => s.song.id).toList(), b.map((s) => s.song.id).toList());
    expect(a, isNotEmpty);
    final one = a.first;
    final again = w.byId(one.id)!;
    expect(again.song.id, one.song.id);
    expect(again.lat, one.lat);
    expect(w.byId('1:2:3:9'), isNull);
    // A different secret seed gives a different world.
    final other = WorldSpawner(pool, seed: 43).around(40.758, -73.985, nowMs: now);
    expect(other.map((s) => s.song.id).toList(), isNot(a.map((s) => s.song.id).toList()));
  });

  test('favourites turn up more often without moving other spawns', () {
    final w = WorldSpawner(pool, seed: 7);
    final now = DateTime.utc(2026, 11, 9).millisecondsSinceEpoch;
    var plain = 0, boosted = 0;
    for (var t = 0; t < 40; t++) {
      final ms = now + t * WorldSpawner.window.inMilliseconds;
      plain += w.around(10, 10, nowMs: ms).where((s) => s.song.artistId == 3).length;
      final withFav = w.around(10, 10, nowMs: ms, favorites: {3});
      boosted += withFav.where((s) => s.song.artistId == 3).length;
      // Positions are the same either way.
      expect(withFav.map((s) => s.id).toList(), w.around(10, 10, nowMs: ms).map((s) => s.id).toList());
    }
    expect(boosted, greaterThan(plain * 3));
  });

  test('distance', () {
    expect(distanceMeters(0, 0, 0, 1), closeTo(111195, 50));
  });
}
