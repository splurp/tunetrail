part of 'economy.dart';

/// A treasure map: where the chest is buried, the sand castle the map
/// shows, and where the player was when they got it.
class Treasure {
  Treasure({required this.lat, required this.lng, required this.castleLat, required this.castleLng, required this.fromLat, required this.fromLng, required this.at});
  final double lat, lng;
  final double castleLat, castleLng;
  final double fromLat, fromLng;
  final int at;

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'cLat': castleLat, 'cLng': castleLng, 'fLat': fromLat, 'fLng': fromLng, 'at': at};

  factory Treasure.fromJson(Map<String, dynamic> j) => Treasure(
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        castleLat: (j['cLat'] as num).toDouble(),
        castleLng: (j['cLng'] as num).toDouble(),
        fromLat: (j['fLat'] as num).toDouble(),
        fromLng: (j['fLng'] as num).toDouble(),
        at: (j['at'] as num?)?.toInt() ?? 0,
      );
}

/// A DJ battle: players near the DJ tap along to its song for
/// [kBattleSeconds]; their combined accuracy has to beat the DJ's.
class Battle {
  Battle({required this.id, required this.dj, required this.startAt, required this.endAt});
  final String id;
  final DjNpc dj;
  final int startAt, endAt;

  /// Players and the accuracy each handed in (null until they do).
  final Map<String, double?> players = {};

  /// Each player's running accuracy while the battle is on (for the live
  /// team score and battle meter).
  final Map<String, double> live = {};
  bool resolved = false;
  bool won = false;
  double team = 0;
  String? winnerId;
  CardPayload? prize;
  final Map<String, int> xp = {};
}

/// Map features, treasure, DJ battles, players near each other, levels
/// and bonuses.
extension EconomyWorld on Economy {
  static const _playersRadius = 600.0;
  static const _presenceMs = 60000;

  (int, int) _day(Account a) {
    final offset = a.tz ?? 0;
    final d = WorldSpawner.dayAt(now(), offset);
    return (d, WorldSpawner.dayEndMs(d, offset));
  }

  // -------------------------------------------------------------- features
  /// The features of a cell that glow today.
  Iterable<WorldFeature> _glowingIn(Account a, int cx, int cy, int d) sync* {
    for (final f in WorldFeatures.inCell(cx, cy, (x, y) => a.terrains['$x:$y:$d'])) {
      if (WorldFeatures.glows(seed, cx, cy, f.square, d)) yield f;
    }
  }

  /// Extra spawn spots in a cell from the glowing nests around it.
  List<(int, double, double)> _nestSpots(Account a, int cx, int cy, int d, CellGround ground) {
    final out = <(int, double, double)>[];
    for (final f in _glowingIn(a, cx, cy, d)) {
      if (!f.kind.nest) continue;
      for (final (slot, lat, lng) in WorldFeatures.nestSpots(seed, f, d, expectedInCell: math.max(0.5, WorldSpawner.expectedSpots(ground)))) {
        // Not on water (where the ground there is known).
        final (sx, sy) = WorldSpawner.cellOf(lat, lng);
        final g = a.grounds['$sx:$sy:$d'];
        if (g != null) {
          final row = ((lat / WorldSpawner.cellDeg - sy) * CellGround.n).floor().clamp(0, CellGround.n - 1);
          final col = ((lng / WorldSpawner.lngDegForRow(sy) - sx) * CellGround.n).floor().clamp(0, CellGround.n - 1);
          if (g.squares[row * CellGround.n + col] == CellGround.water) continue;
        }
        out.add((slot, lat, lng));
      }
    }
    return out;
  }

  /// What glows around the player and which DJs are about (sent with the
  /// spawns). Glowing features already used today are left out.
  Map<String, dynamic> worldAround(String id) {
    final a = account(id);
    final lat = a.lat, lng = a.lng;
    if (lat == null || lng == null) return const {};
    final (d, dayEnd) = _day(a);
    final t = now();
    final glow = <Map<String, dynamic>>[];
    final djs = <Map<String, dynamic>>[];
    a.djDone.removeWhere((_, until) => until < t);
    for (final (cx, cy) in WorldSpawner.cellsAround(lat, lng)) {
      for (final f in _glowingIn(a, cx, cy, d)) {
        if (!a.claimedFeatures.contains('${f.id}:$d')) glow.add(f.toJson());
      }
      _settleDj(a, cx, cy, d, dayEnd);
    }
    for (final dj in _djsNear(a, lat, lng)) {
      djs.add(dj.toJson());
    }
    return {'glow': glow, 'djs': djs};
  }

