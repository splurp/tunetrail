import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

CardPayload card(int uid, {Rarity r = Rarity.rare, bool shiny = false}) =>
    CardPayload(
      uid: uid,
      songId: 1000 + uid,
      title: 'Song $uid',
      artistId: 1,
      artistName: 'Artist',
      albumId: 2,
      albumTitle: 'Album',
      coverMd5: '',
      rarity: r,
      shiny: shiny,
    );

void main() {
  late MarketEngine m;
  setUp(() {
    m = MarketEngine(seed: 1);
    m.register('a', 'Alice');
    m.register('b', 'Bob');
  });

  test('listing, buying credits seller inbox', () {
    final l = m.createListing('a', card(1), 120);
    expect(m.browse(const ListingQuery()).length, 1);
    final got = m.buyListing('b', l.id, expectedPrice: 120);
    expect(got.uid, 1);
    expect(m.listings, isEmpty);
    final inbox = m.claimInbox('a');
    expect(inbox.single.coins, 120);
    expect(m.claimInbox('a'), isEmpty);
  });

  test('cannot buy own listing', () {
    final l = m.createListing('a', card(1), 10);
    expect(() => m.buyListing('a', l.id), throwsA(isA<MarketException>()));
  });

  test('trade accept swaps cards and returns competing offers', () {
    m.register('c', 'Cara');
    final l = m.createListing('a', card(1, r: Rarity.epic), 500, acceptsTrades: true);
    final o1 = m.createOffer('b', l.id, [card(2)], 50);
    m.createOffer('c', l.id, [card(3)], 0);
    m.acceptOffer('a', o1.id);
    final a = m.claimInbox('a');
    expect(a.single.cards.single.uid, 2);
    expect(a.single.coins, 50);
    expect(m.claimInbox('b').single.cards.single.uid, 1);
    // Cara's escrowed card comes back.
    expect(m.claimInbox('c').single.cards.single.uid, 3);
    expect(m.offers, isEmpty);
  });

  test('browse filters and sorts', () {
    m.createListing('a', card(1, r: Rarity.common), 5);
    m.createListing('a', card(2, r: Rarity.legendary, shiny: true), 9000);
    m.createListing('a', card(3, r: Rarity.rare), 100);
    final cheap = m.browse(const ListingQuery(sort: ListingSort.priceLow));
    expect(cheap.map((l) => l.price), [5, 100, 9000]);
    expect(m.browse(const ListingQuery(shinyOnly: true)).single.card.uid, 2);
    expect(m.browse(const ListingQuery(rarities: {2})).single.card.uid, 3);
    expect(m.browse(const ListingQuery(excludeSellerId: 'a')), isEmpty);
  });

  test('json round trip', () {
    final l = m.createListing('a', card(1), 120, acceptsTrades: true);
    m.createOffer('b', l.id, [card(2)], 0);
    m.setShowcase('a', 'Mine', [card(5)], []);
    final copy = MarketEngine()..loadJson(m.toJson());
    expect(copy.listings.length, 1);
    expect(copy.offers.length, 1);
    expect(copy.showcases['a']!.cards.single.uid, 5);
  });

  test('rng is deterministic', () {
    final a = Rng(42), b = Rng(42);
    for (var i = 0; i < 100; i++) {
      expect(a.nextInt(1000), b.nextInt(1000));
    }
    final counts = List.filled(5, 0);
    final r = Rng(7);
    for (var i = 0; i < 100000; i++) {
      counts[r.rollRarity().index]++;
    }
    expect(counts[0], greaterThan(counts[1]));
    expect(counts[3], greaterThan(counts[4]));
    expect(counts[4], greaterThan(1000));
  });
}
