import 'package:flutter/material.dart';

import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/collection.dart';
import '../../data/samples.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'artist_screen.dart';
import 'album_screen.dart';
import 'listing_composer.dart';

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
            icon: Icon(card.favorite ? Icons.favorite : Icons.favorite_border, color: card.favorite ? kAccent : null),
            onPressed: () => g.collection.setFavorite(uid, !card.favorite),
          ),
        ],
      ),
      body: AdaptivePanes(flex: const [4, 5], panes: [
       [
        Center(
            child: SongCardView(
                song: s,
                rarity: card.rarity,
                shiny: card.shiny,
                edition: card.edition,
                serial: card.serial,
                // On wide screens the card gets its own pane, sized by height.
                width: isWideLayout(context) ? ((MediaQuery.sizeOf(context).height - 200) / 1.5).clamp(260.0, 460.0) : w.clamp(200, 340) * 0.85)),
        const SizedBox(height: 18),
        Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 10, children: [
          if (card.edition == Edition.sample && SampleLibrary.of(s.id) != null)
            ValueListenableBuilder(
              valueListenable: g.samples,
              builder: (context, pb, _) => FilledButton.icon(
                onPressed: () => pb.active && pb.songId == s.id ? g.samples.stop() : g.samples.play(SampleLibrary.of(s.id)!),
                icon: Icon(pb.active && pb.songId == s.id ? Icons.stop : Icons.graphic_eq),
                label: Text(pb.active && pb.songId == s.id ? 'Stop' : 'Play breakdown'),
              ),
            ),
          (card.edition == Edition.sample ? OutlinedButton.icon : FilledButton.icon)(
            onPressed: () => g.audio.playOne(s.id),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play preview'),
          ),
          OutlinedButton.icon(
            onPressed: () => _addToPlaylist(context, uid),
            icon: const Icon(Icons.playlist_add),
            label: const Text('Playlist'),
          ),
        ]),
       ],
       [
        if (!isWideLayout(context)) const SizedBox(height: 18),
        _InfoRow('Collected', '${card.acquiredAt.toLocal()}'.split('.').first),
        _InfoRow('Source', switch (card.source) {
          CardSource.wild => 'Caught in the wild',
          CardSource.pack => 'Song pack',
          CardSource.quest => 'Quest reward',
          CardSource.market => 'Bought on the market',
          CardSource.trade => 'Trade',
          CardSource.debug => 'Debug generator',
        }),
        _InfoRow('Edition', card.edition == Edition.standard ? 'Standard' : '${card.edition.label}${card.serial > 0 ? ' · #${card.serial} of ${card.edition.maxSerials}' : ''}'),
        _InfoRow('Variants of this song owned', '${g.collection.copiesOf(s.id)}'),
        if (card.edition == Edition.sample && SampleLibrary.of(s.id) != null) ...[
          _InfoRow('Samples', '${SampleLibrary.of(s.id)!.source.title} — ${SampleLibrary.of(s.id)!.source.artistName} (${SampleLibrary.of(s.id)!.sourceYear})'),
          if (g.profile.debugEnabled) SampleSyncTuner(songId: s.id),
        ],
        _InfoRow('Est. market value', '${formatNumber(payload.fair)} coins'),
        _InfoRow('Popularity', '${formatNumber(s.rank)} (Deezer score, higher = more played)'),
        _InfoRow('Scrap value', '${g.scrapValueOf(card)} coins'),
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
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                if (await showQuickListSheet(context, uid) && context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.bolt_outlined, size: 18),
              label: const Text('Quick list'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: () async {
                if (await openComposer(context, [uid]) && context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.sell_outlined, size: 18),
              label: const Text('List on market'),
            ),
          ),
        ]),
        if (card.edition == Edition.standard && !card.shiny) ...[
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () async {
            final v = g.scrapValueOf(card);
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Scrap this song?'),
                content: Text('Scrap "${s.title}" (${card.rarity.label}${card.shiny ? ', Shiny' : ''}) for $v coins? This can\'t be undone.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Scrap')),
                ],
              ),
            );
            if (ok == true && context.mounted) {
              g.scrap([uid]);
              g.toast('Scrapped for $v coins');
              Navigator.pop(context);
            }
          },
          icon: const Icon(Icons.recycling_rounded, size: 18),
          label: const Text('Scrap for coins'),
        ),
        ],
       ],
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

/// Debug tool: nudge a Sample edition's alignment (where the passage
/// starts in each preview, and the speed change) and save it locally.
class SampleSyncTuner extends StatefulWidget {
  const SampleSyncTuner({super.key, required this.songId});
  final int songId;
  @override
  State<SampleSyncTuner> createState() => _SampleSyncTunerState();
}

class _SampleSyncTunerState extends State<SampleSyncTuner> {
  late SampleInfo _s = SampleLibrary.of(widget.songId)!;

  void _set(double src, double song) {
    final g = GameScope.read(context);
    final v = (src, song);
    SampleLibrary.overrides[widget.songId] = v;
    g.profile.sampleOverrides[widget.songId] = v;
    g.profile.changed();
    setState(() => _s = SampleLibrary.of(widget.songId)!);
  }

  Widget _row(String label, double value, void Function(double) apply) => Row(children: [
        Expanded(child: Text('$label  ${value >= 0 ? '+' : ''}${(value * 1000).round()} ms', style: const TextStyle(fontSize: 13))),
        for (final d in [-0.05, -0.005, 0.005, 0.05])
          SizedBox(
            width: 50,
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(44, 32)),
              onPressed: () => apply(value + d),
              child: FittedBox(child: Text('${d > 0 ? '+' : ''}${(d * 1000).round()}', maxLines: 1, style: const TextStyle(fontSize: 12))),
            ),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final g = GameScope.read(context);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: kOutline)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sample sync tuner (debug)', style: TextStyle(fontWeight: FontWeight.w700)),
        const Text('Shift either preview if the voices don\'t line up on your device.', style: TextStyle(fontSize: 12, color: kTextTertiary)),
        const SizedBox(height: 6),
        _row('Original', _s.sourceShift, (v) => _set(v.clamp(-2.0, 2.0), _s.songShift)),
        _row('Song', _s.songShift, (v) => _set(_s.sourceShift, v.clamp(-2.0, 2.0))),
        Row(children: [
          TextButton.icon(onPressed: () => g.samples.play(_s), icon: const Icon(Icons.play_arrow), label: const Text('Audition')),
          const Spacer(),
          TextButton(
            onPressed: () {
              SampleLibrary.overrides.remove(widget.songId);
              g.profile.sampleOverrides.remove(widget.songId);
              g.profile.changed();
              setState(() => _s = SampleLibrary.of(widget.songId)!);
            },
            child: const Text('Reset'),
          ),
        ]),
      ]),
    );
  }
}
