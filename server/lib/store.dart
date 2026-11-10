import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

/// Where the server keeps its state between restarts.
abstract class Store {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> state);
  String get label;

  /// Every player's public collection (player id → card JSON list).
  Future<Map<String, List<dynamic>>> loadCollections();

  /// Saves one player's collection.
  Future<void> saveCollection(String playerId, List<dynamic> cards);

  /// The server's song catalogue: songs, and fans per artist.
  Future<(List<SongInfo>, Map<int, int>)> loadCatalog();

  /// Adds/updates catalogue songs and artist fan counts.
  Future<void> saveCatalog(List<SongInfo> songs, Map<int, int> fans);

  /// Every server-side account: its data and its cards.
  Future<List<(Map<String, dynamic>, List<CardPayload>)>> loadAccounts();

  /// Saves an account. [changed] maps card uids to their new card (null =
  /// removed); with [allCards] the stored cards are replaced entirely.
  Future<void> saveAccount(String id, Map<String, dynamic> data, {Map<int, CardPayload?> changed = const {}, List<CardPayload>? allCards, required List<CardPayload> Function() currentCards});

  /// Postgres when [databaseUrl] is set (e.g. a free Supabase or Neon
  /// database), else a JSON file next to the server.
  static Future<Store> open({String? databaseUrl, String filePath = 'market.json'}) async {
    if (databaseUrl != null && databaseUrl.isNotEmpty) return PgStore.connect(databaseUrl);
    return FileStore(filePath);
  }
}

class FileStore implements Store {
  FileStore(this.path);
  final String path;
  @override
  String get label => 'file $path';

  @override
  Future<Map<String, dynamic>?> load() async {
    final f = File(path);
    if (!await f.exists()) return null;
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  }

  @override
  Future<void> save(Map<String, dynamic> state) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(state));
    await tmp.rename(path);
  }

  File get _catalog => File('$path.catalog.jsonl');

  @override
  Future<(List<SongInfo>, Map<int, int>)> loadCatalog() async {
    final songs = <int, SongInfo>{};
    final fans = <int, int>{};
    if (!await _catalog.exists()) return (<SongInfo>[], fans);
    for (final line in await _catalog.readAsLines()) {
      if (line.isEmpty) continue;
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['s'] != null) {
        final s = SongInfo.fromJson(j['s'] as Map<String, dynamic>);
        songs[s.id] = s;
      } else if (j['f'] != null) {
        fans[(j['a'] as num).toInt()] = (j['f'] as num).toInt();
      }
    }
    return (songs.values.toList(), fans);
  }

  @override
  Future<void> saveCatalog(List<SongInfo> songs, Map<int, int> fans) async {
    final sink = _catalog.openWrite(mode: FileMode.append);
    for (final s in songs) {
      sink.writeln(jsonEncode({'s': s.toJson()}));
    }
    fans.forEach((a, f) => sink.writeln(jsonEncode({'a': a, 'f': f})));
    await sink.close();
  }

  Directory get _accounts => Directory('$path.accounts');

  @override
  Future<List<(Map<String, dynamic>, List<CardPayload>)>> loadAccounts() async {
    final out = <(Map<String, dynamic>, List<CardPayload>)>[];
    if (!await _accounts.exists()) return out;
    await for (final f in _accounts.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      out.add((j['data'] as Map<String, dynamic>, [for (final c in (j['cards'] as List? ?? const [])) CardPayload.fromJson(c as Map<String, dynamic>)]));
    }
    return out;
  }

  @override
  Future<void> saveAccount(String id, Map<String, dynamic> data,
      {Map<int, CardPayload?> changed = const {}, List<CardPayload>? allCards, required List<CardPayload> Function() currentCards}) async {
    await _accounts.create(recursive: true);
    final name = sha256.convert(utf8.encode(id)).toString();
    final f = File('${_accounts.path}/$name.json'), tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'data': data, 'cards': [for (final c in allCards ?? currentCards()) c.toJson()]}));
    await tmp.rename(f.path);
  }

  Directory get _collections => Directory('$path.collections');

  @override
  Future<Map<String, List<dynamic>>> loadCollections() async {
    final out = <String, List<dynamic>>{};
    if (!await _collections.exists()) return out;
    await for (final f in _collections.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        out[j['id'] as String] = j['cards'] as List<dynamic>;
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> saveCollection(String playerId, List<dynamic> cards) async {
    await _collections.create(recursive: true);
    // File names come from a hash: player ids never become paths.
    final name = sha256.convert(utf8.encode(playerId)).toString();
    final f = File('${_collections.path}/$name.json'), tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'id': playerId, 'cards': cards}));
    await tmp.rename(f.path);
  }
}