  WorldFeature _feature(Account a, String featureId, int d) {
    final p = featureId.split(':');
    final cx = p.length == 3 ? int.tryParse(p[0]) : null, cy = p.length == 3 ? int.tryParse(p[1]) : null, sq = p.length == 3 ? int.tryParse(p[2]) : null;
    if (cx == null || cy == null || sq == null) throw MarketException('Nothing there');
    for (final f in _glowingIn(a, cx, cy, d)) {
      if (f.square == sq) return f;
    }
    throw MarketException('Nothing there');
  }

  /// Works out a cell's DJ for the day once, for everyone (from the first
  /// ground map the server has for the cell).
  void _settleDj(Account a, int cx, int cy, int d, int dayEnd) {
    final id = 'dj:$cx:$cy:$d';
    if (worldDjs.containsKey(id) || noDj.contains(id) || defeatedDjs.containsKey(id)) return;
    final ground = a.grounds['$cx:$cy:$d'];
    final songs = _playableDjSongs();
    if (ground == null || songs.isEmpty) return;
    final dj = WorldDjs.inCell(seed, cx, cy, d, ground, songs, expiresAt: dayEnd);
    if (dj == null) {
      if (noDj.length > 200000) noDj.clear();
      noDj.add(id);
    } else {
      worldDjs[id] = dj;
    }
  }

  /// The DJs a player can see: any player's, within about 700 m, except
  /// ones this player beat today (or that are taking a break from them).
  Iterable<DjNpc> _djsNear(Account a, double lat, double lng) sync* {
    final t = now();
    worldDjs.removeWhere((_, x) => x.expiresAt > 0 && x.expiresAt < t);
    if (defeatedDjs.values.any((until) => until < t)) {
      defeatedDjs.removeWhere((_, until) => until < t);
      _saveDefeated();
    }
    for (final dj in worldDjs.values) {
      if (a.djDone.containsKey(dj.id) || defeatedDjs.containsKey(dj.id)) continue;
      if (distanceMeters(lat, lng, dj.lat, dj.lng) <= 700) yield dj;
    }
  }

  /// Uses a glowing feature the player is standing by: coins from a sewer
  /// grate, a treasure map from a sand castle, an Epic or Legendary song
  /// from a lily pad (fishing) or rock pile (mining). Once a day each.
  Map<String, dynamic> claimFeature(String id, String featureId, double lat, double lng, {bool unlimitedRange = false}) {
    final a = account(id);
    _moveTo(a, lat, lng);
    final (d, _) = _day(a);
    final f = _feature(a, featureId, d);
    final key = '${f.id}:$d';
    if (a.claimedFeatures.contains(key)) throw MarketException('Nothing left here today');
    if (f.kind.nest) throw MarketException('Songs gather around this one');
    final dist = distanceMeters(lat, lng, f.lat, f.lng);
    if (dist > kCatchRangeMeters + kCatchRangeSlackMeters + 30 && !(unlimitedRange && admins.contains(id))) {
      _flag(a, 'feature_out_of_range', '${dist.round()} m from a ${f.kind.label}');
      throw MarketException('You\'re too far away — walk closer');
    }
    final out = <String, dynamic>{'kind': f.kind.name};
    switch (f.kind) {
      case FeatureKind.grate:
        final coins = rollWeighted(kGrateCoins, rng.nextDouble());
        a.coins += coins;
        a.stat('grateCoins', coins);
        out['coins'] = coins;
      case FeatureKind.sandcastle:
        if (a.treasure != null) throw MarketException('You already have a treasure map — dig that treasure up first');
        a.treasure = _buryTreasure(a, f, lat, lng, d);
        out['treasure'] = a.treasure!.toJson();
      case FeatureKind.lilypad || FeatureKind.rocks:
        if (catalog.songs.isEmpty) throw MarketException('The song catalogue is still loading — try again soon');
        final rarity = rng.nextInt(100) < kFoundLegendaryPercent ? Rarity.legendary : Rarity.epic;
        final pool = catalog.pool;
        final r = Rng(rng.nextInt(1 << 32) ^ (now() << 20));
        SongInfo? song;
        for (var i = 0; i < 12 && (song == null || pool.rarityOf(song.id).index < Rarity.epic.index); i++) {
          song = pool.pickSong(r, rarity: rarity);
        }
        if (song == null) throw MarketException('Nothing bit — try again');
        final card = song.toPayload(uid: 0, rarity: pool.rarityOf(song.id), acquiredAt: now());
        final (got, dup) = _give(a, card);
        final xp = _xp(a, catchXp(card.rarity));
        a.stat(f.kind == FeatureKind.lilypad ? 'fished' : 'mined', 1);
        out
          ..['card'] = (got ?? card).toJson()
          ..['xp'] = xp;
        if (got == null) out['dup'] = dup;
      case FeatureKind.bush || FeatureKind.sapling:
        break;
    }
    a.claimedFeatures.add(key);
    touch(a);
    return out;
  }

