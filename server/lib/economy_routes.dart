import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import 'economy.dart';

/// HTTP routes of the server-side economy. Every answer carries `acct`: the
/// player's balances, items and card changes since the `X-Econ-Rev` the
/// game sent (or `full: true`, and the game fetches `/me/cards`).
void addEconomyRoutes(
  Router r,
  Economy e, {
  required String Function(Request) pid,
  required String Function(Request) named,
  required String Function(Request) admin,
  required Future<Map<String, dynamic>> Function(Request) body,
  required Response Function(Object?) ok,
  required Future<Response> Function(Future<Response> Function()) guard,
}) {
  int? rev(Request req) => int.tryParse(req.headers['x-econ-rev'] ?? '');
  int? tzOf(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  double num0(Map<String, dynamic> b, String k) => (b[k] as num?)?.toDouble() ?? double.nan;

  /// [data] plus the account sync.
  Response withAcct(Request req, String id, Map<String, dynamic> data) => ok({...data, 'acct': e.sync(e.account(id), rev(req))});

  // ---------------------------------------------------------------- account
  r.post('/me/import', (Request req) => guard(() async {
        final id = pid(req);
        final a = e.import(id, await body(req));
        return ok({'acct': e.sync(a, null)});
      }));
  r.get('/me/account', (Request req) => guard(() async => withAcct(req, pid(req), const {})));
  r.get('/me/cards', (Request req) => guard(() async {
        final a = e.account(pid(req));
        return ok({'rev': a.rev, 'cards': [for (final c in a.cards.values) c.toJson()]});
      }));

  // ----------------------------------------------------------------- spawns
  r.post('/spawns', (Request req) => guard(() async {
        final id = pid(req);
        final b = await body(req);
        final zones = <String, Map<int, double>>{};
        final raw = b['zones'] as Map<String, dynamic>? ?? const {};
        for (final z in raw.entries.take(64)) {
          final m = <int, double>{};
          for (final g in (z.value as Map<String, dynamic>).entries.take(30)) {
            final k = int.tryParse(g.key), v = (g.value as num?)?.toDouble();
            if (k != null && v != null && v.isFinite) m[k] = v.clamp(0.2, 5.0);
          }
          zones[z.key] = m;
        }
        final grounds = <String, String>{
          for (final g in (b['grounds'] as Map<String, dynamic>? ?? const {}).entries.take(64))
            if (g.value is String && (g.value as String).length == 32) g.key: g.value as String,
        };
        // Games before Beta v1.0.4 don't send ground maps: every cell counts
        // as open land for them.
        if (!b.containsKey('grounds') && num0(b, 'lat').isFinite && num0(b, 'lng').isFinite) {
          final land = CellGround.allLand().encode();
          for (final (cx, cy) in WorldSpawner.cellsAround(num0(b, 'lat'), num0(b, 'lng'))) {
            grounds['$cx:$cy'] = land;
          }
        }
        final list = e.spawnsAround(id, num0(b, 'lat'), num0(b, 'lng'), tz: tzOf(b['tz']), zones: zones, grounds: grounds);
        return withAcct(req, id, {'spawns': list, 'now': e.now()});
      }));
  r.post('/spawns/<sid>/buy', (Request req, String sid) => guard(() async {
        final id = pid(req);
        final b = await body(req);
        final price = e.buySpawn(id, Uri.decodeComponent(sid), num0(b, 'lat'), num0(b, 'lng'));
        return withAcct(req, id, {'price': price});
      }));
  r.post('/spawns/<sid>/throw', (Request req, String sid) => guard(() async {
        final id = pid(req);
        final b = await body(req);
        final res = await e.throwAt(id, Uri.decodeComponent(sid), num0(b, 'lat'), num0(b, 'lng'), (b['acc'] as num?)?.toInt() ?? 0,
            unlimitedRange: b['unlimited'] == true, noLiveFootage: b['noLive'] == true);
        return withAcct(req, id, res.toJson());
      }));

  // ------------------------------------------------------------------ packs
  Map<String, dynamic> pull((CardPayload, CardPayload?, int) p) => {
        'card': (p.$2 ?? p.$1).toJson(),
        if (p.$2 == null) 'dup': p.$3,
      };
  r.post('/packs/<pack>/open', (Request req, String pack) => guard(() async {
        final id = named(req);
        final pulls = e.openPack(id, pack);
        return withAcct(req, id, {'pulls': [for (final p in pulls) pull(p)]});
      }));
  r.get('/blindbox/<artist>', (Request req, String artist) => guard(() async {
        pid(req);
        return ok({'price': await e.blindBoxPriceOf(int.parse(artist))});
      }));
  r.post('/blindbox/<artist>/open', (Request req, String artist) => guard(() async {
        final id = named(req);
        final b = await body(req);
        final p = await e.openBlindBox(id, int.parse(artist), expectedPrice: (b['price'] as num?)?.toInt());
        return withAcct(req, id, {'pull': pull(p)});
      }));

  // ------------------------------------------------------------------- shop
  r.post('/shop/<item>/buy', (Request req, String item) => guard(() async {
        final id = pid(req);
        e.buyItem(id, item);
        return withAcct(req, id, const {});
      }));
  r.post('/shop/<item>/grant', (Request req, String item) => guard(() async {
        final id = pid(req);
        e.grant(id, item);
        return withAcct(req, id, const {});
      }));
  r.post('/me/scrap', (Request req) => guard(() async {
        final id = pid(req);
        final b = await body(req);
        final coins = e.scrap(id, [for (final u in (b['uids'] as List? ?? const [])) (u as num).toInt()]);
        return withAcct(req, id, {'coins': coins});
      }));

  // ----------------------------------------------------------------- quests
  r.get('/quests', (Request req) => guard(() async {
        final id = pid(req);
        return withAcct(req, id, e.questBoard(id, tz: tzOf(req.url.queryParameters['tz'])));
      }));
  r.post('/quests/<q>/claim', (Request req, String q) => guard(() async {
        final id = pid(req);
        final (card, dup) = await e.claimQuest(id, Uri.decodeComponent(q));
        return withAcct(req, id, {if (card != null) 'card': card.toJson(), if (dup > 0) 'dup': dup});
      }));

  // -------------------------------------------------------------- minigames
  r.get('/minigames/<game>', (Request req, String game) => guard(() async {
        final id = pid(req);
        return ok(e.minigameQuota(id, game, tz: tzOf(req.url.queryParameters['tz'])));
      }));
  r.post('/minigames/<game>/start', (Request req, String game) => guard(() async {
        final id = pid(req);
        final b = await body(req);
        return withAcct(req, id, e.startMinigame(id, game, tz: tzOf(b['tz'])));
      }));
  r.post('/minigames/<game>/award', (Request req, String game) => guard(() async {
        final id = pid(req);
        final b = await body(req);
        return withAcct(req, id, {'paid': e.awardMinigame(id, game, (b['bits'] as num?)?.toInt() ?? 0)});
      }));

  // ------------------------------------------------------------------ admin
  r.post('/admin/econ/balances', (Request req) => guard(() async {
        final id = admin(req);
        final b = await body(req);
        e.adminSetBalances(id, coins: (b['coins'] as num?)?.toInt(), bits: (b['bits'] as num?)?.toInt());
        return withAcct(req, id, const {});
      }));
  r.post('/admin/econ/cards', (Request req) => guard(() async {
        final id = admin(req);
        final b = await body(req);
        return withAcct(req, id, {'added': e.adminGenerateCards(id, (b['n'] as num?)?.toInt() ?? 0)});
      }));
  r.post('/admin/econ/clear', (Request req) => guard(() async {
        final id = admin(req);
        e.adminClearCards(id);
        return withAcct(req, id, const {});
      }));
  r.post('/admin/econ/minigames/reset', (Request req) => guard(() async {
        final id = admin(req);
        e.adminResetMinigames(id);
        return withAcct(req, id, const {});
      }));
  r.post('/admin/econ/respawn', (Request req) => guard(() async {
        final id = admin(req);
        e.adminRespawn(id);
        return withAcct(req, id, const {});
      }));
  r.post('/admin/econ/free/<item>', (Request req, String item) => guard(() async {
        final id = admin(req);
        e.buyItem(id, item, free: true);
        return withAcct(req, id, const {});
      }));
  r.post('/admin/econ/spawn', (Request req) => guard(() async {
        final id = admin(req);
        final b = await body(req);
        final s = e.debugSpawn(id, SongInfo.fromJson(b['song'] as Map<String, dynamic>), num0(b, 'lat'), num0(b, 'lng'),
            shiny: b['shiny'] == true, edition: Edition.fromIndex((b['ed'] as num?)?.toInt() ?? 0));
        return ok(s);
      }));
  r.get('/admin/flags', (Request req) => guard(() async {
        admin(req);
        return ok(e.flagged());
      }));
  r.post('/admin/flags/<player>/clear', (Request req, String player) => guard(() async {
        admin(req);
        e.clearFlags(Uri.decodeComponent(player));
        return ok({'ok': true});
      }));
}
