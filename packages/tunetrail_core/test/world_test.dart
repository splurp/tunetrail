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

  List<WorldSpawn> around(WorldSpawner w, double lat, double lng, int d, {Set<int> favorites = const {}, CellGround? ground, Map<String, int> gens = const {}}) => [
        for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng))
          for (final (k, la, ln) in w.spots(cx, cy, d, ground ?? CellGround.allLand()))
            ?w.spawnAt(cx, cy, d, k, gens[WorldSpawner.slotKey(cx, cy, d, k)] ?? 0, la, ln, expiresAt: 0, favorites: favorites),
      ];

  test('spawns are deterministic for a day and differ by seed', () {
    final w = WorldSpawner(pool, seed: 42);
    final a = around(w, 40.758, -73.985, 20000);
    final b = around(w, 40.758, -73.985, 20000);
    expect(a, isNotEmpty);
    expect(a.map((s) => s.id).toList(), b.map((s) => s.id).toList());
    expect(a.map((s) => s.song.id).toList(), b.map((s) => s.song.id).toList());
    // The next day shuffles them.
    expect(around(w, 40.758, -73.985, 20001).map((s) => s.lat).toList(), isNot(a.map((s) => s.lat).toList()));
    final other = around(WorldSpawner(pool, seed: 43), 40.758, -73.985, 20000);
    expect(other.map((s) => s.song.id).toList(), isNot(a.map((s) => s.song.id).toList()));
  });

  test('a caught spot gets a new song in the same place', () {
    final w = WorldSpawner(pool, seed: 5);
    final (cx, cy) = WorldSpawner.cellOf(40.758, -73.985);
    final spots = w.spots(cx, cy, 100, CellGround(List.filled(64, CellGround.built)));
    expect(spots, isNotEmpty);
    final (k, lat, lng) = spots.first;
    final first = w.spawnAt(cx, cy, 100, k, 0, lat, lng, expiresAt: 0)!;
    final next = w.spawnAt(cx, cy, 100, k, 1, lat, lng, expiresAt: 0)!;
    expect(next.lat, first.lat);
    expect(next.id, isNot(first.id));
  });

  test('never on water; more spots where it is built up', () {
    final w = WorldSpawner(pool, seed: 9);
    // West half water, east half land.
    final half = CellGround([for (var i = 0; i < 64; i++) i % 8 < 4 ? CellGround.water : CellGround.land]);
    expect(CellGround.parse(half.encode())!.squares, half.squares);
    var rural = 0, urban = 0;
    for (var c = 0; c < 400; c++) {
      for (final (_, _, lng) in w.spots(c, 7, 3, half)) {
        rural++;
        final x = lng / WorldSpawner.lngDegForRow(7) - c;
        expect(x, greaterThan(0.5)); // east (land) half only
      }
      urban += w.spots(c, 7, 3, CellGround(List.filled(64, CellGround.built))).length;
      expect(w.spots(c, 7, 3, CellGround(List.filled(64, CellGround.water))), isEmpty);
    }
    expect(urban, greaterThan(rural * 4));
  });

  test('favourites turn up more often without moving other spawns', () {
    final w = WorldSpawner(pool, seed: 7);
    var plain = 0, boosted = 0;
    for (var d = 0; d < 40; d++) {
      plain += around(w, 10, 10, d).where((s) => s.song.artistId == 3).length;
      final withFav = around(w, 10, 10, d, favorites: {3});
      boosted += withFav.where((s) => s.song.artistId == 3).length;
      expect(withFav.map((s) => s.id).toList(), around(w, 10, 10, d).map((s) => s.id).toList());
    }
    expect(boosted, greaterThan(plain * 3));
  });

  test('distance', () {
    expect(distanceMeters(0, 0, 0, 1), closeTo(111195, 50));
  });
}