  /// Picks where a sand castle's treasure is buried: 120–400 m from the
  /// castle, on land where the ground is known, and never so far that
  /// walking there would lose the map.
  Treasure _buryTreasure(Account a, WorldFeature castle, double lat, double lng, int d) {
    final mPerLat = 111132.95, mPerLng = 111319.49 * math.max(0.2, math.cos(castle.lat * math.pi / 180));
    (double, double)? best;
    for (var i = 0; i < 24; i++) {
      final ang = rng.nextDouble() * 2 * math.pi;
      final dist = kTreasureMinMeters + rng.nextDouble() * (400 - kTreasureMinMeters);
      final tLat = castle.lat + math.sin(ang) * dist / mPerLat, tLng = castle.lng + math.cos(ang) * dist / mPerLng;
      if (distanceMeters(lat, lng, tLat, tLng) > kTreasureMaxMeters - 60) continue;
      best ??= (tLat, tLng);
      final (cx, cy) = WorldSpawner.cellOf(tLat, tLng);
      final g = a.grounds['$cx:$cy:$d'];
      if (g == null) continue;
      final row = ((tLat / WorldSpawner.cellDeg - cy) * CellGround.n).floor().clamp(0, CellGround.n - 1);
      final col = ((tLng / WorldSpawner.lngDegForRow(cy) - cx) * CellGround.n).floor().clamp(0, CellGround.n - 1);
      if (g.squares[row * CellGround.n + col] == CellGround.water) continue;
      best = (tLat, tLng);
      break;
    }
    best ??= (castle.lat + kTreasureMinMeters / mPerLat, castle.lng);
    return Treasure(lat: best.$1, lng: best.$2, castleLat: castle.lat, castleLng: castle.lng, fromLat: lat, fromLng: lng, at: now());
  }

  /// Digs at the X of the player's treasure map. Returns the bits in the
  /// chest.
  int digTreasure(String id, double lat, double lng) {
    final a = account(id);
    _moveTo(a, lat, lng);
    final tr = a.treasure;
    if (tr == null) throw MarketException('Your treasure map is gone — you strayed too far from where you found it');
    final dist = distanceMeters(lat, lng, tr.lat, tr.lng);
    if (dist > kTreasureDigMeters + kCatchRangeSlackMeters) throw MarketException('Nothing here — the X is ${dist.round()} m away');
    final bits = rollWeighted(kTreasureBits, rng.nextDouble());
    a.bits += bits;
    a.treasure = null;
    a.stat('treasures', 1);
    a.stat('treasureBits', bits);
    touch(a);
    return bits;
  }

