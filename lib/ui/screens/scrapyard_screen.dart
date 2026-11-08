import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../app.dart';
import '../widgets/cards.dart';
import 'collection_screen.dart';

/// Scrap unwanted songs for coins. More-streamed (and rarer, and shiny)
/// songs are worth more scrap.
class ScrapyardScreen extends StatefulWidget {
  const ScrapyardScreen({super.key});
  @override
  State<ScrapyardScreen> createState() => _ScrapyardScreenState();
}

class _ScrapyardScreenState extends State<ScrapyardScreen> {
  final List<int> _selected = [];
  static const _max = 2000;

  void _selectDuplicates({Rarity? maxRarity}) {
    final g = GameScope.read(context);
    final c = g.collection;
    final best = <int, (int, int)>{}; // songId → (score, uid)
    final all = <(int, int, int, int)>[]; // songId, score, uid, rarity
    for (var i = 0; i < c.length; i++) {
      final sid = c.songIdAt(i);
      final score = c.rarityAt(i) * 2 + (c.shinyAt(i) ? 1 : 0);
      final uid = c.uidAt(i);
      all.add((sid, score, uid, c.rarityAt(i)));
      final b = best[sid];
      if (b == null || score > b.$1) best[sid] = (score, uid);
    }
    final pinned = {...g.profile.showcaseCards, for (final p in g.profile.playlists) ...p.cardUids};
    setState(() {
      _selected
        ..clear()
        ..addAll([
          for (final (sid, _, uid, r) in all)
            if (best[sid]!.$2 != uid && !pinned.contains(uid) && (maxRarity == null || r <= maxRarity.index)) uid
        ].take(_max));
    });
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final cards = [for (final u in _selected) ?g.collection.byUid(u)];
    final total = cards.fold<int>(0, (a, c) => a + g.scrapValueOf(c));
    return Scaffold(
      appBar: AppBar(title: const Text('Scrapyard')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(16), border: Border.all(color: kOutline)),
            child: const Row(children: [
              Icon(Icons.recycling_rounded, color: kAccent),
              SizedBox(width: 12),
              Expanded(
                child: Text('Turn songs you don’t want into coins. The more streams a song has, the more it’s worth. Rarity and shiny boost the payout.',
                    style: TextStyle(color: kTextSecondary, fontSize: 13)),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Choose songs'),
              onPressed: () async {
                final picked = await pickCards(context, title: 'Pick songs to scrap', max: 500, exclude: _selected.toSet());
                if (picked != null) setState(() => _selected.addAll(picked));
              },
            ),
            ActionChip(label: const Text('All duplicates'), onPressed: () => _selectDuplicates()),
            ActionChip(label: const Text('Common & Uncommon duplicates'), onPressed: () => _selectDuplicates(maxRarity: Rarity.uncommon)),
            if (_selected.isNotEmpty) ActionChip(label: const Text('Clear'), onPressed: () => setState(_selected.clear)),
          ]),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Duplicate picks keep your best copy of every song and skip songs in playlists or your showcase.',
              style: TextStyle(fontSize: 11, color: kTextTertiary)),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: cards.isEmpty
              ? const Center(child: Text('Nothing selected', style: TextStyle(color: kTextTertiary)))
              : ListView.builder(
                  itemCount: cards.length,
                  itemExtent: 58,
                  itemBuilder: (_, i) {
                    final c = cards[i];
                    return CardRow(
                      song: c.song,
                      rarity: c.rarity,
                      shiny: c.shiny,
                      edition: c.edition,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(width: 6),
                        Text('${g.scrapValueOf(c)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        IconButton(icon: const Icon(Icons.close, size: 16, color: kTextTertiary), onPressed: () => setState(() => _selected.remove(c.uid))),
                      ]),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.recycling_rounded),
                label: Text(cards.isEmpty ? 'Select songs to scrap' : 'Scrap ${formatNumber(cards.length)} for ${formatNumber(total)} coins'),
                onPressed: cards.isEmpty
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Scrap songs?'),
                            content: Text('Scrap ${cards.length} song(s) for ${formatNumber(total)} coins. This can’t be undone.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Scrap')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          final got = g.scrap(_selected);
                          g.toast('Scrapped ${cards.length} songs for ${formatNumber(got)} coins');
                          setState(_selected.clear);
                        }
                      },
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