/// The whole market state as one JSONB row. Simple and plenty for the
/// first thousands of players; individual tables come with server-side
/// collections and currency.
class PgStore implements Store {
  PgStore._(this._url);
  final String _url;
  Connection? _conn;

  @override
  String get label => 'postgres';

  static Future<PgStore> connect(String url) async {
    final s = PgStore._(url);
    final c = await s._connection();
    await c.execute('CREATE TABLE IF NOT EXISTS tunetrail_state (id text PRIMARY KEY, data jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())');
    await c.execute('CREATE TABLE IF NOT EXISTS tunetrail_collections (player_id text PRIMARY KEY, cards jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())');
    await c.execute('CREATE TABLE IF NOT EXISTS tunetrail_songs (id bigint PRIMARY KEY, data jsonb NOT NULL)');
    await c.execute('CREATE TABLE IF NOT EXISTS tunetrail_artists (id bigint PRIMARY KEY, fans bigint NOT NULL)');
    await c.execute('CREATE TABLE IF NOT EXISTS tunetrail_accounts (player_id text PRIMARY KEY, data jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())');
    await c.execute('CREATE TABLE IF NOT EXISTS tunetrail_cards (player_id text NOT NULL, uid bigint NOT NULL, data jsonb NOT NULL, PRIMARY KEY (player_id, uid))');
    return s;
  }

  Future<Connection> _connection() async {
    final c = _conn;
    if (c != null && c.isOpen) return c;
    // Hosted databases need TLS.
    final url = _url.contains('sslmode=') ? _url : '$_url${_url.contains('?') ? '&' : '?'}sslmode=require';
    return _conn = await Connection.openFromUrl(url);
  }

