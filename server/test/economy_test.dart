import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tunetrail_core/tunetrail_core.dart';
import 'package:tunetrail_server/auth.dart';
import 'package:tunetrail_server/catalog.dart';
import 'package:tunetrail_server/economy.dart';
import 'package:tunetrail_server/store.dart';

import '../bin/server.dart' show buildRouter;

/// A catalogue of [n] made-up songs over a few artists and genres.
ServerCatalog fakeCatalog(Directory dir, {int n = 600}) {
  final c = ServerCatalog(FileStore('${dir.path}/m.json'));
  final genres = [132, 116, 152, 165, 85, 84];
  for (var i = 1; i <= n; i++) {
    final artist = 1000 + i % 40;
    c.songs[i] = SongInfo(id: i, title: 'Song $i', artistId: artist, artistName: 'Artist $artist', genreId: genres[i % genres.length], rank: (i * 7919) % 1000000);
    c.fans[artist] = 10000 * (artist - 990);
  }
  return c;
}

/// Ground maps of the cells around a point: all built up.
Map<String, String> built(double lat, double lng) => {
      for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng)) '$cx:$cy': CellGround(List.filled(64, CellGround.built)).encode(),
    };

void main() {
  late Directory dir;
  late MarketEngine engine;
  late Economy econ;
  var clock = 1800000000000;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('econ');
    engine = MarketEngine(seed: 1);
    econ = Economy(engine: engine, catalog: fakeCatalog(dir), seed: 42, clock: () => clock, random: math.Random(7))..attach();
    engine.register('p1', 'One');
    engine.register('p2', 'Two');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CardPayload card(int uid, int song, {Rarity r = Rarity.common, bool shiny = false}) =>
      CardPayload(uid: uid, songId: song, title: 'Song $song', artistId: 1, artistName: 'A', albumId: 0, albumTitle: '', coverMd5: '', rarity: r, shiny: shiny);

  test('import happens once and moves balances, items and cards', () {
    final a = econ.import('p1', {
      'coins': 900,
      'bits': 40,
      'xp': 12,
      'owned': ['pet_cat', 'not_an_item'],
      'claimed': ['m_size_10', 'd_catch'],
      'cards': [card(5, 1).toJson(), card(6, 2).toJson()],
    });
    expect(a.coins, 900);
    expect(a.owned, {'pet_cat'});
    expect(a.questsClaimed, {'m_size_10'});
    expect(a.cards.length, 2);
    expect(engine.collections['p1']!.length, 2);
    expect(() => econ.import('p1', {}), throwsA(isA<MarketException>()));
    expect(econ.sync(a, null)['full'], true);
    expect(econ.sync(a, a.rev).containsKey('full'), false);
  });

  test('economy requests need an imported account', () {
    expect(() => econ.openPack('p1', 'pack_gold'), throwsA(isA<MarketException>()));
  });

  group('spawns', () {
    setUp(() => econ.import('p1', {'coins': 5000}));

    test('the server issues spawns, and only nearby ones can be caught', () async {
      final list = econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      expect(list, isNotEmpty);
      final s = WorldSpawn.fromJson(list.first);
      // From 2 km away: refused (and flagged).
      await expectLater(econ.throwAt('p1', s.id, s.lat + 0.018, s.lng, 100), throwsA(isA<MarketException>()));
      // Standing on it: a perfect beat always catches, and it's shiny.
      clock += 600000;
      final r = await econ.throwAt('p1', s.id, s.lat, s.lng, 100);
      expect(r.result, 'caught');
      expect(r.card!.shiny || r.card!.edition != Edition.standard, true);
      // It's gone now.
      await expectLater(econ.throwAt('p1', s.id, s.lat, s.lng, 100), throwsA(isA<MarketException>()));
      expect(econ.spawnsAround('p1', s.lat, s.lng, grounds: built(s.lat, s.lng)).any((x) => x['id'] == s.id), false);
    });

    test('a bought spawn always gets caught, from where you stand', () async {
      final list = econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      final here = (40.7812, -73.9665);
      final far = list.map(WorldSpawn.fromJson).firstWhere((s) {
        final d = distanceMeters(here.$1, here.$2, s.lat, s.lng);
        return d > 120 && d < 450 && !s.shiny && s.edition == Edition.standard;
      });
      final before = econ.account('p1').coins;
      final price = econ.buySpawn('p1', far.id, here.$1, here.$2);
      expect(price, greaterThan(0));
      expect(econ.account('p1').coins, before - price);
      final r = await econ.throwAt('p1', far.id, here.$1, here.$2, 0);
      expect(r.result, 'caught');
    });

    test('a spawn gets away after five misses at most', () async {
      final s = WorldSpawn.fromJson(econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665)).first);
      var result = '';
      for (var i = 0; i < 5 && result != 'fled' && result != 'caught'; i++) {
        result = (await econ.throwAt('p1', s.id, s.lat, s.lng, 0)).result;
      }
      expect(['fled', 'caught'], contains(result));
    });

    test('no spawns until the game sends the ground; never on water', () {
      expect(econ.spawnsAround('p1', 40.7812, -73.9665), isEmpty);
      final water = {for (final k in built(40.7812, -73.9665).keys) k: CellGround(List.filled(64, CellGround.water)).encode()};
      expect(econ.spawnsAround('p1', 40.7812, -73.9665, grounds: water), isEmpty);
      // The day's first ground map sticks: sending land later changes nothing.
      expect(econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665)), isEmpty);
    });

    test('spawns stay all day; a caught spot gets a new song an hour later', () async {
      final first = econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      clock += 2 * 3600000;
      final later = econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      expect(later.map((x) => x['id']).toSet(), first.map((x) => x['id']).toSet());
      final s = WorldSpawn.fromJson(first.first);
      expect((await econ.throwAt('p1', s.id, s.lat, s.lng, 100)).result, 'caught');
      final gone = econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      expect(gone.any((x) => x['lat'] == s.lat && x['lng'] == s.lng), false);
      clock += 3600000 + 1000;
      final back = econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      final again = back.map(WorldSpawn.fromJson).where((x) => x.lat == s.lat && x.lng == s.lng).single;
      expect(again.id, isNot(s.id));
      // Catchable from 100 m.
      final away = again.lat + 95 / 111132.0;
      expect((await econ.throwAt('p1', again.id, away, again.lng, 100)).result, 'caught');
    });

    test('caught editions show up in recent pulls', () async {
      econ.admins.add('p1');
      final song = econ.catalog.songs.values.first;
      final s = WorldSpawn.fromJson(econ.debugSpawn('p1', song, 40.78, -73.96, edition: Edition.canvas));
      expect((await econ.throwAt('p1', s.id, s.lat, s.lng, 50)).result, 'caught');
      final pulls = engine.recentPullsOf(Edition.canvas);
      expect(pulls.single['sn'], 1);
      expect(pulls.single['by'], 'One');
      expect((pulls.single['song'] as Map)['id'], song.id);
      expect(engine.recentPullsOf(Edition.live), isEmpty);
      // Kept with the market state.
      final copy = MarketEngine()..loadJson(engine.toJson());
      expect(copy.recentPullsOf(Edition.canvas).length, 1);
    });

    test('teleporting across the city is flagged', () {
      econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      clock += 10000;
      econ.spawnsAround('p1', 51.5, -0.12, grounds: built(51.5, -0.12));
      expect(econ.account('p1').flags.map((f) => f.kind), contains('impossible_travel'));
      expect(econ.flagged().single['id'], 'p1');
      econ.clearFlags('p1');
      expect(econ.flagged(), isEmpty);
    });

    test('walking counts towards distance', () {
      econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      clock += 60000;
      econ.spawnsAround('p1', 40.7832, -73.9665, grounds: built(40.7832, -73.9665)); // ~220 m in a minute
      expect(econ.account('p1').stats['meters'], closeTo(222, 5));
    });
  });

  test('packs cost bits and give the right number of cards', () {
    econ.import('p1', {'bits': 150});
    final pulls = econ.openPack('p1', 'pack_gold');
    expect(pulls.length, 10);
    expect(pulls.every((p) => p.$1.rarity.index >= Rarity.rare.index), true);
    final a = econ.account('p1');
    expect(a.bits, 50);
    expect(a.cards.length + pulls.where((p) => p.$2 == null).length, 10);
    expect(() => econ.openPack('p1', 'pack_gold'), throwsA(isA<MarketException>()));
  });

  test('shop: bits items, grants and bundles', () {
    econ.import('p1', {'bits': 600});
    econ.buyItem('p1', 'pet_cat');
    expect(econ.account('p1').bits, 100);
    expect(() => econ.buyItem('p1', 'pet_dog'), throwsA(isA<MarketException>()));
    expect(() => econ.buyItem('p1', 'hat_cap'), throwsA(isA<MarketException>()));
    econ.grant('p1', 'bundle_hats');
    expect(econ.account('p1').owned.containsAll(shopIdsOfKind(ShopKind.hat)), true);
    econ.grant('p1', 'bits_100');
    expect(econ.account('p1').bits, 200);
  });

  test('scrapping pays coins and skips editions', () {
    econ.import('p1', {
      'cards': [card(1, 1, r: Rarity.rare).toJson(), CardPayload.fromJson({...card(2, 2).toJson(), 'ed': Edition.canvas.index, 'sn': 3}).toJson()],
    });
    final coins = econ.scrap('p1', [1, 2, 99]);
    expect(coins, scrapValue(Rarity.rare, false, 0));
    expect(econ.account('p1').cards.keys, [2]);
  });

  test('minigame rounds pay at most the round maximum, from one daily pool', () {
    econ.import('p1', {});
    expect(() => econ.awardMinigame('p1', 'song', 5), throwsA(isA<MarketException>()));
    econ.startMinigame('p1', 'song');
    expect(econ.awardMinigame('p1', 'song', 50), 5);
    expect(econ.awardMinigame('p1', 'song', 5), 0);
    // One pool for all the games: as many rounds a day as there are games.
    for (var i = 1; i < kMinigamePlaysPerDay; i++) {
      econ.startMinigame('p1', i.isEven ? 'lyric' : 'backwards');
    }
    expect(() => econ.startMinigame('p1', 'song'), throwsA(isA<MarketException>()));
    expect(econ.minigameQuota('p1', 'artist')['left'], 0);
    expect(econ.account('p1').bits, 5);
  });

  test('quests track catches on the server and pay out once', () async {
    econ.import('p1', {});
    final board = econ.questBoard('p1');
    expect((board['daily'] as List).length, 4);
    final ms = (board['milestone'] as List).firstWhere((q) => q['id'] == 'm_size_10');
    expect(ms['progress'], 0);
    await expectLater(econ.claimQuest('p1', 'm_size_10'), throwsA(isA<MarketException>()));
    econ.adminSetBalances('p1');
    econ.admins.add('p1');
    econ.adminGenerateCards('p1', 30);
    final before = econ.account('p1').coins;
    await econ.claimQuest('p1', 'm_size_10');
    expect(econ.account('p1').coins, before + 30);
    await expectLater(econ.claimQuest('p1', 'm_size_10'), throwsA(isA<MarketException>()));
  });

  group('market over HTTP', () {
    late Handler h;
    setUp(() {
      h = buildRouter(engine, Auth(secret: 'x' * 40, googleClientIds: {}, allowGuests: true), economy: econ, catalog: econ.catalog).call;
      econ.import('p1', {'coins': 0, 'cards': [card(11, 1).toJson(), card(12, 2).toJson()]});
      econ.import('p2', {'coins': 1000});
    });

    Future<(int, dynamic)> call(String method, String path, String who, [Object? body]) async {
      final res = await h(Request(method, Uri.parse('http://x$path'),
          headers: {'x-player-id': who, 'x-player-name': who, 'content-type': 'application/json'}, body: body == null ? null : jsonEncode(body)));
      return (res.statusCode, jsonDecode(await res.readAsString()));
    }

    test('listing holds the card; buying moves coins and the card', () async {
      // A card the seller doesn't own can't be listed.
      var (st, _) = await call('POST', '/listings', 'p1', {
        'items': [ListingItem(card: card(99, 9), price: 50).toJson()],
      });
      expect(st, 400);
      final res = await call('POST', '/listings', 'p1', {
        'items': [ListingItem(card: card(11, 1), price: 300).toJson()],
      });
      expect(res.$1, 200);
      expect(econ.account('p1').cards.containsKey(11), false);
      final id = res.$2['id'] as String;
      (st, _) = await call('POST', '/listings/$id/buy', 'p2', {'price': 300});
      expect(st, 200);
      expect(econ.account('p2').coins, 700);
      expect(econ.account('p1').coins, 300);
      expect(econ.account('p2').cards.values.single.songId, 1);
    });

    test('a failed purchase refunds the coins', () async {
      final res = await call('POST', '/listings', 'p1', {
        'items': [ListingItem(card: card(12, 2), price: 5000).toJson()],
      });
      final id = res.$2['id'] as String;
      final (st, _) = await call('POST', '/listings/$id/buy', 'p2', {'price': 5000});
      expect(st, 400);
      expect(econ.account('p2').coins, 1000);
      // Cancelling returns the card.
      await call('POST', '/listings/$id/cancel', 'p1');
      expect(econ.account('p1').cards.containsKey(12), true);
    });

    test('bids are held and refunded when outbid', () async {
      engine.register('p3', 'Three');
      econ.import('p3', {'coins': 1000});
      final res = await call('POST', '/auctions', 'p1', {'cards': [card(11, 1).toJson()], 'start': 100, 'hours': 1});
      final id = res.$2['id'] as String;
      await call('POST', '/auctions/$id/bid', 'p2', {'amount': 100});
      expect(econ.account('p2').coins, 900);
      await call('POST', '/auctions/$id/bid', 'p3', {'amount': 300});
      expect(econ.account('p2').coins, 1000);
      expect(econ.account('p3').coins, 700);
    });

    test('direct trades hand over the songs from the collection', () async {
      final res = await call('POST', '/players/p1/offers', 'p2', {'uids': [12], 'coins': 250});
      expect(res.$1, 200);
      expect(econ.account('p2').coins, 750);
      await call('POST', '/offers/${res.$2['id']}/accept', 'p1');
      expect(econ.account('p1').coins, 250);
      expect(econ.account('p1').cards.containsKey(12), false);
      expect(econ.account('p2').cards.values.single.songId, 2);
    });

    test('spawns and throws over HTTP carry the account', () async {
      final (st, j) = await call('POST', '/spawns', 'p2', {'lat': 40.7812, 'lng': -73.9665, 'tz': -300, 'grounds': built(40.7812, -73.9665)});
      expect(st, 200);
      expect((j['spawns'] as List), isNotEmpty);
      expect(j['acct']['coins'], 1000);
    });
  });
}
