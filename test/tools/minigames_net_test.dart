// Dev check (skipped unless TT_NET=1): album puzzles and trivia from Deezer.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/deezer_api.dart';
import 'package:tunetrail/game/minigames.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

void main() {
  test('album puzzles and trivia', () async {
    final data = MinigameData.parse(File('assets/minigames/artists.json').readAsStringSync());
    final api = DeezerApi();
    final r = math.Random(3);
    for (var i = 0; i < 3; i++) {
      final p = await pickAlbumPuzzle(api, data, MinigameFilter(), r);
      // ignore: avoid_print
      print('album: ${p?.album.title} — ${p?.artist.name} (${p?.album.fans} fans)');
      expect(p, isNotNull);
    }
    final qs = await buildTrivia(api, data, const [FavoriteArtist(id: 230, name: 'Kanye West'), FavoriteArtist(id: 27, name: 'Daft Punk')], r);
    for (final q in qs) {
      // ignore: avoid_print
      print('${q.prompt}\n   ${q.options.join(' | ')}   [answer: ${q.options[q.answer]}]');
      expect(q.options.length, 5);
      expect(q.options.toSet().length, 5);
    }
    expect(qs.length, 5);
  }, skip: Platform.environment['TT_NET'] != '1', timeout: const Timeout(Duration(minutes: 3)));
}