  // -------------------------------------------------------------- presence
  /// Records where the player is and returns who and what is around them:
  /// players whose position is under a minute old, and DJ battles close
  /// enough to join.
  Map<String, dynamic> presence(String id, double lat, double lng, {double heading = 0}) {
    final a = account(id);
    _moveTo(a, lat, lng);
    if (heading.isFinite) a.heading = heading % 360;
    final t = now();
    _active.removeWhere((_, at) => t - at > _presenceMs);
    final me = engine.players[id];
    final players = <Map<String, dynamic>>[];
    for (final otherId in _active.keys) {
      if (otherId == id) continue;
      final o = accounts[otherId];
      if (o == null || !o.showOnMap || o.lat == null || o.lng == null) continue;
      if (distanceMeters(lat, lng, o.lat!, o.lng!) > _playersRadius) continue;
      final p = engine.players[otherId];
      if (p == null || !p.named) continue;
      if ((me?.blocked.contains(otherId) ?? false) || p.blocked.contains(id)) continue;
      players.add({'id': otherId, 'name': p.name, 'lat': o.lat, 'lng': o.lng, 'hdg': o.heading, 'look': p.look, 'level': o.level, 'at': o.locAt});
      if (players.length >= 40) break;
    }
    _sweepBattles();
    final near = <Map<String, dynamic>>[];
    for (final b in battles.values) {
      if (b.resolved || t >= b.endAt - 6000) continue;
      if (distanceMeters(lat, lng, b.dj.lat, b.dj.lng) > kBattleJoinMeters) continue;
      near.add({'id': b.id, 'dj': b.dj.toJson(), 'endAt': b.endAt, 'players': b.players.length, 'joined': b.players.containsKey(id)});
    }
    // The DJs around now (the game fetches the world again if one is new
    // to it: summoned, or found by another player).
    final djIds = [for (final dj in _djsNear(a, lat, lng)) dj.id];
    return {'players': players, 'battles': near, 'now': t, 'djIds': djIds};
  }

  void setShowOnMap(String id, bool show) {
    final a = account(id);
    a.showOnMap = show;
    touch(a);
  }

  // ------------------------------------------------------------ DJ battles
  List<SongInfo> _playableDjSongs() {
    final pool = catalog.pool;
    if (!identical(pool, _djSongsPool) || _djSongs == null) {
      _djSongsPool = pool;
      _djSongs = WorldDjs.playable(pool.songs.values);
    }
    return _djSongs!;
  }

  /// Loads the DJs beaten before a restart.
  Future<void> loadWorld() async {
    try {
      final j = await catalog.store.loadBlob('defeatedDjs');
      if (j is Map) {
        for (final e in j.entries) {
          if (e.value is num) defeatedDjs['${e.key}'] = (e.value as num).toInt();
        }
      }
    } catch (_) {}
  }

  void _saveDefeated() {
    catalog.store.saveBlob('defeatedDjs', defeatedDjs).catchError((Object _) {});
  }

  DjNpc _dj(Account a, String djId) {
    if (defeatedDjs.containsKey(djId)) throw MarketException('Someone has already beaten this DJ');
    final known = worldDjs[djId];
    if (known != null && (known.expiresAt == 0 || known.expiresAt >= now())) return known;
    final p = djId.split(':');
    final (d, dayEnd) = _day(a);
    if (p.length == 4 && p[0] == 'dj' && p[3] == '$d') {
      final cx = int.tryParse(p[1]), cy = int.tryParse(p[2]);
      final ground = a.grounds['$cx:$cy:$d'];
      if (cx != null && cy != null && ground != null) {
        final dj = WorldDjs.inCell(seed, cx, cy, d, ground, _playableDjSongs(), expiresAt: dayEnd);
        if (dj != null) return dj;
      }
    }
    throw MarketException('That DJ has packed up');
  }

  Map<String, dynamic> _battleJson(Battle b, String viewer) {
    final t = now();
    return {
      'id': b.id,
      'dj': b.dj.toJson(),
      'startAt': b.startAt,
      'endAt': b.endAt,
      'now': t,
      'players': [
        for (final e in b.players.entries)
          {'id': e.key, 'name': engine.nameOf(e.key), 'look': engine.players[e.key]?.look ?? const {}, if (b.resolved && e.value != null) 'acc': e.value},
      ],
      'live': {for (final e in b.live.entries) e.key: e.value},
      'done': b.resolved,
      if (b.resolved) ...{
        'won': b.won,
        'team': b.team,
        'djAcc': b.dj.accuracy,
        if (b.winnerId != null) 'winner': {'id': b.winnerId, 'name': engine.nameOf(b.winnerId!)},
        if (b.prize != null) 'prize': b.prize!.toJson(),
        'xp': b.xp[viewer] ?? 0,
      },
    };
  }

