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
//   SPAWN_SEED         secret that decides what spawns where (any string;
//                      defaults to one derived from SESSION_SECRET). Keep it
//                      private: with it, spawns could be predicted.
//   CATALOG_CRAWL      "false" to skip growing the song catalogue from Deezer
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:tunetrail_core/tunetrail_core.dart';
import 'package:tunetrail_server/auth.dart';
import 'package:tunetrail_server/catalog.dart';
import 'package:tunetrail_server/economy.dart';
import 'package:tunetrail_server/economy_routes.dart';
import 'package:tunetrail_server/push.dart';
import 'package:tunetrail_server/store.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  var port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  var dataPath = 'market.json';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
    if (args[i] == '--data') dataPath = args[i + 1];
  }
  // Admin accounts (comma-separated player ids, e.g. g_1234…; see the
  // game's Settings → Player ID): only these can
  // use debug tools, and only in the admin build of the game.
  final admins = {for (final s in (env['ADMINS'] ?? '').split(',')) if (s.trim().isNotEmpty) s.trim()};
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
  for (final e in (await store.loadCollections()).entries) {
    engine.collections[e.key] = [for (final c in e.value) CardPayload.fromJson(c as Map<String, dynamic>)];
  }
  stdout.writeln('Loaded ${engine.listings.length} listings and ${engine.collections.length} collections from ${store.label}');

  // The song catalogue and the server-side economy (balances, cards,
  // spawns, packs, quests).
  final catalog = ServerCatalog(store);
  await catalog.load();
  final seedText = env['SPAWN_SEED'] ?? '';
  final economy = Economy(
    engine: engine,
    catalog: catalog,
    seed: hashString(seedText.isNotEmpty ? seedText : 'spawns:${secret.isEmpty ? 'dev' : secret}'),
    admins: admins,
  )..attach();
  for (final (data, cards) in await store.loadAccounts()) {
    final a = Account.fromJson(data, cards);
    economy.accounts[a.id] = a;
    if (a.imported) {
      // Keep what their old game last uploaded (for restoring lost cards).
      final old = engine.collections[a.id];
      if (old != null && old.isNotEmpty) economy.legacy[a.id] = old;
      engine.collections[a.id] = a.cards.values.toList();
    }
  }
  await economy.loadWorld();
  stdout.writeln('Economy: ${economy.accounts.length} accounts');
  if ((env['CATALOG_CRAWL'] ?? 'true').toLowerCase() != 'false') {
    unawaited(catalog.crawl().then((_) => catalog.fixGenres()).catchError((Object e) => stderr.writeln('catalogue crawl failed: $e')));
  }

  // Saved before a changing request is answered: on hosts that pause the
  // CPU between requests (Cloud Run) a background timer could never run.
  var dirty = false;
  engine.onChanged = () => dirty = true;
  final dirtyCollections = <String>{};
  engine.onCollectionChanged = dirtyCollections.add;
  Future<void> persist() async {
    for (final id in economy.dirty.toList()) {
      economy.dirty.remove(id);
      final a = economy.accounts[id];
      if (a == null) continue;
      final changed = economy.pendingCards.remove(id) ?? const <int, CardPayload?>{};
      final full = economy.rewriteCards.remove(id);
      try {
        await store.saveAccount(id, a.toJson(), changed: changed, allCards: full ? a.cards.values.toList() : null, currentCards: () => a.cards.values.toList());
      } catch (e) {
        economy.dirty.add(id);
        economy.rewriteCards.add(id);
        stderr.writeln('account save failed: $e');
      }
    }
    for (final id in dirtyCollections.toList()) {
      // Accounts on the server economy are saved above.
      if (economy.active(id)) {
        dirtyCollections.remove(id);
        continue;
      }
      dirtyCollections.remove(id);
      try {
        await store.saveCollection(id, [for (final c in engine.collections[id] ?? const <CardPayload>[]) c.toJson()]);
      } catch (e) {
        dirtyCollections.add(id);
        stderr.writeln('collection save failed: $e');
      }
    }
    if (!dirty) return;
    dirty = false;
    try {
      await store.save(engine.toJson());
    } catch (e) {
      dirty = true;
      stderr.writeln('save failed: $e');
    }
  }

  // Push notifications (optional): a Firebase service account.
  PushSender? push;
  try {
    push = await PushSender.fromBase64(env['FIREBASE_SERVICE_ACCOUNT_B64']);
  } catch (e) {
    stderr.writeln('push notifications disabled: $e');
  }
  if (push != null) {
    final sender = push;
    engine.onNotify = (id, title, body) {
      for (final t in List.of(engine.pushTokens[id] ?? const <String>[])) {
        sender.send(t, title, body).then((ok) {
          if (!ok) engine.dropPushToken(t);
        }).catchError((Object e) {
          stderr.writeln('push failed: $e');
        });
      }
    };
  }

  final app = buildRouter(engine, auth, admins: admins, economy: economy, catalog: catalog);
  final handler = const Pipeline()
      .addMiddleware(_cors())
      .addMiddleware(_rateLimit())
      .addMiddleware((inner) => (req) async {
            final res = await inner(req);
            // Reads can change state too (claiming the inbox, expiring
            // listings, marking messages read); persist() skips clean state.
            await persist();
            return res;
          })
      .addHandler(app.call);
  // Auctions end on time (and send their notifications) even when nobody
  // happens to be using the market.
  Timer.periodic(const Duration(seconds: 15), (_) async {
    if (engine.settleAuctions() > 0 || engine.expireListings() > 0) await persist();
  });
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('Tunetrail server on :${server.port} · storage: ${store.label} · google ids: ${googleIds.length} · guests: ${auth.allowGuests} · push: ${push != null}');
}

