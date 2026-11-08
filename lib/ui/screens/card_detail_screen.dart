import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/collection.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'artist_screen.dart';
import 'album_screen.dart';

class CardDetailScreen extends StatelessWidget {
  const CardDetailScreen({super.key, required this.uid});
  final int uid;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final card = g.collection.byUid(uid);
    if (card == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('You no longer own this card.')));
    }
    final s = card.song;
    final payload = card.toPayload();
    final w = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(card.favorite ? Icons.favorite : Icons.favorite_border, color: card.favorite ? Colors.pinkAccent : null),
            onPressed: () => g.collection.setFavorite(uid, !card.favorite),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(child: SongCardView(song: s, rarity: card.rarity, shiny: card.shiny, width: w.clamp(200, 340) * 0.85)),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          FilledButton.icon(
            onPressed: () => g.audio.playOne(s.id),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play preview'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: () => _addToPlaylist(context, uid),
            icon: const Icon(Icons.playlist_add),
            label: const Text('Playlist'),
          ),
        ]),
        const SizedBox(height: 18),
        _InfoRow('Collected', '${card.acquiredAt.toLocal()}'.split('.').first),
        _InfoRow('Source', switch (card.source) {
          CardSource.wild => 'Caught in the wild',
          CardSource.pack => 'Song pack',
          CardSource.quest => 'Quest reward',
          CardSource.market => 'Bought on the market',
          CardSource.trade => 'Trade',
          CardSource.debug => 'Debug generator',
        }),
        _InfoRow('Copies owned', '${g.collection.copiesOf(s.id)}'),
        _InfoRow('Est. market value', '${formatNumber(payload.fair)} coins'),
        _InfoRow('Quick-sell value', '${quickSellValue(card.rarity, card.shiny)} coins'),
        const Divider(height: 28),
        ListTile(
          leading: const Icon(Icons.person),
          title: Text(s.artistName),
          subtitle: const Text('Artist • discography'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: s.artistId, name: s.artistName))),
        ),
        ListTile(
          leading: const Icon(Icons.album),
          title: Text(s.albumTitle),
          subtitle: const Text('Album • track list'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: s.albumId))),
        ),
        ListTile(
          leading: Icon(g.profile.showcaseCards.contains(uid) ? Icons.star : Icons.star_border),
          title: Text(g.profile.showcaseCards.contains(uid) ? 'Remove from showcase' : 'Add to showcase'),
          onTap: () {
            final p = g.profile;
            if (!p.showcaseCards.remove(uid)) {
              if (p.showcaseCards.length >= 24) {
                g.toast('Showcase is full (24 cards)');
                return;
              }
              p.showcaseCards.add(uid);
            }
            p.changed();
          },
        ),
        const Divider(height: 28),
        FilledButton.tonalIcon(
          onPressed: () => showListDialog(context, uid),
          icon: const Icon(Icons.sell),
          label: const Text('Sell on player market'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () async {
            final v = quickSellValue(card.rarity, card.shiny);
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Quick sell?'),
                content: Text('Sell "${s.title}" (${card.rarity.label}${card.shiny ? ', Shiny' : ''}) to the game for $v coins?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sell')),
                ],
              ),
            );
            if (ok == true && context.mounted) {
              g.quickSell(uid);
              g.toast('Sold for $v coins');
              Navigator.pop(context);
            }
          },
          icon: const Icon(Icons.monetization_on_outlined),
          label: const Text('Quick sell to the game'),
        ),
      ]),
    );
  }

  static Future<void> _addToPlaylist(BuildContext context, int uid) async {
    final g = GameScope.read(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Add to playlist', style: TextStyle(fontWeight: FontWeight.w800))),
          for (final p in g.profile.playlists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(p.name),
              subtitle: Text('${p.cardUids.length} songs'),
              trailing: p.cardUids.contains(uid) ? const Icon(Icons.check) : null,
              onTap: () {
                g.addToPlaylist(p, uid);
                Navigator.pop(ctx);
                g.toast('Added to ${p.name}');
              },
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist…'),
            onTap: () async {
              Navigator.pop(ctx);
              final name = await promptText(context, 'New playlist', 'Playlist name');
              if (name != null && name.isNotEmpty) {
                final p = g.createPlaylist(name);
                g.addToPlaylist(p, uid);
                g.toast('Added to $name');
              }
            },
          ),
        ]),
      ),
    );
  }
}

/// Dialog for listing a card on the market.
Future<void> showListDialog(BuildContext context, int uid) async {
  final g = GameScope.read(context);
  final card = g.collection.byUid(uid);
  if (card == null) return;
  final payload = card.toPayload();
  final price = TextEditingController(text: '${suggestedPrice(payload)}');
  var trades = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('List on market'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${card.song.title} — ${card.song.artistName}'),
          RarityLabel(card.rarity, shiny: card.shiny),
          const SizedBox(height: 12),
          TextField(
            controller: price,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Price (coins)', prefixIcon: Icon(kCoinIcon, color: kCoinColor)),
          ),
          const SizedBox(height: 4),
          Text('Suggested: ${suggestedPrice(payload)}  •  Est. value ${payload.fair}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: trades,
            onChanged: (v) => set(() => trades = v),
            title: const Text('Accept trade offers'),
          ),
          const Text('The card is held by the market until it sells or you cancel.', style: TextStyle(fontSize: 12, color: Colors.white54)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('List it')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final p = int.tryParse(price.text.trim());
  if (p == null || p < 1) {
    g.toast('Enter a valid price');
    return;
  }
  try {
    await g.listCard(uid, p, trades: trades);
    g.toast('Listed for $p coins');
    if (context.mounted && Navigator.canPop(context)) Navigator.pop(context);
  } catch (e) {
    g.toast('$e');
  }
}

Future<String?> promptText(BuildContext context, String title, String hint, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.k, this.v);
  final String k;
  final String v;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 140, child: Text(k, style: const TextStyle(color: Colors.white54))),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}
