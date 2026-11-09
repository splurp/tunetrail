// Dev check (skipped unless TT_NET=1): Live-edition footage lookup.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/models.dart';
import 'package:tunetrail/game/movie_service.dart';

void main() {
  test('finds live footage', () async {
    final m = MovieService(Directory.systemTemp.createTempSync('mv'));
    for (final (artist, title) in [('Coldplay', 'Yellow'), ('Ed Sheeran', 'The A Team'), ('Bad Bunny', 'Tití Me Preguntó'), ('Metallica', 'Nothing Else Matters'), ('Travis Scott', 'goosebumps')]) {
      final s = Song(id: title.hashCode.abs(), title: title, artistId: 1, artistName: artist, albumId: 1, albumTitle: '', coverMd5: '');
      final c = await m.liveClipFor(s);
      // ignore: avoid_print
      print('$artist – $title: ${c == null ? 'none' : c.videoUrl.split('/').last}');
    }
  }, skip: Platform.environment['TT_NET'] != '1');
}
