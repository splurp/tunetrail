import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

class _Clock extends MarketEngine {
  int t = 1000000;
  @override
  int now() => t;
}

CardPayload _card(int uid) => CardPayload(
    uid: uid, songId: uid, title: 'S$uid', artistId: 1, artistName: 'A', albumId: 1, albumTitle: 'B', coverMd5: '', rarity: Rarity.rare, shiny: false);

void main() {
  late _Clock m;
  setUp(() {
    m = _Clock()
      ..register('s', 'seller')
      ..register('a', 'alice')
      ..register('b', 'bob');
  });

  test('bids, refunds when outbid, and the winner gets the songs', () {
    final au = m.createAuction('s', [_card(1)], startPrice: 500, duration: const Duration(hours: 1));
    expect(() => m.bid('a', au.id, 400), throwsA(isA<MarketException>()));
    m.bid('a', au.id, 500);
    expect(() => m.bid('b', au.id, 550), throwsA(isA<MarketException>())); // under +100
    m.bid('b', au.id, 1000);
    expect(m.claimInbox('a').single.coins, 500); // alice refunded
    m.t += const Duration(hours: 1).inMilliseconds;
    expect(m.claimInbox('b').single.cards.single.uid, 1);
    expect(m.claimInbox('s').single.coins, 1000);
    expect(m.auctions, isEmpty);
  });

  test('late bids extend the auction by 30 seconds', () {
    final au = m.createAuction('s', [_card(1)], startPrice: 100, duration: const Duration(hours: 1));
    m.t = au.endsAt - 60000; // one minute left
    final end = au.endsAt;
    m.bid('a', au.id, 100);
    expect(au.endsAt, end + 30000);
  });

  test('buy it now ends the auction and refunds the high bidder', () {
    final au = m.createAuction('s', [_card(1)], startPrice: 100, buyNow: 2000);
    m.bid('a', au.id, 300);
    expect(m.buyAuctionNow('b', au.id, expectedPrice: 2000).single.uid, 1);
    expect(m.claimInbox('a').single.coins, 300);
    expect(m.claimInbox('s').single.coins, 2000);
  });

  test('no bids returns the songs; cancel only without bids', () {
    final au = m.createAuction('s', [_card(1)], startPrice: 100, duration: const Duration(hours: 3));
    final au2 = m.createAuction('s', [_card(2)], startPrice: 100);
    m.bid('a', au2.id, 100);
    expect(() => m.cancelAuction('s', au2.id), throwsA(isA<MarketException>()));
    m.t += const Duration(hours: 3).inMilliseconds;
    expect(m.claimInbox('s').single.cards.single.uid, 1);
  });

  test('reports and blocked songs', () {
    m.fileReport('a', ReportKind.song, '7', 'Song 7', 'Explicit sexual content', 'video');
    expect(() => m.fileReport('a', ReportKind.song, '7', 'Song 7', 'Explicit sexual content', ''), throwsA(isA<MarketException>()));
    expect(() => m.fileReport('a', ReportKind.player, 'a', 'me', 'Cheating', ''), throwsA(isA<MarketException>()));
    m.fileReport('a', ReportKind.player, 'b', 'bob', 'Harassment', 'slurs in DMs');
    m.setSongBlocked(7, true);
    expect(m.reports.where((r) => !r.resolved).single.kind, ReportKind.player);
    expect(() => m.createAuction('s', [_card(7)], startPrice: 100), throwsA(isA<MarketException>()));
    final copy = MarketEngine()..loadJson(m.toJson());
    expect(copy.blockedSongs, {7});
    expect(copy.reports, hasLength(2));
  });
}
