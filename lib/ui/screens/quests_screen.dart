import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../game/quests.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'artist_screen.dart';
import 'card_detail_screen.dart';

class QuestsScreen extends StatelessWidget {
  const QuestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Quests'),
          bottom: const TabBar(tabs: [Tab(text: 'Daily'), Tab(text: 'Unlocks'), Tab(text: 'Milestones')]),
        ),
        body: TabBarView(children: [
          _QuestList(quests: g.dailyQuests, header: 'Resets every day at midnight'),
          _QuestList(
            quests: g.unlockQuests,
            header: 'Artist spotlights rotate weekly. Complete them to unlock exclusive Epic & Legendary cards. '
                'Album completion quests live on each album page.',
          ),
          _QuestList(quests: g.milestoneQuests),
        ]),
      ),
    );
  }
}

class _QuestList extends StatelessWidget {
  const _QuestList({required this.quests, this.header});
  final List<Quest> quests;
  final String? header;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (header != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(header!, style: const TextStyle(color: Colors.white54, fontSize: 12))),
      if (quests.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Quests appear once the song catalog has loaded.', textAlign: TextAlign.center)),
      for (final q in quests)
        Builder(builder: (context) {
          final prog = g.questProgress(q).clamp(0, q.target);
          final done = g.questDone(q);
          final claimed = g.questClaimed(q);
          final rewardSong = q.reward.songId == null ? null : g.catalog.songs[q.reward.songId];
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: q.artistId == null
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ArtistScreen(artistId: q.artistId!, name: rewardSong?.artistName ?? 'Artist'))),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  if (q.imageMd5.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Art(q.imageIsArtist ? artistPicUrl(q.imageMd5) : coverUrl(q.imageMd5), size: 52, circle: q.imageIsArtist),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(_icon(q.kind), size: 36, color: done ? Colors.amber : Colors.white54),
                    ),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(q.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(q.description, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: q.target == 0 ? 0 : prog / q.target, minHeight: 5, borderRadius: BorderRadius.circular(3)),
                      const SizedBox(height: 4),
                      Text(
                        '${formatNumber(prog)} / ${formatNumber(q.target)}  •  '
                        '${[
                          if (q.reward.coins > 0) '${formatNumber(q.reward.coins)} coins',
                          if (q.reward.bits > 0) '${q.reward.bits} bits',
                          if (q.reward.xp > 0) '${q.reward.xp} XP',
                          if (q.reward.rarity != null) '${q.reward.rarity!.label} card',
                        ].join(' + ')}',
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  claimed
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : FilledButton(
                          onPressed: done
                              ? () {
                                  final card = g.claimQuest(q);
                                  g.toast('Quest complete: ${q.title}');
                                  if (card != null) {
                                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: card.uid)));
                                  }
                                }
                              : null,
                          child: const Text('Claim'),
                        ),
                ]),
              ),
            ),
          );
        }),
    ]);
  }

  IconData _icon(QuestKind k) => switch (k) {
        QuestKind.walkMeters => Icons.directions_walk,
        QuestKind.openPack => Icons.inventory_2,
        QuestKind.listOnMarket => Icons.storefront,
        QuestKind.catchShiny => Icons.auto_awesome,
        QuestKind.collectionSize => Icons.library_music,
        QuestKind.catchRarePlus => Icons.diamond,
        _ => Icons.music_note,
      };
}
