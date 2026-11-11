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

  test('admins can restore cards from before the switch; other devices merge in', () {
    // The old game had uploaded two cards, one a numbered Canvas.
    engine.collections['p1'] = [card(41, 1), CardPayload.fromJson({...card(42, 2).toJson(), 'ed': Edition.canvas.index, 'sn': 1})];
    econ.import('p1', {}); // a fresh install imported nothing
    expect(econ.account('p1').cards, isEmpty);
    econ.import('p2', {});
    econ.admins.add('p2');
    expect(econ.adminRestoreLegacy('p2', 'p1'), 2);
    expect(econ.account('p1').cards.keys.toSet(), {41, 42});
    expect(econ.adminRestoreLegacy('p2', 'p1'), 0); // nothing twice
    // A second device's progress is added once it finds the account on the server.
    econ.merge('p1', {'coins': 300, 'cards': [card(43, 3).toJson(), card(41, 1).toJson()]});
    expect(econ.account('p1').coins, 300);
    expect(econ.account('p1').cards.length, 3);
    expect(econ.account('p1').flags.last.kind, 'device_merge');
  });

  test('admins can reset or add minigame rounds', () {
    econ.import('p1', {});
    econ.import('p2', {});
    econ.admins.add('p2');
    for (var i = 0; i < kMinigamePlaysPerDay; i++) {
      econ.startMinigame('p1', 'song');
    }
    expect(econ.minigameQuota('p1', 'song')['left'], 0);
    econ.adminMinigames('p2', 'p1');
    expect(econ.minigameQuota('p1', 'song')['left'], kMinigamePlaysPerDay);
    econ.adminMinigames('p2', 'p1', extra: 4);
    expect(econ.minigameQuota('p1', 'song')['left'], kMinigamePlaysPerDay + 4);
  });

  test('chat showcases use the server account\'s cards', () {
    econ.import('p1', {'cards': [card(5, 5).toJson()]});
    expect(engine.sendMessage('p1', 'p2', '', cardUid: 5).card!.songId, 5);
    expect(() => engine.sendMessage('p1', 'p2', '', cardUid: 6), throwsA(isA<MarketException>()));
  });

  test('admins can purge a lost numbered card, not one someone has', () {
    econ.import('p1', {});
    econ.import('p2', {});
    econ.admins.add('p2');
    expect(engine.claimSerial(5, Edition.canvas), 1);
    expect(engine.claimSerial(5, Edition.canvas), 2);
    final held = CardPayload.fromJson({...card(9, 5).toJson(), 'ed': Edition.canvas.index, 'sn': 2});
    econ.merge('p1', {'cards': [held.toJson()]});
    expect(() => econ.adminPurgeSerial('p2', 5, Edition.canvas, 2), throwsA(isA<MarketException>()));
    expect(() => econ.adminPurgeSerial('p1', 5, Edition.canvas, 1), throwsA(isA<MarketException>())); // admins only
    econ.adminPurgeSerial('p2', 5, Edition.canvas, 1);
    expect(engine.claimSerial(5, Edition.canvas), 1);
  });

  group('exploration', () {
    const lat = 40.7812, lng = -73.9665;
    Map<String, String> terrainAll(Terrain t) => {
          for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng)) '$cx:$cy': CellTerrain(List.filled(64, t)).encode(),
        };
    List<Map<String, dynamic>> glow(String id) => (econ.worldAround(id)['glow'] as List).cast<Map<String, dynamic>>();

    setUp(() {
      econ.import('p1', {});
      econ.import('p2', {});
      engine.setUsername('p1', 'One');
      engine.setUsername('p2', 'Two');
    });

    test('levels: 200 XP to level 2, 3,700 from 36 to 37, 10,000 from 99 to 100, then no further', () {
      expect(xpToNextLevel(1), 200);
      expect(xpToNextLevel(36), 3700);
      expect(xpToNextLevel(99), 10000);
      expect(levelForXp(0), 1);
      expect(levelForXp(199), 1);
      expect(levelForXp(200), 2);
      expect(levelForXp(xpForLevel(37) - 1), 36);
      expect(levelForXp(1 << 40), kMaxLevel);
      expect(catchXp(Rarity.common), 5);
      expect(catchXp(Rarity.legendary, shiny: true), 500);
      expect(catchXp(Rarity.common, edition: Edition.canvas), 1000);
      expect(catchXp(Rarity.rare, edition: Edition.live), 2000);
    });

    test('a bonus every five levels; choosing again costs bits; bonuses apply', () {
      final a = econ.account('p1');
      expect(() => econ.chooseBonus('p1', 'xp'), throwsA(isA<MarketException>()));
      a.xp = xpForLevel(10);
      econ.chooseBonus('p1', 'xp');
      econ.chooseBonus('p1', 'scrap');
      expect(() => econ.chooseBonus('p1', 'spawn'), throwsA(isA<MarketException>()));
      expect(a.bonuses.xpMultiplier, closeTo(1.05, 1e-9));
      // Minigame bits give ×5 XP, with the XP bonus on top.
      final before = a.xp;
      econ.startMinigame('p1', 'song');
      econ.awardMinigame('p1', 'song', 5);
      expect(a.xp - before, (25 * 1.05).round());
      // Scrapping pays 5% more.
      econ.merge('p1', {'cards': [card(1, 1, r: Rarity.legendary).toJson()]});
      final worth = scrapValue(a.cards[1]!.rarity, false, 0);
      expect(econ.scrap('p1', [1]), (worth * 1.05).round());
      expect(() => econ.respecBonuses('p1'), throwsA(isA<MarketException>())); // no bits
      a.bits = 150;
      econ.respecBonuses('p1');
      expect(a.bits, 50);
      expect(a.bonuses.unspent(a.level), 2);
    });

    test('a spawn-rate bonus only adds spots', () {
      final spawner = WorldSpawner(econ.catalog.pool, seed: 42);
      final ground = CellGround(List.filled(64, CellGround.built));
      for (var cx = 0; cx < 30; cx++) {
        final base = spawner.spots(cx, 7, 100, ground), more = spawner.spots(cx, 7, 100, ground, rate: 2);
        expect(more.length, greaterThanOrEqualTo(base.length));
        expect(more.take(base.length).toList(), base);
      }
    });

    test('trades give both players XP', () {
      econ.merge('p2', {'cards': [card(7, 7).toJson()]});
      econ.merge('p1', {'cards': [card(8, 8).toJson()]});
      final o = engine.createDirectOffer('p1', 'p2', [7], [econ.account('p1').cards[8]!], 0);
      engine.acceptOffer('p2', o.id);
      expect(econ.account('p1').xp, kTradeXp);
      expect(econ.account('p2').xp, kTradeXp);
    });

    /// Moves on a day at a time until at least [min] features glow
    /// around the player on ground that's all [t].
    List<Map<String, dynamic>> glowingDay(String id, Terrain t, {int min = 1}) {
      for (var i = 0; i < 400; i++) {
        econ.spawnsAround(id, lat, lng, grounds: built(lat, lng), terrains: terrainAll(t));
        final g = glow(id);
        if (g.length >= min) return g;
        clock += 24 * 3600 * 1000;
      }
      fail('nothing glowed');
    }

    CellTerrain? all(Terrain t, int cx, int cy) => CellTerrain(List.filled(64, t));

    test('features follow the terrain, rarer kinds rarer, at least 100 m apart', () {
      int count(Terrain t) => [
            for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng)) ...WorldFeatures.inCell(cx, cy, (x, y) => all(t, x, y)),
          ].length;
      final bushes = count(Terrain.grass), pads = count(Terrain.water), rocks = count(Terrain.rock), grates = count(Terrain.street);
      expect(count(Terrain.urban), 0); // grates are only in the street
      expect(bushes, greaterThan(pads));
      expect(pads, greaterThan(rocks));
      expect(rocks, greaterThan(grates));
      // Spacing holds within and across cells.
      for (final t in [Terrain.grass, Terrain.water, Terrain.street]) {
        final fs = [
          for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng)) ...WorldFeatures.inCell(cx, cy, (x, y) => all(t, x, y)),
        ];
        for (var i = 0; i < fs.length; i++) {
          for (var j = i + 1; j < fs.length; j++) {
            expect(distanceMeters(fs[i].lat, fs[i].lng, fs[j].lat, fs[j].lng), greaterThanOrEqualTo(WorldFeatures.minSpacing - 1));
          }
        }
      }
    });

    test('a glowing sewer grate pays coins once; out of range or not glowing: nothing', () {
      final g = glowingDay('p1', Terrain.street);
      final f = g.first;
      expect(f['kind'], 'grate');
      // Too far away: nothing (and nothing is used up).
      expect(() => econ.claimFeature('p1', f['id'] as String, (f['lat'] as double) + 0.01, f['lng'] as double), throwsA(isA<MarketException>()));
      clock += 600000;
      final before = econ.account('p1').coins;
      final r = econ.claimFeature('p1', f['id'] as String, f['lat'] as double, f['lng'] as double);
      expect([250, 500, 1000, 2500, 5000], contains(r['coins']));
      expect(econ.account('p1').coins, before + (r['coins'] as int));
      expect(glow('p1').any((x) => x['id'] == f['id']), false);
      expect(() => econ.claimFeature('p1', f['id'] as String, f['lat'] as double, f['lng'] as double), throwsA(isA<MarketException>()));
      // One that doesn't glow gives nothing.
      final (cx, cy) = WorldSpawner.cellOf(f['lat'] as double, f['lng'] as double);
      final dull = [
        for (final (x, y) in WorldSpawner.cellsAround(lat, lng)) ...WorldFeatures.inCell(x, y, (a, b) => all(Terrain.street, a, b)),
      ].firstWhere((x) => x.id != f['id'] && !g.any((y) => y['id'] == x.id));
      expect(cx, isNotNull);
      expect(() => econ.claimFeature('p1', dull.id, dull.lat, dull.lng), throwsA(isA<MarketException>()));
    });

    test('lily pads and rock piles give an Epic or Legendary song', () {
      for (final t in [Terrain.rock, Terrain.water]) {
        final f = glowingDay('p1', t).first;
        expect(f['kind'], t == Terrain.rock ? 'rocks' : 'lilypad');
        final r = econ.claimFeature('p1', f['id'] as String, f['lat'] as double, f['lng'] as double);
        final c = CardPayload.fromJson(r['card'] as Map<String, dynamic>);
        expect(c.rarity.index, greaterThanOrEqualTo(Rarity.epic.index));
        expect(econ.account('p1').cards.values.any((x) => x.songId == c.songId) || r['dup'] != null, true);
        clock += 24 * 3600 * 1000;
      }
      expect(econ.account('p1').xp, greaterThan(0));
    });

    test('a sand castle gives a treasure map; digging at the X pays bits; straying loses the map', () {
      final g = glowingDay('p1', Terrain.sand, min: 2);
      final f = g.first;
      econ.claimFeature('p1', f['id'] as String, f['lat'] as double, f['lng'] as double);
      final tr = econ.account('p1').treasure!;
      final d = distanceMeters(f['lat'] as double, f['lng'] as double, tr.lat, tr.lng);
      expect(d, inInclusiveRange(kTreasureMinMeters - 1, 401));
      // Only one map at a time.
      clock += 600000;
      final f2 = g[1];
      expect(() => econ.claimFeature('p1', f2['id'] as String, f2['lat'] as double, f2['lng'] as double), throwsA(isA<MarketException>()));
      // Not at the X yet.
      clock += 600000;
      expect(() => econ.digTreasure('p1', f['lat'] as double, f['lng'] as double), throwsA(isA<MarketException>()));
      clock += 600000;
      final bits = econ.digTreasure('p1', tr.lat, tr.lng);
      expect([20, 50, 100], contains(bits));
      expect(econ.account('p1').bits, bits);
      expect(econ.account('p1').treasure, isNull);
      // Another map, then walking 600 m from where it was picked up.
      clock += 600000;
      econ.claimFeature('p1', f2['id'] as String, f2['lat'] as double, f2['lng'] as double);
      expect(econ.account('p1').treasure, isNotNull);
      clock += 600000;
      econ.presence('p1', (f2['lat'] as double) + 0.0054, f2['lng'] as double);
      expect(econ.account('p1').treasure, isNull);
    });

    test('glowing bushes are nests: more songs around them', () {
      final g = glowingDay('p1', Terrain.grass);
      expect(g.every((f) => f['kind'] == 'bush'), true);
      final nests = econ.spawnsAround('p1', lat, lng, grounds: built(lat, lng), terrains: terrainAll(Terrain.grass)).length;
      final plain = econ.spawnsAround('p2', lat, lng, grounds: built(lat, lng)).length;
      expect(nests, greaterThan(plain));
      // Bushes aren't tapped for anything.
      final f = g.first;
      expect(() => econ.claimFeature('p1', f['id'] as String, f['lat'] as double, f['lng'] as double), throwsA(isA<MarketException>()));
    });

    test('DJs stand at least 1 km apart', () {
      final songs = [for (var i = 0; i < 20; i++) SongInfo(id: 9000 + i, title: 'Hit $i', artistId: 1, artistName: 'A', rank: 900000)];
      final ground = CellGround(List.filled(64, CellGround.built));
      final djs = <DjNpc>[];
      final (cx0, cy0) = WorldSpawner.cellOf(lat, lng);
      for (var dy = -25; dy <= 25; dy++) {
        for (var dx = -25; dx <= 25; dx++) {
          final dj = WorldDjs.inCell(42, cx0 + dx, cy0 + dy, 20000, ground, songs);
          if (dj != null) djs.add(dj);
        }
      }
      expect(djs.length, greaterThan(3));
      for (var i = 0; i < djs.length; i++) {
        for (var j = i + 1; j < djs.length; j++) {
          expect(distanceMeters(djs[i].lat, djs[i].lng, djs[j].lat, djs[j].lng), greaterThanOrEqualTo(WorldDjs.minSpacing));
        }
      }
    });

    test('players near each other see each other for a minute; hidden and blocked ones are not shown', () {
      econ.presence('p2', lat + 0.001, lng, heading: 90);
      var seen = econ.presence('p1', lat, lng)['players'] as List;
      expect(seen.single['name'], 'Two');
      expect(seen.single['hdg'], 90);
      econ.setShowOnMap('p2', false);
      expect(econ.presence('p1', lat, lng)['players'], isEmpty);
      econ.setShowOnMap('p2', true);
      engine.setBlocked('p2', 'p1', true);
      expect(econ.presence('p1', lat, lng)['players'], isEmpty);
      engine.setBlocked('p2', 'p1', false);
      clock += 61000;
      seen = econ.presence('p1', lat, lng)['players'] as List;
      expect(seen, isEmpty);
    });

    test('team accuracy: +50% for a second player, +25% a third, +12.5% a fourth', () {
      expect(teamAccuracy([88]), 88);
      expect(teamAccuracy([50, 50]), 75);
      expect(teamAccuracy([50, 50, 50]), 87.5);
      expect(teamAccuracy([50, 50, 50, 50]), 93.75);
      expect(teamAccuracy([90, 95]), 100);
      expect(djAccuracy(500000), 90);
      expect(djAccuracy(1000000), 100);
    });

    test('a DJ battle: join, score, win a Canvas and XP — or lose', () {
      econ.admins.add('p2');
      econ.presence('p1', lat, lng);
      final dj = DjNpc.fromJson(econ.adminSummonDj('p2', 'p1'));
      expect(dj.accuracy, inInclusiveRange(90, 100));
      expect((econ.worldAround('p1')['djs'] as List).any((x) => x['id'] == dj.id), true);
      // A solo player at 88% loses; the DJ takes a break.
      var b = econ.challengeDj('p1', dj.id, lat, lng);
      b = econ.scoreBattle('p1', b['id'] as String, 88, 40);
      expect(b['done'], true);
      expect(b['won'], false);
      expect(() => econ.challengeDj('p1', dj.id, lat, lng), throwsA(isA<MarketException>()));
      clock += 11 * 60000;
      // Two players at 70% make 100%: they win.
      econ.presence('p2', lat, lng);
      b = econ.challengeDj('p1', dj.id, lat, lng);
      final id = b['id'] as String;
      expect((econ.presence('p2', lat, lng)['battles'] as List).single['id'], id);
      econ.joinBattle('p2', id, lat, lng);
      expect(econ.scoreBattle('p1', id, 70, 40)['done'], false);
      b = econ.scoreBattle('p2', id, 70, 40);
      expect(b['won'], true);
      expect(b['team'], 100);
      final winner = (b['winner'] as Map)['id'] as String;
      final prize = CardPayload.fromJson(b['prize'] as Map<String, dynamic>);
      expect(prize.edition, Edition.canvas);
      expect(prize.songId, dj.song.id);
      expect(econ.account(winner).cards.containsKey(prize.uid), true);
      expect(econ.account('p1').xp, kDjBattleXp);
      expect(econ.account('p2').xp, kDjBattleXp);
      expect((econ.worldAround('p1')['djs'] as List).any((x) => x['id'] == dj.id), false);
    });

    test('a battle nobody scores in is settled when its time is up', () {
      econ.admins.add('p2');
      econ.presence('p1', lat, lng);
      final dj = DjNpc.fromJson(econ.adminSummonDj('p2', 'p1'));
      final b = econ.challengeDj('p1', dj.id, lat, lng);
      clock += (kBattleSeconds + 15) * 1000;
      final after = econ.battleState('p1', b['id'] as String);
      expect(after['done'], true);
      expect(after['won'], false);
    });

    test('admins: perfect ring taps, go to a player, bring a player over', () {
      econ.admins.add('p2');
      econ.adminPerfectRing('p2', 'p1', true);
      expect(econ.sync(econ.account('p1'), null)['perfect'], true);
      econ.presence('p1', lat, lng);
      econ.presence('p2', lat + 0.2, lng); // ~22 km away
      final at = econ.adminWhereIs('p2', 'p1');
      expect(at['lat'], lat);
      econ.adminBringPlayer('p2', 'p1');
      final tp = econ.sync(econ.account('p1'), null)['teleport'] as Map<String, dynamic>;
      expect(tp['lat'], lat + 0.2);
      // Their game moves them: no impossible-travel flag, and the move is done.
      clock += 5000;
      econ.presence('p1', lat + 0.2, lng);
      expect(econ.account('p1').flags.where((f) => f.kind == 'impossible_travel'), isEmpty);
      expect(econ.account('p1').teleport, isNull);
      expect(() => econ.adminBringPlayer('p1', 'p2'), throwsA(isA<MarketException>())); // admins only
    });

    test('admins add and remove XP and bonuses', () {
      econ.admins.add('p2');
      expect(econ.adminXp('p2', 'p1', 5000), 5000);
      expect(econ.adminXp('p2', 'p1', -9000), 0);
      econ.adminBonus('p2', 'p1', 'rarity', 3);
      expect(econ.account('p1').bonuses.of(Bonus.rarity), 3);
      econ.adminBonus('p2', 'p1', 'rarity', -10);
      expect(econ.account('p1').bonuses.of(Bonus.rarity), 0);
      expect(() => econ.adminXp('p1', 'p2', 5), throwsA(isA<MarketException>()));
      // Bonuses survive a save and load.
      econ.adminBonus('p2', 'p1', 'spawn', 2);
      final a = econ.account('p1');
      final copy = Account.fromJson(a.toJson(), a.cards.values.toList());
      expect(copy.bonuses.of(Bonus.spawn), 2);
    });
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

    test('admins can gift items and coins and spawn any song next to a player', () async {
      econ.import('p2', {});
      expect(() => econ.adminGrant('p2', 'p1', item: 'pet_cat'), throwsA(isA<MarketException>()));
      econ.admins.add('p2');
      expect(econ.adminGrant('p2', 'p1', item: 'bundle_hats', coins: 100), contains('100 coins'));
      expect(econ.account('p1').owned.containsAll(shopIdsOfKind(ShopKind.hat)), true);
      expect(engine.peekInbox('p1').last.message, contains('gift'));
      // Spawning needs to know where the player is.
      final song = econ.catalog.songs.values.first;
      expect(() => econ.adminSpawnFor('p2', 'p1', song), throwsA(isA<MarketException>()));
      econ.spawnsAround('p1', 40.7812, -73.9665, grounds: built(40.7812, -73.9665));
      final s = WorldSpawn.fromJson(econ.adminSpawnFor('p2', 'p1', song, rarity: Rarity.legendary, edition: Edition.live));
      expect(s.rarity, Rarity.legendary);
      expect(distanceMeters(s.lat, s.lng, 40.7812, -73.9665), inInclusiveRange(14, 31));
      expect(econ.spawnsAround('p1', 40.7812, -73.9665).any((x) => x['id'] == s.id), true);
      final r = await econ.throwAt('p1', s.id, 40.7812, -73.9665, 100);
      expect(r.card!.edition, Edition.live);
      expect(econ.account('p1').adminLog.length, 2);
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
