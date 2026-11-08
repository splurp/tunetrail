// Dev helper (skipped unless TT_NET=1): checks the iTunes movie lookup.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/models.dart';
import 'package:tunetrail/game/movie_service.dart';

void main() {
  test('finds a music video', () async {
    final m = MovieService(Directory.systemTemp.createTempSync('mv'));
    const s = Song(id: 630827242, title: 'Stronger', artistId: 230, artistName: 'Kanye West', albumId: 1, albumTitle: '', coverMd5: '');
    final clip = await m.clipFor(s);
    expect(clip, isNotNull);
    expect(clip!.videoUrl, contains('.m4v'));
  }, skip: Platform.environment['TT_NET'] != '1');
}
