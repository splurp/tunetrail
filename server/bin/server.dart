// Tunetrail multiplayer server (market, serial numbers, accounts).
//
//   dart run bin/server.dart                 (JSON file storage, guests allowed)
//
// Environment (production):
//   PORT               port to listen on (Cloud Run sets this)
//   DATABASE_URL       Postgres URL (e.g. Supabase) — state is kept there
//   SESSION_SECRET     long random string used to sign session tokens
//   GOOGLE_CLIENT_IDS  comma-separated OAuth client ids whose Google
//                      sign-in tokens are accepted
//   ALLOW_GUESTS       "true" to also accept unauthenticated X-Player-Id
//                      players (default: true only when no Google ids set)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:tunetrail_core/tunetrail_core.dart';
import 'package:tunetrail_server/auth.dart';
import 'package:tunetrail_server/store.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  var port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  var dataPath = 'market.json';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
    if (args[i] == '--data') dataPath = args[i + 1];
  }
  final googleIds = {for (final s in (env['GOOGLE_CLIENT_IDS'] ?? '').split(',')) if (s.trim().isNotEmpty) s.trim()};
  final secret = env['SESSION_SECRET'] ?? '';
  if (googleIds.isNotEmpty && secret.length < 32) {
    stderr.writeln('SESSION_SECRET must be set (32+ characters) when Google sign-in is enabled');
    exit(1);
  }
  final auth = Auth(
    secret: secret.isEmpty ? 'dev-only-secret-change-me-0123456789' : secret,
    googleClientIds: googleIds,
    allowGuests: (env['ALLOW_GUESTS'] ?? (googleIds.isEmpty ? 'true' : 'false')).toLowerCase() == 'true',
  );

  final store = await Store.open(databaseUrl: env['DATABASE_URL'], filePath: dataPath);
  final engine = MarketEngine();
  final saved = await store.load();
  if (saved != null) engine.loadJson(saved);
  stdout.writeln('Loaded ${engine.listings.length} listings from ${store.label}');

  // Saved before a changing request is answered: on hosts that pause the
  // CPU between requests (Cloud Run) a background timer could never run.
  var dirty = false;
  engine.onChanged = () => dirty = true;
  Future<void> persist() async {
    if (!dirty) return;
    dirty = false;
    try {
      await store.save(engine.toJson());
    } catch (e) {
      dirty = true;
      stderr.writeln('save failed: $e');
    }
  }

  final app = buildRouter(engine, auth);
  final handler = const Pipeline()
      .addMiddleware(_cors())
      .addMiddleware(_rateLimit())
      .addMiddleware((inner) => (req) async {
            final res = await inner(req);
            if (req.method != 'GET') await persist();
            return res;
          })
      .addHandler(app.call);
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('Tunetrail server on :${server.port} · storage: ${store.label} · google ids: ${googleIds.length} · guests: ${auth.allowGuests}');
}

