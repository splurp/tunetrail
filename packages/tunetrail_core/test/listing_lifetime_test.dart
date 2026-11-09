import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

class _Clock extends MarketEngine {
  int t = 1000000;
  @override
  int now() => t;
}

CardPayload _card(int uid) => CardPayload(
    uid: uid, songId: uid, title: 'S$uid', artistId: 1, artistName: 'A', albumId: 1, albumTitle: 'B', coverMd5: '', rarity: Rarity.common, shiny: false);

void main() {
  test('listings expire after 7 days and return to the seller', () {
    final m = _Clock()..register('s', 's');
    m.createListing('s', [ListingItem(card: _card(1), price: 10)]);
    m.t += const Duration(days: 6).inMilliseconds;
    expect(m.browse(const ListingQuery()), hasLength(1));
    m.t += const Duration(days: 1).inMilliseconds;
    expect(m.browse(const ListingQuery()), isEmpty);
    expect(m.claimInbox('s').single.cards.single.uid, 1);
  });

  test('bumping moves a listing to the top, with a cooldown', () {
    final m = _Clock()..register('s', 's');
    final a = m.createListing('s', [ListingItem(card: _card(1), price: 10)]);
    m.t += 1000;
    m.createListing('s', [ListingItem(card: _card(2), price: 10)]);
    expect(() => m.bumpListing('s', a.id), throwsA(isA<MarketException>()));
    m.t += Listing.bumpCooldown.inMilliseconds;
    m.bumpListing('s', a.id);
    expect(m.browse(const ListingQuery()).first.id, a.id);
    expect(() => m.bumpListing('x', a.id), throwsA(isA<MarketException>()));
  });
}