  /// Challenges a DJ the player is standing by (or joins the battle if
  /// someone else already started one with it).
  Map<String, dynamic> challengeDj(String id, String djId, double lat, double lng, {bool unlimitedRange = false}) {
    final a = account(id);
    _moveTo(a, lat, lng);
    _sweepBattles();
    final t = now();
    for (final b in battles.values) {
      if (b.dj.id == djId && !b.resolved && t < b.endAt - 6000) return joinBattle(id, b.id, lat, lng);
    }
    if ((a.djDone[djId] ?? 0) > t) throw MarketException('This DJ needs a break — come back later');
    final dj = _dj(a, djId);
    final dist = distanceMeters(lat, lng, dj.lat, dj.lng);
    if (dist > kCatchRangeMeters + kCatchRangeSlackMeters + 30 && !(unlimitedRange && admins.contains(id))) {
      throw MarketException('You\'re too far away — walk closer');
    }
    // A few seconds for the song to load before the first beat.
    final b = Battle(id: 'b${++_battleCounter}-$t', dj: dj, startAt: t + 4000, endAt: t + 4000 + kBattleSeconds * 1000);
    b.players[id] = null;
    battles[b.id] = b;
    return _battleJson(b, id);
  }

  /// Joins a battle going on nearby.
  Map<String, dynamic> joinBattle(String id, String battleId, double lat, double lng) {
    final a = account(id);
    _moveTo(a, lat, lng);
    final b = battles[battleId];
    final t = now();
    if (b == null || b.resolved || t >= b.endAt - 6000) throw MarketException('That battle is over');
    if (distanceMeters(lat, lng, b.dj.lat, b.dj.lng) > kBattleJoinMeters + kCatchRangeSlackMeters) throw MarketException('You\'re too far away to join');
    if (b.players.length >= 12 && !b.players.containsKey(id)) throw MarketException('This battle is full');
    b.players.putIfAbsent(id, () => null);
    return _battleJson(b, id);
  }

  /// A player's average accuracy over the battle (beats they let go by
  /// count as zero in it).
  Map<String, dynamic> scoreBattle(String id, String battleId, double accuracy, int beats) {
    final a = account(id);
    final b = battles[battleId];
    if (b == null || !b.players.containsKey(id)) throw MarketException('That battle is over');
    if (!b.resolved && b.players[id] == null) {
      final acc = beats <= 0 || !accuracy.isFinite ? 0.0 : accuracy.clamp(0.0, 100.0).toDouble();
      b.players[id] = acc;
      if (acc >= 99.5 && beats >= 20) _flag(a, 'dj_accuracy', '${acc.toStringAsFixed(1)}% over $beats beats');
      if (b.players.values.every((v) => v != null)) _resolve(b);
    }
    return battleState(id, battleId);
  }

  /// A player's running accuracy during the battle; answers with the
  /// battle (everyone's running accuracies).
  Map<String, dynamic> liveScore(String id, String battleId, double accuracy) {
    final b = battles[battleId];
    if (b == null || !b.players.containsKey(id)) throw MarketException('That battle is over');
    if (!b.resolved && accuracy.isFinite) b.live[id] = accuracy.clamp(0.0, 100.0).toDouble();
    return _battleJson(b, id);
  }

  Map<String, dynamic> battleState(String id, String battleId) {
    _sweepBattles();
    final b = battles[battleId];
    if (b == null) throw MarketException('That battle is over');
    return _battleJson(b, id);
  }

  /// Settles battles whose time is up, and forgets old ones.
  void _sweepBattles() {
    final t = now();
    for (final b in battles.values) {
      // A few seconds for the last scores to arrive.
      if (!b.resolved && t > b.endAt + 6000) _resolve(b);
    }
    battles.removeWhere((_, b) => t > b.endAt + 10 * 60000);
  }

