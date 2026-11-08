import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'card_detail_screen.dart';
import 'collection_screen.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final lists = g.profile.playlists;
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New playlist'),
        onPressed: () async {
          final n = await promptText(context, 'New playlist', 'Name');
          if (n != null && n.isNotEmpty) g.createPlaylist(n);
        },
      ),
      body: lists.isEmpty
          ? const Center(child: Text('No playlists yet.\nBuild one from songs you own!', textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: lists.length,
              itemBuilder: (context, i) {
                final p = lists[i];
                final first = p.cardUids.isEmpty ? null : g.collection.byUid(p.cardUids.first);
                return ListTile(
                  leading: Art(first?.song.cover(56) ?? '', size: 48),
                  title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${p.cardUids.length} songs'),
                  trailing: IconButton(icon: const Icon(Icons.play_circle), onPressed: p.cardUids.isEmpty ? null : () => g.playPlaylist(p)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlist: p))),
                );
              },
            ),
    );
  }
}

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = playlist;
    final cards = [for (final u in p.cardUids) ?g.collection.byUid(u)];
    return Scaffold(
      appBar: AppBar(title: Text(p.name), actions: [
        IconButton(
          icon: const Icon(Icons.edit),
          onPressed: () async {
            final n = await promptText(context, 'Rename playlist', 'Name', initial: p.name);
            if (n != null && n.isNotEmpty) {
              p.name = n;
              g.profile.changed();
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () {
            g.deletePlaylist(p);
            Navigator.pop(context);
          },
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.playlist_add),
        onPressed: () async {
          final picked = await pickCards(context, title: 'Add songs', max: 200, exclude: p.cardUids.toSet());
          if (picked != null) {
            for (final u in picked) {
              g.addToPlaylist(p, u);
            }
          }
        },
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text('${cards.length} songs • 30-second previews via Deezer', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const Spacer(),
            FilledButton.icon(onPressed: cards.isEmpty ? null : () => g.playPlaylist(p), icon: const Icon(Icons.play_arrow), label: const Text('Play')),
          ]),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: cards.length,
            onReorderItem: (a, b) {
              final u = p.cardUids.removeAt(a);
              p.cardUids.insert(b, u);
              g.profile.changed();
            },
            itemBuilder: (context, i) {
              final c = cards[i];
              return Dismissible(
                key: ValueKey('${p.id}-${c.uid}'),
                direction: DismissDirection.endToStart,
                background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.all(16), child: const Icon(Icons.delete)),
                onDismissed: (_) => g.removeFromPlaylist(p, c.uid),
                child: CardRow(
                  song: c.song,
                  rarity: c.rarity,
                  shiny: c.shiny,
                  onTap: () => g.playPlaylist(p, start: i),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
