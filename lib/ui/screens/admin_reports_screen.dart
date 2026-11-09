import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/showcase_strip.dart';
import 'player_screen.dart';

/// Admin build only: reports from players, with actions.
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});
  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _all = false;
  Future<List<Report>>? _f;

  void _load() => setState(() => _f = GameScope.read(context).market.adminReports(all: _all));

  Future<void> _act(Future<void> Function() f, String done) async {
    final g = GameScope.read(context);
    try {
      await f();
      g.toast(done);
    } catch (e) {
      g.toast('$e');
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    _f ??= g.market.adminReports(all: _all);
    return Scaffold(
      appBar: AppBar(title: const Text('Reports'), actions: [
        Row(children: [
          const Text('Resolved', style: TextStyle(fontSize: 13)),
          Switch(value: _all, onChanged: (v) => setState(() {
                _all = v;
                _f = null;
              })),
        ]),
      ]),
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: FutureBuilder<List<Report>>(
          future: _f,
          builder: (context, snap) {
            if (snap.hasError) return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}'))]);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) return ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Text('No open reports.', textAlign: TextAlign.center))]);
            return ListView(padding: const EdgeInsets.all(12), children: [
              for (final r in list)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(r.kind == ReportKind.song ? Icons.music_note : Icons.person, size: 18),
                        const SizedBox(width: 6),
                        Expanded(child: Text(r.targetLabel, style: const TextStyle(fontWeight: FontWeight.w700))),
                        if (r.resolved) const Text('resolved', style: TextStyle(color: kTextTertiary, fontSize: 12)),
                      ]),
                      Text('${r.reason} · by ${r.reporterName} · ${DateTime.fromMillisecondsSinceEpoch(r.createdAt).toLocal().toString().substring(0, 16)}',
                          style: const TextStyle(fontSize: 12, color: kTextSecondary)),
                      if (r.details.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: SelectableText(r.details)),
                      Wrap(spacing: 8, children: [
                        if (r.card != null) TextButton(onPressed: () => showCardFullView(context, r.card!), child: const Text('View card')),
                        if (r.kind == ReportKind.player)
                          TextButton(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(playerId: r.targetId))),
                            child: const Text('Open profile'),
                          ),
                        if (r.kind == ReportKind.song)
                          TextButton(
                            onPressed: () => _act(() => g.market.adminBlockSong(int.parse(r.targetId), true), 'Song blocked'),
                            child: const Text('Block song', style: TextStyle(color: Color(0xFFE5737A))),
                          ),
                        if (!r.resolved) FilledButton.tonal(onPressed: () => _act(() => g.market.adminResolve(r.id), 'Resolved'), child: const Text('Resolve')),
                      ]),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}