  @override
  Future<Map<String, dynamic>?> load() async {
    final rows = await (await _connection()).execute(Sql.named("SELECT data::text FROM tunetrail_state WHERE id = 'market'"));
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first[0] as String) as Map<String, dynamic>;
  }

  @override
  Future<void> save(Map<String, dynamic> state) async {
    await (await _connection()).execute(
      Sql.named("INSERT INTO tunetrail_state (id, data, updated_at) VALUES ('market', @d::jsonb, now()) "
          'ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, updated_at = now()'),
      parameters: {'d': jsonEncode(state)},
    );
  }

  @override
  Future<Map<String, List<dynamic>>> loadCollections() async {
    final rows = await (await _connection()).execute(Sql.named('SELECT player_id, cards::text FROM tunetrail_collections'));
    return {for (final r in rows) r[0] as String: jsonDecode(r[1] as String) as List<dynamic>};
  }

  @override
  Future<void> saveCollection(String playerId, List<dynamic> cards) async {
    // Parameters are sent separately from the SQL text, so ids and card
    // data can never change the query.
    await (await _connection()).execute(
      Sql.named('INSERT INTO tunetrail_collections (player_id, cards, updated_at) VALUES (@id, @c::jsonb, now()) '
          'ON CONFLICT (player_id) DO UPDATE SET cards = EXCLUDED.cards, updated_at = now()'),
      parameters: {'id': playerId, 'c': jsonEncode(cards)},
    );
  }

  @override
  Future<List<(Map<String, dynamic>, List<CardPayload>)>> loadAccounts() async {
    final c = await _connection();
    final cards = <String, List<CardPayload>>{};
    for (final r in await c.execute(Sql.named('SELECT player_id, data::text FROM tunetrail_cards'))) {
      cards.putIfAbsent(r[0] as String, () => []).add(CardPayload.fromJson(jsonDecode(r[1] as String) as Map<String, dynamic>));
    }
    return [
      for (final r in await c.execute(Sql.named('SELECT player_id, data::text FROM tunetrail_accounts')))
        (jsonDecode(r[1] as String) as Map<String, dynamic>, cards[r[0] as String] ?? <CardPayload>[]),
    ];
  }

  @override
  Future<void> saveAccount(String id, Map<String, dynamic> data,
      {Map<int, CardPayload?> changed = const {}, List<CardPayload>? allCards, required List<CardPayload> Function() currentCards}) async {
    final c = await _connection();
    await c.runTx((tx) async {
      await tx.execute(
        Sql.named('INSERT INTO tunetrail_accounts (player_id, data, updated_at) VALUES (@id, @d::jsonb, now()) '
            'ON CONFLICT (player_id) DO UPDATE SET data = EXCLUDED.data, updated_at = now()'),
        parameters: {'id': id, 'd': jsonEncode(data)},
      );
      List<CardPayload> upserts;
      if (allCards != null) {
        await tx.execute(Sql.named('DELETE FROM tunetrail_cards WHERE player_id = @id'), parameters: {'id': id});
        upserts = allCards;
      } else {
        final removed = [for (final e in changed.entries) if (e.value == null) e.key];
        if (removed.isNotEmpty) {
          await tx.execute(
            Sql.named('DELETE FROM tunetrail_cards WHERE player_id = @id AND uid IN (SELECT (x)::bigint FROM jsonb_array_elements_text(@u::jsonb) x)'),
            parameters: {'id': id, 'u': jsonEncode(removed)},
          );
        }
        upserts = [for (final v in changed.values) ?v];
      }
      for (var i = 0; i < upserts.length; i += 500) {
        final batch = upserts.sublist(i, math.min(upserts.length, i + 500));
        await tx.execute(
          Sql.named('INSERT INTO tunetrail_cards (player_id, uid, data) SELECT @id, (x->>\'uid\')::bigint, x FROM jsonb_array_elements(@b::jsonb) x '
              'ON CONFLICT (player_id, uid) DO UPDATE SET data = EXCLUDED.data'),
          parameters: {'id': id, 'b': jsonEncode([for (final card in batch) card.toJson()])},
        );
      }
    });
  }

  @override
  Future<(List<SongInfo>, Map<int, int>)> loadCatalog() async {
    final c = await _connection();
    final songs = [for (final r in await c.execute(Sql.named('SELECT data::text FROM tunetrail_songs'))) SongInfo.fromJson(jsonDecode(r[0] as String) as Map<String, dynamic>)];
    final fans = {for (final r in await c.execute(Sql.named('SELECT id, fans FROM tunetrail_artists'))) (r[0] as int): (r[1] as int)};
    return (songs, fans);
  }

  @override
  Future<void> saveCatalog(List<SongInfo> songs, Map<int, int> fans) async {
    final c = await _connection();
    // In batches, as JSON arrays expanded by Postgres (one round trip each).
    for (var i = 0; i < songs.length; i += 500) {
      final batch = songs.sublist(i, i + 500 > songs.length ? songs.length : i + 500);
      await c.execute(
        Sql.named('INSERT INTO tunetrail_songs (id, data) SELECT (x->>\'id\')::bigint, x FROM jsonb_array_elements(@b::jsonb) x '
            'ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data'),
        parameters: {'b': jsonEncode([for (final s in batch) s.toJson()])},
      );
    }
    if (fans.isNotEmpty) {
      await c.execute(
        Sql.named('INSERT INTO tunetrail_artists (id, fans) SELECT (x->>0)::bigint, (x->>1)::bigint FROM jsonb_array_elements(@b::jsonb) x '
            'ON CONFLICT (id) DO UPDATE SET fans = EXCLUDED.fans'),
        parameters: {'b': jsonEncode([for (final e in fans.entries) [e.key, e.value]])},
      );
    }
  }
}