  void _resolve(Battle b) {
    if (b.resolved) return;
    b.resolved = true;
    final scored = {for (final e in b.players.entries) if (e.value != null) e.key: e.value!};
    b.team = teamAccuracy(scored.values.toList());
    b.won = scored.isNotEmpty && b.team > b.dj.accuracy;
    final t = now();
    for (final pid in b.players.keys) {
      final a = accounts[pid];
      if (a == null) continue;
      // Beaten DJs are gone for the day; after a loss they take a break.
      a.djDone[b.dj.id] = b.won ? math.max(b.dj.expiresAt, t + 3600000) : t + 10 * 60000;
      a.stat(b.won ? 'djWins' : 'djLosses', 1);
      if (b.won && scored.containsKey(pid)) b.xp[pid] = _xp(a, kDjBattleXp);
      touch(a);
    }
    if (!b.won) return;
    // Beaten: the DJ leaves the map for everyone (for the rest of its day,
    // or until a summoned one would have left).
    final dj = b.dj;
    defeatedDjs[dj.id] = dj.expiresAt > 0 ? math.max(dj.expiresAt, t + 60000) : t + 24 * 3600000;
    worldDjs.remove(dj.id);
    _saveDefeated();
    // One of the team, at random, takes home a Canvas of the song.
    final ids = scored.keys.toList();
    final winner = ids[rng.nextInt(ids.length)];
    final a = accounts[winner];
    if (a == null) return;
    final song = b.dj.song;
    final rarity = catalog.songs.containsKey(song.id) ? catalog.pool.rarityOf(song.id) : Rarity.rare;
    final serial = engine.claimSerial(song.id, Edition.canvas, song: song, playerId: winner);
    // Every Canvas of the song already claimed: a Shiny instead.
    final card = serial != null
        ? song.toPayload(uid: 0, rarity: rarity, edition: Edition.canvas, serial: serial, acquiredAt: t)
        : song.toPayload(uid: 0, rarity: rarity, shiny: true, acquiredAt: t);
    b
      ..winnerId = winner
      ..prize = _add(a, card, keepUid: false);
    touch(a);
  }

  // ---------------------------------------------------------------- levels
  /// Takes one of the bonuses the player's level has earned.
  void chooseBonus(String id, String bonus) {
    final a = account(id);
    final b = Bonus.byName(bonus);
    if (b == null) throw MarketException('Unknown bonus');
    if (a.bonuses.unspent(a.level) <= 0) throw MarketException('No bonus to choose yet — one comes every $kLevelsPerBonus levels');
    a.bonuses.chosen[b] = (a.bonuses.chosen[b] ?? 0) + 1;
    touch(a);
  }

  /// Hands every chosen bonus back to be chosen again, for bits.
  void respecBonuses(String id) {
    final a = account(id);
    if (a.bonuses.chosenTotal == 0) throw MarketException('You haven\'t chosen any bonuses yet');
    if (a.bits < kRespecBits) throw MarketException('Choosing again costs $kRespecBits bits');
    a.bits -= kRespecBits;
    a.bonuses.chosen.clear();
    touch(a);
  }

  // ----------------------------------------------------------------- admin
  Account _adminTarget(String adminId, String targetId) {
    if (!admins.contains(adminId)) throw MarketException('Admins only');
    final a = accounts[targetId];
    if (a == null || !a.imported) throw MarketException('That player isn\'t on the server economy yet (they need to open the updated game once)');
    return a;
  }

  /// Admin: adds XP to a player, or takes it away ([delta] < 0).
  int adminXp(String adminId, String targetId, int delta) {
    final a = _adminTarget(adminId, targetId);
    final before = a.xp;
    a.xp = (a.xp + delta).clamp(0, xpForLevel(kMaxLevel) + 1000000);
    final change = a.xp - before;
    _logAdmin(a, adminId, '${change >= 0 ? 'gave' : 'took'} ${change.abs()} XP');
    if (change != 0) engine.notice(targetId, change > 0 ? 'You received $change XP' : '${change.abs()} XP was removed from your account', title: 'XP');
    touch(a);
    return a.xp;
  }

