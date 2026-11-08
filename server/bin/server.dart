// Tunetrail multiplayer market server.
//
//   dart run bin/server.dart --port 8080 --data market.json
//
// Every request identifies the player with the `X-Player-Id` and
// `X-Player-Name` headers. This is a development server: it does no
// authentication and trusts client-reported coin balances (see README).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

Future<void> main(List<String> args) async {
  var port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  var dataPath = 'market.json';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
    if (args[i] == '--data') dataPath = args[i + 1];
  }

  final engine = MarketEngine();
  final file = File(dataPath);
  if (file.existsSync()) {
    engine.loadJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    stdout.writeln('Loaded ${engine.listings.length} listings from $dataPath');
  }
  Timer? saveTimer;
  engine.onChanged = () {
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(seconds: 2), () {
      final tmp = File('$dataPath.tmp');
      tmp.writeAsStringSync(jsonEncode(engine.toJson()));
      tmp.renameSync(dataPath);
    });
  };

  final app = buildRouter(engine);
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_cors())
      .addHandler(app.call);
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('Tunetrail market listening on http://${server.address.host}:${server.port}');
}

Router buildRouter(MarketEngine m) {
  final r = Router();

  String pid(Request req) {
    final id = req.headers['x-player-id'];
    if (id == null || id.isEmpty) throw MarketException('Missing X-Player-Id');
    final name = Uri.decodeComponent(req.headers['x-player-name'] ?? 'Player');
    if (!m.players.containsKey(id) || m.players[id]!.name != name) {
      m.register(id, name);
    }
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
    } on FormatException catch (e) {
      return Response(400, body: jsonEncode({'error': e.message}));
    }
  }

  r.get('/health', (Request req) => ok({'ok': true, 'listings': m.listings.length}));

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
  'access-control-allow-headers': 'content-type, x-player-id, x-player-name',
};
