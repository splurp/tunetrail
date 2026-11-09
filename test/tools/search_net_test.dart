// Dev check (skipped unless TT_NET=1): originals show up in song search.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/deezer_api.dart';

void main() {
  test('search finds originals', () async {
    final api = DeezerApi();
    for (final (q, artist) in [('i write sins not tragedies', 'Panic! At The Disco'), ('somebody that i used to know', 'Gotye')]) {
      final r = await api.searchSongs(q);
      // ignore: avoid_print
      print('$q → ${r.take(3).map((s) => '${s.title} · ${s.artistName}').join(' | ')}');
      expect(r.first.artistName, artist);
    }
  }, skip: Platform.environment['TT_NET'] != '1');
}
