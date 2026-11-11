import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunetrail/data/models.dart';
import 'package:tunetrail/ui/widgets/cards.dart';
import 'package:tunetrail_core/tunetrail_core.dart' show Rarity;

Song _song(String title) =>
    Song(id: 1, title: title, artistId: 2, artistName: 'Kanye West', albumId: 3, albumTitle: 'My Beautiful Dark Twisted Fantasy', coverMd5: '', artistPicMd5: '');

void main() {
  testWidgets('regular and Canvas cards are the same size, short or long titles', (t) async {
    final keys = [GlobalKey(), GlobalKey()];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SongCardView(key: keys[0], song: _song('Runaway'), rarity: Rarity.legendary, shiny: true, width: 237, live: false),
            SongCardView(key: keys[1], song: _song('A very long song title that wraps onto two lines'), rarity: Rarity.legendary, shiny: false, width: 237, live: false),
          ]),
        ),
      ),
    ));
    final sizes = [for (final k in keys) t.getSize(find.byKey(k))];
    // A Canvas / Live / Sample card is always width × kCardAspect.
    expect(sizes[0], const Size(237, 237 * kCardAspect));
    expect(sizes[1], const Size(237, 237 * kCardAspect));
    expect(t.takeException(), isNull); // nothing overflows
  });
}
