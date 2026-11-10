import 'package:flutter/material.dart';

import '../../game/market_service.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'player_screen.dart';

/// Admin build only: accounts the server flagged for possible cheating
/// (impossible travel, throws from too far, inhumanly fast throws, very
/// high perfect-beat rates, oversized imports, many store grants).
class AdminFlagsScreen extends StatefulWidget {
  const AdminFlagsScreen({super.key});
  @override
  State<AdminFlagsScreen> createState() => _AdminFlagsScreenState();
}

class _AdminFlagsScreenState extends State<AdminFlagsScreen> {
  Future<List<dynamic>>? _f;

  Future<List<dynamic>> _fetch() async {
    final m = GameScope.read(context).market;
    if (m is! RemoteMarket) return const [];
    return await m.send('GET', '/admin/flags') as List<dynamic>;
  }

  void _load() => setState(() => _f = _fetch());

  static const _labels = {
    'impossible_travel': 'Impossible travel',
    'throw_out_of_range': 'Threw from too far away',
    'rapid_throws': 'Inhumanly fast throws',
    'perfect_rate': 'Very high perfect-beat rate',
    'big_import': 'Large progress import',
    'many_grants': 'Many store grants',
    'minigame_bits': 'Asked for too many minigame bits',
  };

  Future<void> _clear(String id) async {
    final g = GameScope.read(context);
    try {
      await (g.market as RemoteMarket).send('POST', '/admin/flags/${Uri.encodeComponent(id)}/clear');
      g.toast('Marked as reviewed');
    } catch (e) {
      g.toast('$e');
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    _f ??= _fetch();
    return Scaffold(
      appBar: AppBar(title: const Text('Cheat flags'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: FutureBuilder<List<dynamic>>(
          future: _f,
          builder: (context, snap) {
            if (snap.hasError) return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}'))]);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) {
              return ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Text('No accounts waiting for review.', textAlign: TextAlign.center))]);
            }
            return ListView(padding: const EdgeInsets.all(12), children: [
              for (final raw in list)
                Builder(builder: (context) {
                  final a = raw as Map<String, dynamic>;
                  final id = a['id'] as String;
                  final stats = a['stats'] as Map<String, dynamic>? ?? const {};
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(a['name'] as String? ?? id, style: const TextStyle(fontWeight: FontWeight.w800)),
                        SelectableText(id, style: const TextStyle(fontSize: 11, color: kTextTertiary)),
                        const SizedBox(height: 4),
                        Text('${a['coins']} coins · ${a['bits']} bits · ${a['cards']} cards · '
                            '${stats['caught'] ?? 0} caught · ${stats['perfect'] ?? 0}/${stats['throws'] ?? 0} perfect throws',
                            style: const TextStyle(fontSize: 12, color: kTextSecondary)),
                        const SizedBox(height: 6),
                        for (final f in (a['flags'] as List))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Icon(Icons.warning_amber, size: 16, color: Color(0xFFE5A54B)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${_labels[(f as Map)['k']] ?? f['k']}: ${f['d']} · '
                                  '${DateTime.fromMillisecondsSinceEpoch(f['at'] as int).toLocal().toString().substring(0, 16)}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ]),
                          ),
                        Wrap(spacing: 8, children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(playerId: id))),
                            child: const Text('Open profile'),
                          ),
                          TextButton(onPressed: () => _clear(id), child: const Text('Mark reviewed')),
                        ]),
                      ]),
                    ),
                  );
                }),
            ]);
          },
        ),
      ),
    );
  }
}
