import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

void main() {
  test('an artist with many songs in the catalogue does not crowd out the rest', () {
    final songs = [
      // One artist with 100 songs (a favourite someone added)…
      for (var i = 0; i < 100; i++) SongInfo(id: 1000 + i, title: 'Big $i', artistId: 1, artistName: 'Big', genreId: 85, rank: 500000),
      // …and 100 artists with one song each.
      for (var a = 0; a < 100; a++) SongInfo(id: 5000 + a, title: 'Small $a', artistId: 100 + a, artistName: 'Small $a', genreId: 85, rank: 500000),
    ];
    final pool = SongPool(songs);
    final rng = Rng(7);
    var big = 0;
    const n = 20000;
    for (var i = 0; i < n; i++) {
      final s = pool.pickSong(rng, genreId: 85, rarity: pool.rarityOf(1000));
      if (s != null && s.artistId == 1) big++;
    }
    // By song count it would be about half; weighted by √songs per artist
    // it's well under a fifth.
    expect(big / n, lessThan(0.2));
    expect(big, greaterThan(0));
  });
}
