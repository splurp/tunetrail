import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

void main() {
  // A big catalogue where genre correction has left a single song filed
  // under Top Hits (genre 0) — it used to take Top Hits' whole spawn share.
  SongPool pool() {
    final songs = <SongInfo>[];
    var id = 1;
    for (final g in [132, 116, 152, 165, 85, 84]) {
      for (var a = 0; a < 60; a++) {
        for (var k = 0; k < 5; k++) {
          songs.add(SongInfo(id: id++, title: 's$id', artistId: g * 1000 + a, artistName: 'a$a', genreId: g, rank: (id * 7919) % 900000));
        }
      }
    }
    songs.add(const SongInfo(id: 999999, title: 'Leftover chart song', artistId: 1, artistName: 'x', genreId: 0, rank: 500000));
    return SongPool(songs);
  }

  test('a genre left with one song does not flood spawns', () {
    final spawner = WorldSpawner(pool(), seed: 42);
    var leftover = 0, total = 0;
    for (var slot = 0; slot < 4000; slot++) {
      final s = spawner.spawnAt(10, 20, 100, slot, 0, 0, 0, expiresAt: 0);
      if (s == null) continue;
      total++;
      if (s.song.id == 999999) leftover++;
    }
    // Before the fix this was about 1 spawn in 10.
    expect(leftover / total, lessThan(0.01));
  });

  test('Top Hits draws from the most popular songs', () {
    final p = pool();
    expect(p.genreSize(0), greaterThan(kTopHitsSongs ~/ 2));
  });
}
