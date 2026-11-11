part of 'game.dart';

/// A small feature standing on the map: where the world puts it, and where
/// it is drawn (moved off buildings, sewer grates onto the street).
class MapFeature {
  MapFeature(this.feature, this.x, this.y);
  final WorldFeature feature;

  /// Drawn position in world metres (relative to the map's origin).
  final double x, y;
  bool glow = false;

  FeatureKind get kind => feature.kind;
  String get id => feature.id;
  LatLng get point => LatLng(feature.lat, feature.lng);
}

/// Another player walking around nearby.
class NearbyPlayer {
  NearbyPlayer(this.id);
  final String id;
  String name = '';
  Map<String, dynamic> look = const {};
  int level = 1;

  /// Where the server last put them, and where they're drawn (gliding
  /// towards it).
  double lat = 0, lng = 0, drawLat = 0, drawLng = 0;
  double heading = 0, drawHeading = 0;
  bool moving = false;
  int seenAt = 0;

  /// The walk from one reported position to the next: it takes as long as
  /// the time between the two reports, so the player walks steadily from A
  /// to B instead of jumping and stopping.
  double fromLat = 0, fromLng = 0;
  int walkStart = 0, walkMs = 0;

  /// When the server last heard where they are (their clock on it).
  int serverAt = 0;
  final IdleDirector idle = IdleDirector();
}

/// A DJ battle going on close enough to join.
class NearbyBattle {
  NearbyBattle(this.id, this.dj, this.endAt, this.players, this.joined);
  final String id;
  final DjNpc dj;
  final int endAt;
  final int players;
  final bool joined;
}

/// What the Exploration Update adds to the world around the player: map
/// features (some glowing), DJs, other players and DJ battles.
class WorldState extends ChangeNotifier {
  WorldState(this.g);
  final Game g;

  List<MapFeature> features = const [];
  List<DjNpc> djs = const [];
  final Map<String, NearbyPlayer> players = {};
  List<NearbyBattle> battles = const [];

  final Set<String> _glow = {};
  final Set<String> _summonSeen = {};
  final Map<String, String> _terrainCache = {};
  int _builtFor = -1;
  String _builtCell = '';
  Timer? _poll;
  bool _polling = false;

  /// Server time minus this device's clock (ms).
  int clockSkew = 0;
  int get serverNow => DateTime.now().millisecondsSinceEpoch + clockSkew;

