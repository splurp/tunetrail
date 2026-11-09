import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

CardPayload card(int uid, {Rarity r = Rarity.rare, bool shiny = false, int genre = 132}) => CardPayload(
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
      genreId: genre,
    );

ListingItem item(int uid, int price, {Rarity r = Rarity.rare, bool shiny = false, int genre = 132}) =>
    ListingItem(card: card(uid, r: r, shiny: shiny, genre: genre), price: price);

void main() {
  late MarketEngine m;
  setUp(() {
    m = MarketEngine(seed: 1);
    m.register('a', 'Alice');
    m.register('b', 'Bob');
  });

  test('single listing: buy credits seller inbox', () {
    final l = m.createListing('a', [item(1, 120)]);
    expect(m.browse(const ListingQuery()).length, 1);
    final got = m.buyListing('b', l.id, expectedPrice: 120);
    expect(got.single.uid, 1);
    expect(m.listings, isEmpty);
    expect(m.claimInbox('a').single.coins, 120);
    expect(m.claimInbox('a'), isEmpty);
  });

  test('folder: auto price, manual discount, buy whole folder', () {
    final auto = m.createListing('a', [item(1, 100), item(2, 50), item(3, 25)]);
    expect(auto.folderPrice, 175);
    final disc = m.createListing('a', [item(4, 100), item(5, 100)], folderPrice: 150, note: 'bundle deal');
    expect(disc.folderPrice, 150);
    expect(disc.discount, 50);
    expect(() => m.createListing('a', [item(6, 10)], folderPrice: 20), throwsA(isA<MarketException>()));
    final got = m.buyListing('b', disc.id, expectedPrice: 150);
    expect(got.map((c) => c.uid), [4, 5]);
    expect(m.claimInbox('a').single.coins, 150);
  });

  test('folder: buy single item, manual price scales, last item removes listing', () {
    final l = m.createListing('a', [item(1, 100), item(2, 100)], folderPrice: 160);
    final c = m.buyItem('b', l.id, 1, expectedPrice: 100);
    expect(c.uid, 1);
    expect(m.listings[l.id]!.items.length, 1);
    expect(m.listings[l.id]!.folderPrice, 100); // single item: own price
    m.buyItem('b', l.id, 2);
    expect(m.listings, isEmpty);
    expect(m.claimInbox('a').fold<int>(0, (a, i) => a + i.coins), 200);
  });

  test('limits: 20 songs, 200-char note, duplicates', () {
    expect(() => m.createListing('a', [for (var i = 0; i < 21; i++) item(i, 1)]), throwsA(isA<MarketException>()));
    expect(() => m.createListing('a', [item(1, 1)], note: 'x' * 201), throwsA(isA<MarketException>()));
    expect(() => m.createListing('a', [item(1, 1), item(1, 2)]), throwsA(isA<MarketException>()));
    m.createListing('a', [item(1, 1)]);
    expect(() => m.createListing('a', [item(1, 5)]), throwsA(isA<MarketException>()));
  });

  test('cannot buy own listing', () {
    final l = m.createListing('a', [item(1, 10)]);
    expect(() => m.buyListing('a', l.id), throwsA(isA<MarketException>()));
    expect(() => m.buyItem('a', l.id, 1), throwsA(isA<MarketException>()));
  });

  test('trade for whole folder; competing offers returned; item sale voids offers', () {
    m.register('c', 'Cara');
    final l = m.createListing('a', [item(1, 500, r: Rarity.epic), item(9, 50)], acceptsTrades: true);
    final o1 = m.createOffer('b', l.id, [card(2)], 50, note: 'pls');
    m.createOffer('c', l.id, [card(3)], 0);
    m.acceptOffer('a', o1.id);
    final a = m.claimInbox('a');
    expect(a.single.cards.single.uid, 2);
    expect(a.single.coins, 50);
    expect(m.claimInbox('b').single.cards.map((c) => c.uid), [1, 9]);
    expect(m.claimInbox('c').single.cards.single.uid, 3);
    expect(m.offers, isEmpty);

    final l2 = m.createListing('a', [item(20, 10), item(21, 10)], acceptsTrades: true);
    m.createOffer('b', l2.id, [card(22)], 0);
    m.buyItem('c', l2.id, 20);
    expect(m.offers, isEmpty);
    expect(m.claimInbox('b').single.cards.single.uid, 22);
  });

  test('browse filters match any song in a folder and sorts by folder price', () {
    m.createListing('a', [item(1, 5, r: Rarity.common)]);
    m.createListing('a', [item(2, 9000, r: Rarity.legendary, shiny: true, genre: 116), item(3, 1, r: Rarity.common)]);
    m.createListing('a', [item(4, 100, r: Rarity.rare)], note: 'cheap rare');
    expect(m.browse(const ListingQuery(sort: ListingSort.priceLow)).map((l) => l.folderPrice), [5, 100, 9001]);
    expect(m.browse(const ListingQuery(shinyOnly: true)).single.items.length, 2);
    expect(m.browse(const ListingQuery(genres: {116})).length, 1);
    expect(m.browse(const ListingQuery(rarities: {2})).single.card.uid, 4);
    expect(m.browse(const ListingQuery(text: 'cheap')).single.card.uid, 4);
    expect(m.browse(const ListingQuery(excludeSellerId: 'a')), isEmpty);
    expect(m.browse(const ListingQuery(sort: ListingSort.rarity)).first.items.length, 2);
  });

  test('withdraw item returns it', () {
    final l = m.createListing('a', [item(1, 10), item(2, 10)]);
    expect(m.withdrawItem('a', l.id, 1).uid, 1);
    expect(m.listings[l.id]!.items.single.card.uid, 2);
  });

  test('json round trip incl. legacy single-card listings', () {
    final l = m.createListing('a', [item(1, 120), item(2, 30)], folderPrice: 140, note: 'hi', acceptsTrades: true);
    m.createOffer('b', l.id, [card(5)], 0);
    m.setShowcase('a', 'Mine', [card(5)], []);
    final copy = MarketEngine()..loadJson(m.toJson());
    expect(copy.listings.values.single.folderPrice, 140);
    expect(copy.listings.values.single.note, 'hi');
    expect(copy.offers.values.single.requestedCards.length, 2);
    final legacy = Listing.fromJson({'id': 'x', 'sellerId': 'a', 'card': card(7).toJson(), 'price': 33});
    expect(legacy.items.single.price, 33);
  });

  test('scrap value grows with streams and rarity', () {
    // Half the map purchase price (just out of range); shinies ×10.
    expect(scrapValue(Rarity.common, false, 0), 25);
    expect(scrapValue(Rarity.legendary, false, 0), 400);
    expect(scrapValue(Rarity.rare, true, 500000), scrapValue(Rarity.rare, false, 500000) * 10);
    expect(scrapValue(Rarity.epic, false, 0, edition: Edition.canvas), 3000);
  });

  test('rng is deterministic', () {
    final a = Rng(42), b = Rng(42);
    for (var i = 0; i < 100; i++) {
      expect(a.nextInt(1000), b.nextInt(1000));
    }
  });
}