Router buildRouter(MarketEngine m, Auth auth, {Set<String> admins = const {}, Economy? economy, ServerCatalog? catalog}) {
  final r = Router();
  final econ = economy;

  /// The calling player: from a session token, or (when guests are
  /// allowed) the X-Player-Id header.
  String pid(Request req) {
    final authz = req.headers['authorization'] ?? '';
    if (authz.startsWith('Bearer ')) {
      final who = auth.check(authz.substring(7).trim());
      if (who == null) throw AuthException('Session expired — sign in again');
      final id = who.$1;
      // Signed-in players are named only through /me/username.
      if (!m.players.containsKey(id)) m.register(id, 'New player');
      return id;
    }
    if (!auth.allowGuests) throw AuthException('Sign in required');
    final id = req.headers['x-player-id'];
    if (id == null || id.isEmpty || id.length > 64) throw MarketException('Missing X-Player-Id');
    if (id.startsWith('g_')) throw AuthException('Sign in to use this account');
    final shown = cleanUserText(Uri.decodeComponent(req.headers['x-player-name'] ?? 'Player'), maxLength: kUsernameMax);
    if (!m.players.containsKey(id) || (!m.players[id]!.named && m.players[id]!.name != shown)) m.register(id, shown);
    return id;
  }

  /// The calling player, who must have chosen a username (guests on a
  /// development server count as named).
  String named(Request req) {
    final id = pid(req);
    final p = m.players[id]!;
    if (!p.named && id.startsWith('g_')) throw MarketException('Choose a username first');
    return id;
  }

  /// Request bodies are capped (a large collection is ~2 MB).
  Future<Map<String, dynamic>> body(Request req) async {
    const max = 8 * 1024 * 1024;
    if ((req.contentLength ?? 0) > max) throw MarketException('Request too large');
    final bytes = <int>[];
    await for (final chunk in req.read()) {
      bytes.addAll(chunk);
      if (bytes.length > max) throw MarketException('Request too large');
    }
    if (bytes.isEmpty) return {};
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map<String, dynamic>) throw const FormatException('Expected a JSON object');
    return j;
  }

  List<CardPayload> cards(Object? list) => [for (final c in (list as List? ?? const [])) CardPayload.fromJson(c as Map<String, dynamic>)];

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
      return Response(400, body: jsonEncode({'error': e.message}), headers: {'content-type': 'application/json'});
    } on TypeError {
      return Response(400, body: jsonEncode({'error': 'Malformed request'}), headers: {'content-type': 'application/json'});
    }
  }

  /// Runs a market request that hands over cards and/or coins: on the
  /// server economy they're taken from the player's account first (the
  /// player's own copies are used), and given back if the request fails.
  Response escrowed(String id, List<CardPayload> offered, int coins, Response Function(List<CardPayload> own) f) {
    final e = econ;
    if (e == null || !e.active(id)) return f(offered);
    if (coins < 0) throw MarketException('Invalid coin amount');
    if ((e.accounts[id]?.coins ?? 0) < coins) throw MarketException('Not enough coins ($coins needed)');
    final own = e.escrowCards(id, offered);
    e.escrowCoins(id, coins);
    try {
      return f(own);
    } catch (_) {
      e.credit(id, coins: coins, cards: own);
      rethrow;
    }
  }

  /// Runs a purchase or bid of [price] coins (taken first on the server
  /// economy; refunded if the request fails).
  Response paid(String id, int price, Response Function() f) {
    final e = econ;
    if (e == null || !e.active(id) || price <= 0) return f();
    e.escrowCoins(id, price);
    try {
      return f();
    } catch (_) {
      e.credit(id, coins: price);
      rethrow;
    }
  }

  r.get('/serials/<song>/<edition>', (Request req, String song, String edition) => guard(() async => ok({
        'left': m.serialsLeft(int.parse(song), Edition.fromIndex(int.parse(edition))),
      })));
  r.post('/serials/<song>/<edition>/claim', (Request req, String song, String edition) => guard(() async {
        final me = pid(req);
        // Games may send the song, for the Edition Checker's recent pulls.
        final b = await body(req);
        final info = b['song'] is Map<String, dynamic> ? SongInfo.fromJson(b['song'] as Map<String, dynamic>) : null;
        return ok({'serial': m.claimSerial(int.parse(song), Edition.fromIndex(int.parse(edition)), song: info?.id == int.parse(song) ? info : null, playerId: me)});
      }));
  r.get('/editions/recent', (Request req) => guard(() async {
        final e = Edition.fromIndex(int.tryParse(req.url.queryParameters['ed'] ?? '') ?? Edition.canvas.index);
        return ok(m.recentPullsOf(e));
      }));
  r.get('/health', (Request req) => ok({'ok': true, 'listings': m.listings.length, 'players': m.players.length}));

  // Google sign-in → session token.
  r.post('/auth/google', (Request req) => guard(() async {
        final b = await body(req);
        final token = b['idToken'] as String?;
        if (token == null || token.isEmpty) throw AuthException('Missing idToken');
        final (id, _) = await auth.verifyGoogle(token);
        if (!m.players.containsKey(id)) m.register(id, 'New player');
        final p = m.players[id]!;
        return ok({'token': auth.issue(id, p.name), 'playerId': id, 'name': p.name, 'needsUsername': !p.named});
      }));

  // ------------------------------------------------------------ account
  r.get(
    '/me',
    (Request req) => guard(() async {
      final p = m.players[pid(req)]!;
      final admin = admins.contains(p.id);
      return ok({
        'id': p.id,
        'name': p.name,
        'needsUsername': !p.named && p.id.startsWith('g_'),
        'unread': m.unreadCount(p.id),
        'admin': admin,
        if (econ != null) 'economy': true,
        if (econ != null) 'imported': econ.active(p.id),
        if (econ != null) 'usernameCost': econ.usernameChangeCost(p.id),
      });
    }),
  );
  r.get(
    '/usernames/check',
    (Request req) => guard(() async {
      final name = (req.url.queryParameters['name'] ?? '').trim();
      final err = usernameError(name);
      return ok({
        'ok': err == null && m.usernameAvailable(name, forId: pid(req)),
        'error': err ?? (m.usernameAvailable(name, forId: pid(req)) ? null : 'That username is taken'),
      });
    }),
  );
  r.post(
    '/me/username',
    (Request req) => guard(() async {
      final id = pid(req);
      final b = await body(req);
      final name = (b['name'] as String? ?? '').trim();
      final changing = m.players[id]?.named ?? false;
      if (changing && m.players[id]!.name == name) return ok({'name': name, 'token': auth.issue(id, name)});
      final cost = econ?.usernameChangeCost(id) ?? 0;
      if (cost > 0 && (econ!.accounts[id]?.bits ?? 0) < cost) throw MarketException('Changing your username again costs $cost bits');
      final p = m.setUsername(id, name);
      if (changing) econ?.chargeUsernameChange(id);
      return ok({'name': p.name, 'token': auth.issue(id, p.name)});
    }),
  );
  r.put(
    '/me/profile',
    (Request req) => guard(() async {
      final id = named(req);
      final b = await body(req);
      if (b['favArtists'] != null && catalog != null) {
        final ids = [for (final a in (b['favArtists'] as List)) ((a as Map<String, dynamic>)['id'] as num).toInt()];
        unawaited(catalog.ensureArtists(ids.take(200)).catchError((Object _) {}));
      }
      m.setPublicProfile(
        id,
        look: b['look'] as Map<String, dynamic>?,
        theme: b['theme'] as String?,
        level: (b['level'] as num?)?.toInt(),
        stats: b['stats'] == null
            ? null
            : {
                for (final e in (b['stats'] as Map<String, dynamic>).entries)
                  if (e.value is num) e.key: e.value as num,
              },
        editionShowcase: b['editions'] == null ? null : cards(b['editions']),
        favoriteArtists: b['favArtists'] == null ? null : [for (final a in (b['favArtists'] as List)) FavoriteArtist.fromJson(a as Map<String, dynamic>)],
      );
      return ok({'ok': true});
    }),
  );
  r.post(
    '/me/push',
    (Request req) => guard(() async {
      final id = named(req);
      final b = await body(req);
      m.registerPushToken(id, b['token'] as String? ?? '');
      return ok({'ok': true});
    }),
  );
  r.put(
    '/me/collection',
    (Request req) => guard(() async {
      final id = named(req);
      // Cards of players on the server economy live on the server.
      if (econ?.active(id) ?? false) return ok({'ok': true, 'count': m.collections[id]?.length ?? 0});
      final b = await body(req);
      final next = cards(b['cards']);
      // A fresh install mustn't wipe the collection an older game uploaded.
      if (next.isEmpty && (m.collections[id]?.isNotEmpty ?? false)) return ok({'ok': true, 'count': m.collections[id]!.length});
      m.setCollection(id, next);
      return ok({'ok': true, 'count': m.collections[id]?.length ?? 0});
    }),
  );

  // ------------------------------------------------------------ players
  r.get('/players', (Request req) => guard(() async {
        final me = pid(req);
        final q = req.url.queryParameters['q'] ?? '';
        return ok([for (final p in m.searchPlayers(q, excludeId: me)) p.toJson()]);
      }));
  r.get('/players/<id>', (Request req, String id) => guard(() async {
        final j = m.publicProfile(id, viewerId: pid(req)).toJson();
        // Balances of players on the server economy are shown on profiles.
        final a = econ?.accounts[id];
        if (a != null && a.imported) {
          j['coins'] = a.coins;
          j['bits'] = a.bits;
        }
        return ok(j);
      }));
  r.get('/players/<id>/collection', (Request req, String id) => guard(() async {
        pid(req);
        final q = req.url.queryParameters;
        return ok(m
            .collectionPage(id, text: q['q'] ?? '', offset: int.tryParse(q['offset'] ?? '') ?? 0, limit: int.tryParse(q['limit'] ?? '') ?? 60)
            .toJson());
      }));
  r.post('/players/<id>/offers', (Request req, String id) => guard(() async {
        final me = named(req);
        final b = await body(req);
        final coins = (b['coins'] as num?)?.toInt() ?? 0;
        return escrowed(me, cards(b['cards']), coins, (offered) {
          final o = m.createDirectOffer(me, id, [for (final u in (b['uids'] as List? ?? const [])) (u as num).toInt()], offered, coins, note: b['note'] as String? ?? '');
          return ok(o.toJson());
        });
      }));
  r.post('/players/<id>/block', (Request req, String id) => guard(() async {
        final b = await body(req);
        m.setBlocked(pid(req), id, b['blocked'] as bool? ?? true);
        return ok({'ok': true});
      }));

  // ----------------------------------------------------------- messages
  r.get('/messages', (Request req) => guard(() async => ok([for (final c in m.conversations(pid(req))) c.toJson()])));
  r.get('/messages/<id>', (Request req, String id) => guard(() async => ok([for (final x in m.thread(pid(req), id)) x.toJson()])));
  r.post(
    '/messages/<id>',
    (Request req, String id) => guard(() async {
      final me = named(req);
      final b = await body(req);
      return ok(m.sendMessage(me, id, b['text'] as String? ?? '', cardUid: (b['card'] as num?)?.toInt()).toJson());
    }),
  );

  r.get(
    '/listings',
    (Request req) => guard(() async {
      final q = ListingQuery.fromQueryParams(req.url.queryParameters);
      return ok([for (final l in m.browse(q)) l.toJson()]);
    }),
  );
  r.get('/listings/mine', (Request req) => guard(() async => ok([for (final l in m.listingsOf(pid(req))) l.toJson()])));
  r.post(
    '/listings',
    (Request req) => guard(() async {
      final b = await body(req);
      final me = named(req);
      final items = [for (final i in (b['items'] as List? ?? const [])) ListingItem.fromJson(i as Map<String, dynamic>)];
      return escrowed(me, [for (final i in items) i.card], 0, (own) {
        final l = m.createListing(
          me,
          [for (var k = 0; k < items.length; k++) ListingItem(card: own[k], price: items[k].price)],
          folderPrice: (b['folderPrice'] as num?)?.toInt(),
          note: b['note'] as String? ?? '',
          acceptsTrades: b['trades'] as bool? ?? false,
        );
        econ?.listedOnMarket(me);
        return ok(l.toJson());
      });
    }),
  );
  r.post('/listings/<id>/bump', (Request req, String id) => guard(() async => ok(m.bumpListing(pid(req), id).toJson())));
  r.post('/listings/<id>/cancel', (Request req, String id) => guard(() async {
        final me = pid(req);
        final back = m.cancelListing(me, id);
        econ?.credit(me, cards: back);
        return ok([for (final c in back) c.toJson()]);
      }));
  r.post('/listings/<id>/buy', (Request req, String id) => guard(() async {
        final me = pid(req);
        final b = await body(req);
        final price = m.listings[id]?.folderPrice ?? 0;
        return paid(me, price, () {
          final got = m.buyListing(me, id, expectedPrice: (b['price'] as num?)?.toInt());
          econ?.credit(me, cards: got);
          return ok([for (final c in got) c.toJson()]);
        });
      }));
  r.post('/listings/<id>/items/<uid>/buy', (Request req, String id, String uid) => guard(() async {
        final me = pid(req);
        final b = await body(req);
        final u = int.parse(uid);
        final price = m.listings[id]?.items.where((i) => i.card.uid == u).firstOrNull?.price ?? 0;
        return paid(me, price, () {
          final got = m.buyItem(me, id, u, expectedPrice: (b['price'] as num?)?.toInt());
          econ?.credit(me, cards: [got]);
          return ok(got.toJson());
        });
      }));
  r.post('/listings/<id>/items/<uid>/withdraw', (Request req, String id, String uid) => guard(() async {
        final me = pid(req);
        final back = m.withdrawItem(me, id, int.parse(uid));
        econ?.credit(me, cards: [back]);
        return ok(back.toJson());
      }));

  r.get('/offers', (Request req) => guard(() async =>
      ok([for (final o in m.offersFor(pid(req))) o.toJson()])));
  r.post('/offers', (Request req) => guard(() async {
        final b = await body(req);
        final me = named(req);
        final coins = (b['coins'] as num?)?.toInt() ?? 0;
        if (coins < 0) throw MarketException('Invalid coin amount');
        return escrowed(me, cards(b['cards']), coins, (offered) {
          final o = m.createOffer(me, b['listingId'] as String, offered, coins, note: b['note'] as String? ?? '');
          return ok(o.toJson());
        });
      }));
  r.post('/offers/<id>/accept', (Request req, String id) => guard(() async {
        m.acceptOffer(pid(req), id);
        return ok({'ok': true});
      }));
  r.post('/offers/<id>/decline', (Request req, String id) => guard(() async {
        m.declineOffer(pid(req), id);
        return ok({'ok': true});
      }));

  // ----------------------------------------------------------- auctions
  r.get('/auctions', (Request req) => guard(() async {
        final q = ListingQuery.fromQueryParams(req.url.queryParameters);
        return ok([for (final a in m.browseAuctions(q)) a.toJson()]);
      }));
  r.get('/auctions/mine', (Request req) => guard(() async => ok([for (final a in m.auctionsOf(pid(req))) a.toJson()])));
  r.post('/auctions', (Request req) => guard(() async {
        final me = named(req);
        final b = await body(req);
        return escrowed(me, cards(b['cards']), 0, (own) {
          final a = m.createAuction(me, own,
              startPrice: (b['start'] as num).toInt(),
              increment: (b['inc'] as num?)?.toInt() ?? kMinBidIncrement,
              buyNow: (b['buyNow'] as num?)?.toInt(),
              duration: Duration(hours: (b['hours'] as num?)?.toInt() ?? 24),
              note: b['note'] as String? ?? '');
          econ?.listedOnMarket(me);
          return ok(a.toJson());
        });
      }));
  r.post('/auctions/<id>/bid', (Request req, String id) => guard(() async {
        final me = named(req);
        final b = await body(req);
        final amount = (b['amount'] as num).toInt();
        return paid(me, amount, () => ok(m.bid(me, id, amount).toJson()));
      }));
  r.post('/auctions/<id>/buy', (Request req, String id) => guard(() async {
        final me = named(req);
        final b = await body(req);
        final price = m.auctions[id]?.buyNow ?? 0;
        return paid(me, price, () {
          final got = m.buyAuctionNow(me, id, expectedPrice: (b['price'] as num?)?.toInt());
          econ?.credit(me, cards: got);
          return ok([for (final c in got) c.toJson()]);
        });
      }));
  r.post('/auctions/<id>/cancel', (Request req, String id) => guard(() async {
        final me = pid(req);
        final back = m.cancelAuction(me, id);
        econ?.credit(me, cards: back);
        return ok([for (final c in back) c.toJson()]);
      }));

  // ------------------------------------------------------------ reports
  r.post('/reports', (Request req) => guard(() async {
        final me = named(req);
        final b = await body(req);
        final r = m.fileReport(me, ReportKind.values.byName(b['kind'] as String), '${b['target']}', b['label'] as String? ?? '', b['reason'] as String? ?? '',
            b['details'] as String? ?? '',
            card: b['card'] == null ? null : CardPayload.fromJson(b['card'] as Map<String, dynamic>));
        return ok({'id': r.id});
      }));
  r.get('/blocked-songs', (Request req) => guard(() async => ok(m.blockedSongs.toList())));

  // -------------------------------------------------------------- admin
  String admin(Request req) {
    final id = pid(req);
    if (!admins.contains(id)) throw AuthException('Admins only');
    return id;
  }

  if (econ != null) addEconomyRoutes(r, econ, pid: pid, named: named, admin: admin, body: body, ok: ok, guard: guard);

  r.get('/admin/reports', (Request req) => guard(() async {
        admin(req);
        final all = req.url.queryParameters['all'] == 'true';
        return ok([for (final x in m.reports.reversed) if (all || !x.resolved) x.toJson()]);
      }));
  r.post('/admin/reports/<id>/resolve', (Request req, String id) => guard(() async {
        admin(req);
        m.resolveReport(id);
        return ok({'ok': true});
      }));
  r.post('/admin/songs/<id>/block', (Request req, String id) => guard(() async {
        admin(req);
        final b = await body(req);
        m.setSongBlocked(int.parse(id), b['blocked'] as bool? ?? true);
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
        final me = named(req);
        if (econ != null && econ.active(me) && (econ.accounts[me]!.bits < kShowcaseBits)) {
          throw MarketException('A showcase costs $kShowcaseBits bits');
        }
        final s = m.setShowcase(
            me,
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
        econ?.chargeBits(me, kShowcaseBits, 'A showcase');
        return ok(s.toJson());
      }));
  r.post('/showcases/me/remove', (Request req) => guard(() async {
        m.removeShowcase(pid(req));
        return ok({'ok': true});
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

/// Limits against floods: 300 requests a minute per player (by sign-in
/// token or player id), and 1,200 per network address (players at home on
/// one connection share an address).
Middleware _rateLimit() {
  final hits = <String, (int, int)>{}; // key → (window start ms, count)
  bool over(String key, int limit, int now) {
    final (start, n) = hits[key] ?? (now, 0);
    final fresh = now - start > 60000;
    final count = fresh ? 1 : n + 1;
    hits[key] = (fresh ? now : start, count);
    return count > limit;
  }

  return (inner) => (req) async {
        final info = req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final ip = req.headers['x-forwarded-for']?.split(',').first.trim() ?? info?.remoteAddress.address ?? '?';
        final who = req.headers['authorization'] ?? req.headers['x-player-id'];
        final now = DateTime.now().millisecondsSinceEpoch;
        if (hits.length > 50000) hits.removeWhere((_, v) => now - v.$1 > 60000);
        final tooMany = over('ip:$ip', 1200, now) | (who != null && over('p:$who', 300, now));
        if (tooMany) return Response(429, body: jsonEncode({'error': 'Too many requests — slow down'}));
        return inner(req);
      };
}
