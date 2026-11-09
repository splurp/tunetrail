import 'dart:io';

import 'package:tunetrail_core/tunetrail_core.dart';
import 'package:tunetrail_server/catalog.dart';
import 'package:tunetrail_server/store.dart';

Future<void> main(List<String> args) async {
  final store = FileStore(args.first);
  final c = ServerCatalog(store);
  await c.load();
  await c.crawl(chartsOnly: true);
  final pool = c.pool;
  final counts = <Rarity, int>{};
  for (final r in pool.rarities.values) {
    counts[r] = (counts[r] ?? 0) + 1;
  }
  stdout.writeln('songs ${pool.size} rarities $counts');
  final w = WorldSpawner(pool, seed: 123, sampleSongs: kSampleSongs);
  final sp = w.around(40.758, -73.985, nowMs: DateTime.now().millisecondsSinceEpoch);
  for (final s in sp.take(5)) {
    stdout.writeln('${s.id} ${s.song.title} — ${s.song.artistName} ${s.rarity.label}${s.shiny ? ' shiny' : ''}');
  }
  final (again, _) = await store.loadCatalog();
  stdout.writeln('reloaded ${again.length}');
  exit(0);
}