  /// Admin: adds a bonus to a player (on top of the ones their level
  /// gives), or removes one ([delta] < 0).
  Map<String, dynamic> adminBonus(String adminId, String targetId, String bonus, int delta) {
    final a = _adminTarget(adminId, targetId);
    final b = Bonus.byName(bonus);
    if (b == null) throw MarketException('Unknown bonus');
    final have = a.bonuses.of(b);
    final change = math.max(delta, -have).clamp(-200, 200);
    a.bonuses.granted[b] = (a.bonuses.granted[b] ?? 0) + change;
    _logAdmin(a, adminId, '${change >= 0 ? 'added' : 'removed'} ${change.abs()}× ${b.label} bonus');
    if (change != 0) {
      engine.notice(targetId, change > 0 ? 'You received a bonus: ${b.label} ×$change' : 'A bonus was removed: ${b.label} ×${change.abs()}', title: 'Bonuses');
    }
    touch(a);
    return a.bonuses.toJson();
  }

  /// Admin: every ring tap of a player counts as perfect (for testing).
  void adminPerfectRing(String adminId, String targetId, bool on) {
    final a = _adminTarget(adminId, targetId);
    a.perfectRing = on;
    _logAdmin(a, adminId, on ? 'turned on perfect ring accuracy' : 'turned off perfect ring accuracy');
    touch(a);
  }

  /// Admin: where a player last was ({lat, lng, at}), to go there.
  Map<String, dynamic> adminWhereIs(String adminId, String targetId) {
    final a = _adminTarget(adminId, targetId);
    if (a.lat == null || a.lng == null) throw MarketException('This player hasn\'t opened the map yet');
    final me = accounts[adminId];
    if (me != null) me.travelGraceUntil = now() + 10 * 60000;
    return {'lat': a.lat, 'lng': a.lng, 'at': a.locAt};
  }

  /// Admin: moves a player to where the admin is (their game moves them
  /// there the next time it hears from the server).
  void adminBringPlayer(String adminId, String targetId) {
    final a = _adminTarget(adminId, targetId);
    final me = accounts[adminId];
    if (me == null || me.lat == null || me.lng == null) throw MarketException('Open the map first, so the server knows where you are');
    final t = now();
    a
      ..teleport = {'lat': me.lat, 'lng': me.lng, 'at': t}
      ..travelGraceUntil = t + 10 * 60000;
    _logAdmin(a, adminId, 'moved them to ${engine.nameOf(adminId)}');
    engine.notice(targetId, '${engine.nameOf(adminId)} moved you to where they are', title: 'Teleported');
    touch(a);
  }

  /// Admin: a DJ turns up near a player (for half an hour).
  Map<String, dynamic> adminSummonDj(String adminId, String targetId) {
    final a = _adminTarget(adminId, targetId);
    final lat = a.lat, lng = a.lng;
    if (lat == null || lng == null) throw MarketException('This player hasn\'t opened the map yet');
    final songs = _playableDjSongs();
    if (songs.isEmpty) throw MarketException('The song catalogue is still loading — try again soon');
    final t = now();
    final (name, look) = WorldDjs.persona(rng.nextInt(1 << 32));
    final song = songs[rng.nextInt(songs.length)];
    final ang = rng.nextDouble() * 2 * math.pi;
    final dj = DjNpc(
      id: 'dj:summon:$t',
      name: name,
      lat: lat + math.sin(ang) * 60 / 111132.95,
      lng: lng + math.cos(ang) * 60 / (111319.49 * math.max(0.2, math.cos(lat * math.pi / 180))),
      look: look,
      song: song,
      accuracy: djAccuracy(song.rank),
      expiresAt: t + 30 * 60000,
    );
    worldDjs[dj.id] = dj;
    _logAdmin(a, adminId, 'summoned $name (${song.title})');
    if (adminId != targetId) engine.notice(targetId, '$name has turned up near you — find them on the map for a DJ battle', title: 'DJ battle');
    return dj.toJson();
  }
}