  void start() {
    _poll ??= Timer.periodic(const Duration(seconds: 8), (_) => refreshPresence());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // -------------------------------------------------------------- features
  /// A cell's terrain code from the loaded map, or null while it's loading.
  String? terrainOf(int cx, int cy) {
    final key = '${g.mapData.originLat}:$cx:$cy';
    final hit = _terrainCache[key];
    if (hit != null) return hit;
    final squares = <Terrain>[];
    for (var row = 0; row < CellTerrain.n; row++) {
      for (var col = 0; col < CellTerrain.n; col++) {
        final (lat, lng) = WorldSpawner.squareCenter(cx, cy, row, col);
        final t = g.zones.terrainAt(lat, lng);
        if (t == null) return null;
        squares.add(t);
      }
    }
    if (_terrainCache.length > 400) _terrainCache.clear();
    return _terrainCache[key] = CellTerrain(squares).encode();
  }

  CellTerrain? _terrain(int cx, int cy) {
    final code = terrainOf(cx, cy);
    return code == null ? null : CellTerrain.parse(code);
  }

  /// The cells around the player, as the spawner counts them.
  List<(int, int)> _cells() {
    final p = g.location.position;
    return WorldSpawner.cellsAround(p.latitude, p.longitude);
  }

  /// Rebuilds the features around the player (when they've moved to
  /// another cell or more of the map has loaded).
  void rebuildFeatures({bool force = false}) {
    final p = g.location.position;
    final cell = '${WorldSpawner.cellOf(p.latitude, p.longitude)}';
    final v = g.mapData.version;
    if (!force && v == _builtFor && cell == _builtCell) return;
    _builtFor = v;
    _builtCell = cell;
    final map = g.mapData;
    final out = <MapFeature>[];
    for (final (cx, cy) in _cells()) {
      for (final f in WorldFeatures.inCell(cx, cy, _terrain)) {
        final placed = _place(map, f);
        if (placed == null) continue;
        out.add(MapFeature(f, placed.$1, placed.$2)..glow = _glow.contains(f.id));
      }
    }
    features = out;
    notifyListeners();
  }

  /// Where a feature is drawn: sewer grates sit on the nearest street, and
  /// nothing stands on (or pokes into) a building — a feature in one moves
  /// to the nearest free spot, or isn't shown.
  (double, double)? _place(MapData map, WorldFeature f) {
    var (x, y) = map.toWorld(f.lat, f.lng);
    final margin = f.kind == FeatureKind.grate ? 5.0 : 7.0;
    if (f.kind == FeatureKind.lilypad) {
      // Lily pads float wholly on water: the map's zone squares are ~28 m,
      // so on a thin lake or river the spot can be on the bank — move the
      // pad onto the water nearby, or leave it out.
      bool afloat(double px, double py) =>
          map.inWater(px, py) && map.inWater(px + 6, py) && map.inWater(px - 6, py) && map.inWater(px, py + 6) && map.inWater(px, py - 6);
      if (afloat(x, y)) return (x, y);
      for (final r in const [8.0, 16.0, 24.0]) {
        for (var k = 0; k < 8; k++) {
          final a = (f.variant % 8 + k) * math.pi / 4;
          final nx = x + math.cos(a) * r, ny = y + math.sin(a) * r;
          if (afloat(nx, ny)) return (nx, ny);
        }
      }
      return null;
    }
    if (f.kind == FeatureKind.grate) {
      // Sewer grates are only ever in the street: on the road's centre
      // line, or not at all.
      final road = map.nearestRoad(x, y, within: 30);
      if (road == null) return null;
      return (road.$1, road.$2);
    }
    if (!map.insideBuilding(x, y, margin: margin)) return (x, y);
    for (final r in const [14.0, 26.0, 38.0]) {
      for (var k = 0; k < 8; k++) {
        final a = (f.variant % 8 + k) * math.pi / 4;
        final nx = x + math.cos(a) * r, ny = y + math.sin(a) * r;
        if (!map.insideBuilding(nx, ny, margin: margin)) return (nx, ny);
      }
    }
    return null;
  }

  /// Takes what the server sent with the spawns: which features glow and
  /// where the DJs are.
  void applyServer(Map<String, dynamic> j) {
    final glow = j['glow'];
    if (glow is List) {
      _glow
        ..clear()
        ..addAll([for (final x in glow) '${(x as Map)['id']}']);
      for (final f in features) {
        f.glow = _glow.contains(f.id);
      }
    }
    final d = j['djs'];
    if (d is List) {
      djs = [for (final x in d) DjNpc.fromJson(x as Map<String, dynamic>)];
      for (final dj in djs) {
        g.catalog.addSongs([Song.fromInfo(dj.song)]);
      }
    }
    final now = j['now'];
    if (now is num) clockSkew = now.toInt() - DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  final Map<String, IdleDirector> _djIdles = {};

  /// A DJ's animation state: always at the turntable.
  IdleDirector djIdle(String id) => _djIdles.putIfAbsent(id, () => IdleDirector(hashString(id) & 0xffff, false)..holdTurntable());

  final Map<String, (int, double, double)> _djSpots = {};

  /// Where a DJ stands on the map: beside the nearest road, off buildings.
  (double, double) djPosition(DjNpc dj) {
    final hit = _djSpots[dj.id];
    if (hit != null && hit.$1 == g.mapData.version) return (hit.$2, hit.$3);
    final p = _djSpot(dj);
    if (_djSpots.length > 60) _djSpots.clear();
    _djSpots[dj.id] = (g.mapData.version, p.$1, p.$2);
    return p;
  }

  (double, double) _djSpot(DjNpc dj) {
    final map = g.mapData;
    final (x, y) = map.toWorld(dj.lat, dj.lng);
    final road = map.nearestRoad(x, y, within: 60);
    if (road == null) return (x, y);
    for (final side in const [1.0, -1.0]) {
      final nx = road.$1 - road.$4 * 13 * side, ny = road.$2 + road.$3 * 13 * side;
      if (!map.insideBuilding(nx, ny, margin: 6)) return (nx, ny);
    }
    return (road.$1, road.$2);
  }

  /// Admin builds with "unlimited range" on reach everything on the map.
  bool get _unlimited => kAdminBuild && g.profile.debugEnabled && g.profile.unlimitedRange;

  bool inRange(LatLng p) => _unlimited || metersBetween(g.location.position, p) <= Game.catchRangeMeters;

  /// Uses a glowing feature. Returns the server's answer ({kind, coins |
  /// card (+dup) | treasure}).
  Future<Map<String, dynamic>> claim(MapFeature f) async {
    final p = g.location.position;
    final j = await g.econ.call('POST', '/features/${Uri.encodeComponent(f.id)}/claim',
        body: {'lat': p.latitude, 'lng': p.longitude, if (_unlimited) 'unlimited': true}, source: CardSource.wild);
    f.glow = false;
    _glow.remove(f.id);
    notifyListeners();
    return j;
  }

  // -------------------------------------------------------------- treasure
  /// Where the X is, if the player holds a treasure map.
  LatLng? get treasureSpot {
    final t = g.profile.treasure;
    return t == null ? null : LatLng((t['lat'] as num).toDouble(), (t['lng'] as num).toDouble());
  }

  /// The sand castle the map was found at (the middle of the map).
  LatLng? get treasureCastle {
    final t = g.profile.treasure;
    return t == null ? null : LatLng((t['cLat'] as num).toDouble(), (t['cLng'] as num).toDouble());
  }

  bool get atTreasure {
    final x = treasureSpot;
    return x != null && metersBetween(g.location.position, x) <= kTreasureDigMeters;
  }

  /// The map is lost when its holder strays too far from where they got it.
  void _checkTreasure() {
    final t = g.profile.treasure;
    if (t == null) return;
    final from = LatLng((t['fLat'] as num).toDouble(), (t['fLng'] as num).toDouble());
    if (metersBetween(g.location.position, from) > kTreasureMaxMeters) {
      g.profile.treasure = null;
      g.profile.changed();
      g.toast('You strayed too far — the treasure map crumbled away');
    }
  }

  /// Digs at the X. Returns the bits in the chest.
  Future<int> dig() async {
    final p = g.location.position;
    final j = await g.econ.call('POST', '/treasure/dig', body: {'lat': p.latitude, 'lng': p.longitude});
    return (j['bits'] as num?)?.toInt() ?? 0;
  }

  // -------------------------------------------------------------- presence
  /// Tells the server where the player is and learns who's around.
  Future<void> refreshPresence() async {
    if (!g.serverEconomy || _polling) return;
    _checkTreasure();
    _polling = true;
    try {
      final p = g.location.position;
      final j = await g.econ.call('POST', '/presence', body: {'lat': p.latitude, 'lng': p.longitude, 'hdg': g.location.heading});
      final now = (j['now'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
      clockSkew = now - DateTime.now().millisecondsSinceEpoch;
      final seen = <String>{};
      for (final x in (j['players'] as List? ?? const [])) {
        final m = x as Map<String, dynamic>;
        final id = m['id'] as String;
        seen.add(id);
        final lat = (m['lat'] as num).toDouble(), lng = (m['lng'] as num).toDouble();
        final at = (m['at'] as num?)?.toInt() ?? now;
        final fresh = !players.containsKey(id);
        final np = players.putIfAbsent(
            id,
            () => NearbyPlayer(id)
              ..drawLat = lat
              ..drawLng = lng
              ..fromLat = lat
              ..fromLng = lng
              ..drawHeading = (m['hdg'] as num?)?.toDouble() ?? 0);
        np
          ..name = m['name'] as String? ?? ''
          ..look = (m['look'] as Map<String, dynamic>?) ?? const {}
          ..level = (m['level'] as num?)?.toInt() ?? 1
          ..heading = (m['hdg'] as num?)?.toDouble() ?? 0
          ..seenAt = now;
        if (!fresh && at > np.serverAt && (lat != np.lat || lng != np.lng)) {
          final jump = metersBetween(LatLng(np.drawLat, np.drawLng), LatLng(lat, lng));
          if (jump > 300) {
            // Teleported (or a long gap): just appear there.
            np
              ..drawLat = lat
              ..drawLng = lng
              ..fromLat = lat
              ..fromLng = lng
              ..walkMs = 0;
          } else {
            // Walk there from wherever they're drawn now, taking as long as
            // the gap between the two reports.
            np
              ..fromLat = np.drawLat
              ..fromLng = np.drawLng
              ..walkStart = DateTime.now().millisecondsSinceEpoch
              ..walkMs = (at - np.serverAt).clamp(1500, 30000);
          }
        }
        np
          ..serverAt = at
          ..lat = lat
          ..lng = lng;
      }
      players.removeWhere((id, _) => !seen.contains(id));
      // A DJ new to this game (summoned, or found by another player):
      // fetch the world again to show it.
      final djIds = [for (final x in (j['djIds'] as List? ?? const [])) '$x'];
      if (djIds.any((id) => !djs.any((d) => d.id == id) && _summonSeen.add(id))) g._refreshSpawns(force: true);
      // DJs the server no longer lists (someone beat them) leave the map.
      if (j.containsKey('djIds') && djs.any((d) => !djIds.contains(d.id))) {
        djs = [for (final d in djs) if (djIds.contains(d.id)) d];
      }
      battles = [
        for (final x in (j['battles'] as List? ?? const []))
          NearbyBattle((x as Map)['id'] as String, DjNpc.fromJson(x['dj'] as Map<String, dynamic>), (x['endAt'] as num).toInt(), (x['players'] as num).toInt(), x['joined'] == true),
      ];
      notifyListeners();
    } catch (_) {
      // Tried again in a few seconds.
    } finally {
      _polling = false;
    }
  }

  /// Glides the drawn players towards where they were last seen (called
  /// every frame by the map).
  void animate(double dt) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final p in players.values) {
      var target = p.heading;
      if (p.walkMs > 0) {
        final u = ((nowMs - p.walkStart) / p.walkMs).clamp(0.0, 1.0);
        p
          ..drawLat = p.fromLat + (p.lat - p.fromLat) * u
          ..drawLng = p.fromLng + (p.lng - p.fromLng) * u;
        final span = metersBetween(LatLng(p.fromLat, p.fromLng), LatLng(p.lat, p.lng));
        p.moving = u < 1 && span > 1.5;
        // Face the way they're walking.
        if (p.moving) target = const Distance().bearing(LatLng(p.fromLat, p.fromLng), LatLng(p.lat, p.lng));
        if (u >= 1) p.walkMs = 0;
      } else {
        p
          ..drawLat = p.lat
          ..drawLng = p.lng
          ..moving = false;
      }
      final dh = ((target - p.drawHeading + 540) % 360) - 180;
      p.drawHeading = (p.drawHeading + dh * math.min(1.0, dt * 4) + 360) % 360;
      p.idle.update(dt, p.moving);
    }
    for (final dj in djs) {
      djIdle(dj.id).update(dt, false);
    }
    if (_djIdles.length > 40) _djIdles.removeWhere((id, _) => !djs.any((d) => d.id == id));
  }

  Future<void> setShowOnMap(bool show) async {
    g.profile.showOnMap = show;
    g.profile.changed();
    if (g.serverEconomy) await g.econ.call('POST', '/me/visibility', body: {'show': show});
  }

  // ------------------------------------------------------------ DJ battles
  Future<Map<String, dynamic>> challenge(DjNpc dj) async {
    final p = g.location.position;
    final j = await g.econ.call('POST', '/djs/${Uri.encodeComponent(dj.id)}/challenge',
        body: {'lat': p.latitude, 'lng': p.longitude, if (_unlimited) 'unlimited': true});
    return j['battle'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> join(String battleId) async {
    final p = g.location.position;
    final j = await g.econ.call('POST', '/battles/${Uri.encodeComponent(battleId)}/join', body: {'lat': p.latitude, 'lng': p.longitude});
    return j['battle'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> score(String battleId, double accuracy, int beats) async {
    final j = await g.econ.call('POST', '/battles/${Uri.encodeComponent(battleId)}/score', body: {'acc': accuracy, 'beats': beats}, source: CardSource.wild);
    return j['battle'] as Map<String, dynamic>;
  }

  /// Sends this player's running accuracy; answers with the battle and
  /// everyone's running accuracies (`live`).
  Future<Map<String, dynamic>> liveScore(String battleId, double accuracy) async {
    final j = await g.econ.call('POST', '/battles/${Uri.encodeComponent(battleId)}/live', body: {'acc': accuracy});
    return j['battle'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> battle(String battleId) async {
    final j = await g.econ.call('GET', '/battles/${Uri.encodeComponent(battleId)}', source: CardSource.wild);
    return j['battle'] as Map<String, dynamic>;
  }

  /// A DJ was beaten (or needs a break): off the map until the server
  /// says otherwise.
  void removeDj(String id) {
    djs = [for (final d in djs) if (d.id != id) d];
    notifyListeners();
  }

  // ---------------------------------------------------------------- levels
  Future<void> chooseBonus(Bonus b) => g.econ.call('POST', '/me/bonuses/${b.name}');
  Future<void> respec() => g.econ.call('POST', '/me/respec');
}
