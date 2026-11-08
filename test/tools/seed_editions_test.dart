// Dev helper (skipped unless TT_SEED_DIR is set): seeds a local app data
// dir with Movie / Sample edition cards for screenshots.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/catalog.dart';
import 'package:tunetrail/data/collection.dart';
import 'package:tunetrail/data/deezer_api.dart';
import 'package:tunetrail/data/models.dart';
import 'package:tunetrail/data/samples.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

void main() {
  final path = Platform.environment['TT_SEED_DIR'];
  test('seed edition cards', () async {
    final dir = Directory(path!);
    final cat = Catalog(DeezerApi(), dir);
    await cat.load();
    final s = SampleLibrary.all.first;
    cat.addSongs([s.song]);
    const stronger = Song(id: 630827242, title: 'Stronger', artistId: 230, artistName: 'Kanye West', albumId: 86994002, albumTitle: 'Graduation', coverMd5: '8c6578a2099561992fb7544e6826f767', genreId: 116, rank: 649848);
    if (!cat.songs.containsKey(stronger.id)) cat.addSongs([stronger]);
    await cat.flush();
    final col = CollectionStore(cat, dir);
    await col.load();
    if (!col.ownsVariant(s.song.id, Rarity.epic, false, Edition.sample)) col.add(s.song.id, Rarity.epic, false, CardSource.debug, edition: Edition.sample);
    col.add(stronger.id, Rarity.legendary, true, CardSource.debug, edition: Edition.movie, at: DateTime.now().subtract(const Duration(seconds: 5)));
    await col.save();
  }, skip: path == null);
}
