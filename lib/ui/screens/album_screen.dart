import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../game/quests.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'artist_screen.dart';
import 'card_detail_screen.dart';

/// Album page: official track order, which tracks you own, and the album
/// completion quest.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key, required this.albumId});
  final int albumId;
  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  AlbumInfo? _album;
  String? _error;

  @override
  void initState() {
    super.initState();
    GameScope.read(context).catalog.albumDetails(widget.albumId).then(
          (a) => mounted ? setState(() => _album = a) : null,
          onError: (Object e) => mounted ? setState(() => _error = '$e') : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final a = _album;
    if (a == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: _error == null ? const CircularProgressIndicator() : Text('Could not load album.\n$_error', textAlign: TextAlign.center)),
      );
    }
    final tracks = [for (final id in a.trackIds) ?g.catalog.songs[id]];
    final owned = tracks.where((t) => g.collection.ownsSong(t.id)).length;
    final top = tracks.isEmpty ? null : (tracks.toList()..sort((x, y) => y.rank.compareTo(x.rank))).first;
    final quest = top == null ? null : QuestBoard.album(a, top.id);
    if (quest != null) g.updateAlbumQuest(quest, owned);
    return Scaffold(
      appBar: AppBar(title: Text(a.title, overflow: TextOverflow.ellipsis)),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Art(a.cover(500), size: 130, radius: 10, decodeSize: 400),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                InkWell(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: a.artistId, name: a.artistName))),
                  child: Text(a.artistName, style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700)),
                ),
                Text('${a.recordType.toUpperCase()} • ${a.year} • ${tracks.length} tracks', style: const TextStyle(color: Colors.white54)),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: tracks.isEmpty ? 0 : owned / tracks.length, minHeight: 6, borderRadius: BorderRadius.circular(3)),
                const SizedBox(height: 4),
                Text('$owned / ${tracks.length} collected', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: tracks.isEmpty ? null : () => g.audio.playQueue([for (final t in tracks) t.id], name: a.title),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play previews'),
                ),
              ]),
            ),
          ]),
        ),
        if (quest != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: const Icon(Icons.emoji_events, color: kAccent),
              title: Text(quest.title),
              subtitle: Text(quest.description),
              trailing: g.questClaimed(quest)
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : FilledButton(
                      onPressed: g.questDone(quest)
                          ? () {
                              final c = g.claimQuest(quest);
                              if (c != null) {
                                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: c.uid)));
                              }
                            }
                          : null,
                      child: const Text('Claim'),
                    ),
            ),
          ),
        const SizedBox(height: 8),
        for (var i = 0; i < tracks.length; i++)
          Builder(builder: (context) {
            final t = tracks[i];
            final best = g.collection.bestCopyOf(t.id);
            return ListTile(
              leading: SizedBox(
                width: 28,
                child: Center(child: Text('${i + 1}', style: TextStyle(color: best == null ? Colors.white38 : rarityColor(best.rarity), fontWeight: FontWeight.w800))),
              ),
              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: best == null ? Colors.white54 : Colors.white)),
              subtitle: best == null
                  ? Text(_dur(t.duration), style: const TextStyle(color: Colors.white38))
                  : RarityLabel(best.rarity, shiny: best.shiny, fontSize: 11),
              trailing: IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => g.audio.playQueue([for (final x in tracks) x.id], start: i, name: a.title)),
              onTap: best == null ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: best.uid))),
            );
          }),
        const SizedBox(height: 32),
      ]),
    );
  }

  String _dur(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
