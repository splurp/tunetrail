import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

/// Where the server keeps its state between restarts.
abstract class Store {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> state);
  String get label;

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
}
