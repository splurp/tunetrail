import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/kworb.dart';

void main() {
  test('parses kworb song and listener pages', () {
    final songs = SpotifyStats.parseSongs(File('test/fixtures/kworb_songs.html').readAsStringSync());
    expect(songs.first.title, 'goosebumps');
    expect(songs.first.streams, greaterThan(1000000000));
    expect(songs.where((s) => s.featured), isNotEmpty);
    final l = SpotifyStats.parseListeners(File('test/fixtures/kworb_listeners.html').readAsStringSync());
    expect(l['theweeknd']!.$2, greaterThan(10000000));
    expect(l['brunomars']!.$1, '0du5cEVh5yTK9QJze8zA0C');
  });
}
