// Dev check (skipped unless TT_NET=1): live kworb lookups.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/kworb.dart';

void main() {
  test('kworb live', () async {
    final s = SpotifyStats.instance;
    final top = await s.topSongs('Travis Scott');
    // ignore: avoid_print
    print('Travis: ${top.take(3).map((x) => x.title).join(', ')} · ${await s.monthlyListeners('Travis Scott')} listeners');
    expect(top.first.title.toLowerCase(), 'goosebumps');
    final small = await s.topSongs('Labi Siffre');
    // ignore: avoid_print
    print('Labi Siffre (via MusicBrainz): ${small.take(3).map((x) => x.title).join(', ')}');
  }, skip: Platform.environment['TT_NET'] != '1');
}