Router buildRouter(MarketEngine m, Auth auth) {
  final r = Router();

  /// The calling player: from a session token, or (when guests are
  /// allowed) the X-Player-Id header.
  String pid(Request req) {
    String? id, name;
    final authz = req.headers['authorization'] ?? '';
    if (authz.startsWith('Bearer ')) {
      final who = auth.check(authz.substring(7).trim());
      if (who == null) throw AuthException('Session expired — sign in again');
      (id, name) = who;
    } else if (auth.allowGuests) {
      id = req.headers['x-player-id'];
      name = Uri.decodeComponent(req.headers['x-player-name'] ?? 'Player');
      if (id == null || id.isEmpty) throw MarketException('Missing X-Player-Id');
      if (id.startsWith('g_')) throw AuthException('Sign in to use this account');
    } else {
      throw AuthException('Sign in required');
    }
    final shown = req.headers['x-player-name'] != null ? Uri.decodeComponent(req.headers['x-player-name']!) : name;
    if (!m.players.containsKey(id) || m.players[id]!.name != shown) m.register(id, shown);
    return id;
  }

  Future<Map<String, dynamic>> body(Request req) async {
    final s = await req.readAsString();
    return s.isEmpty ? {} : jsonDecode(s) as Map<String, dynamic>;
  }

  Response ok(Object? data) => Response.ok(jsonEncode(data),
      headers: {'content-type': 'application/json'});

  Future<Response> guard(Future<Response> Function() f) async {
    try {
      return await f();
    } on MarketException catch (e) {
      return Response(400,
          body: jsonEncode({'error': e.message}),
          headers: {'content-type': 'application/json'});
    } on AuthException catch (e) {
      return Response(401, body: jsonEncode({'error': e.message}), headers: {'content-type': 'application/json'});
    } on FormatException catch (e) {
      return Response(400, body: jsonEncode({'error': e.message}));
    }
  }

  r.get('/serials/<song>/<edition>', (Request req, String song, String edition) => guard(() async => ok({
        'left': m.serialsLeft(int.parse(song), Edition.fromIndex(int.parse(edition))),
      })));
  r.post('/serials/<song>/<edition>/claim', (Request req, String song, String edition) => guard(() async {
        pid(req);
        return ok({'serial': m.claimSerial(int.parse(song), Edition.fromIndex(int.parse(edition)))});
      }));
  r.get('/health', (Request req) => ok({'ok': true, 'listings': m.listings.length, 'players': m.players.length}));

  // Google sign-in → session token.
  r.post('/auth/google', (Request req) => guard(() async {
        final b = await body(req);
        final token = b['idToken'] as String?;
        if (token == null || token.isEmpty) throw AuthException('Missing idToken');
        final (id, name) = await auth.verifyGoogle(token);
        if (!m.players.containsKey(id)) m.register(id, name);
        return ok({'token': auth.issue(id, m.players[id]!.name), 'playerId': id, 'name': m.players[id]!.name});
      }));

  r.get('/listings', (Request req) => guard(() async {
        final q = ListingQuery.fromQueryParams(req.url.queryParameters);
        return ok([for (final l in m.browse(q)) l.toJson()]);
      }));
  r.get('/listings/mine', (Request req) => guard(() async =>
      ok([for (final l in m.listingsOf(pid(req))) l.toJson()])));
  r.post('/listings', (Request req) => guard(() async {
        final b = await body(req);
        final l = m.createListing(
          pid(req),
          [for (final i in (b['items'] as List? ?? const [])) ListingItem.fromJson(i as Map<String, dynamic>)],
          folderPrice: (b['folderPrice'] as num?)?.toInt(),
          note: b['note'] as String? ?? '',
          acceptsTrades: b['trades'] as bool? ?? false,
        );
        return ok(l.toJson());
      }));
  r.post('/listings/<id>/cancel', (Request req, String id) => guard(() async =>
      ok([for (final c in m.cancelListing(pid(req), id)) c.toJson()])));
  r.post('/listings/<id>/buy', (Request req, String id) => guard(() async {
        final b = await body(req);
        return ok([for (final c in m.buyListing(pid(req), id, expectedPrice: (b['price'] as num?)?.toInt())) c.toJson()]);
      }));
  r.post('/listings/<id>/items/<uid>/buy', (Request req, String id, String uid) => guard(() async {
        final b = await body(req);
        return ok(m.buyItem(pid(req), id, int.parse(uid), expectedPrice: (b['price'] as num?)?.toInt()).toJson());
      }));
  r.post('/listings/<id>/items/<uid>/withdraw', (Request req, String id, String uid) => guard(() async =>
      ok(m.withdrawItem(pid(req), id, int.parse(uid)).toJson())));

  r.get('/offers', (Request req) => guard(() async =>
      ok([for (final o in m.offersFor(pid(req))) o.toJson()])));
  r.post('/offers', (Request req) => guard(() async {
        final b = await body(req);
        final o = m.createOffer(
            pid(req),
            b['listingId'] as String,
            [
              for (final c in (b['cards'] as List? ?? const []))
                CardPayload.fromJson(c as Map<String, dynamic>)
            ],
            (b['coins'] as num?)?.toInt() ?? 0,
            note: b['note'] as String? ?? '');
        return ok(o.toJson());
      }));
  r.post('/offers/<id>/accept', (Request req, String id) => guard(() async {
        m.acceptOffer(pid(req), id);
        return ok({'ok': true});
      }));
  r.post('/offers/<id>/decline', (Request req, String id) => guard(() async {
        m.declineOffer(pid(req), id);
        return ok({'ok': true});
      }));

  r.get('/inbox', (Request req) => guard(() async =>
      ok([for (final i in m.claimInbox(pid(req))) i.toJson()])));

  r.get('/showcases', (Request req) => guard(() async {
        final p = req.url.queryParameters;
        return ok([
          for (final s in m.browseShowcases(
              offset: int.tryParse(p['offset'] ?? '') ?? 0,
              limit: int.tryParse(p['limit'] ?? '') ?? 30))
            s.toJson()
        ]);
      }));
  r.put('/showcases/me', (Request req) => guard(() async {
        final b = await body(req);
        final s = m.setShowcase(
            pid(req),
            b['title'] as String? ?? '',
            [
              for (final c in (b['cards'] as List? ?? const []))
                CardPayload.fromJson(c as Map<String, dynamic>)
            ],
            [
              for (final p in (b['playlists'] as List? ?? const []))
                ShowcasePlaylist.fromJson(p as Map<String, dynamic>)
            ],
            favoriteArtists: [
              for (final a in (b['favArtists'] as List? ?? const []))
                FavoriteArtist.fromJson(a as Map<String, dynamic>)
            ]);
        return ok(s.toJson());
      }));
  r.post('/showcases/<owner>/like', (Request req, String owner) => guard(() async =>
      ok({'likes': m.likeShowcase(pid(req), owner)})));

  return r;
}

Middleware _cors() => (inner) => (req) async {
      if (req.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }
      final res = await inner(req);
      return res.change(headers: _corsHeaders);
    };

const _corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, PUT, OPTIONS',
  'access-control-allow-headers': 'content-type, authorization, x-player-id, x-player-name',
};

/// Simple per-address limit (120 requests a minute) against floods.
Middleware _rateLimit() {
  final hits = <String, (int, int)>{}; // address → (window start ms, count)
  return (inner) => (req) async {
        final info = req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final ip = req.headers['x-forwarded-for']?.split(',').first.trim() ?? info?.remoteAddress.address ?? '?';
        final now = DateTime.now().millisecondsSinceEpoch;
        final (start, n) = hits[ip] ?? (now, 0);
        final fresh = now - start > 60000;
        final count = fresh ? 1 : n + 1;
        hits[ip] = (fresh ? now : start, count);
        if (hits.length > 50000) hits.removeWhere((_, v) => now - v.$1 > 60000);
        if (count > 120) return Response(429, body: jsonEncode({'error': 'Too many requests — slow down'}));
        return inner(req);
      };
}
