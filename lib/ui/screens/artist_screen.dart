import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'album_screen.dart';

/// Artist profile: picture, top tracks and full discography.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.artistId, required this.name});
  final int artistId;
  final String name;
  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  ArtistInfo? _info;
  List<Song> _top = [];
  List<AlbumInfo> _albums = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cat = GameScope.read(context).catalog;
    try {
      final results = await Future.wait([
        cat.artistDetails(widget.artistId),
        cat.topTracks(widget.artistId),
        cat.discography(widget.artistId, widget.name),
      ]);
      if (!mounted) return;
      setState(() {
        _info = results[0] as ArtistInfo;
        _top = results[1] as List<Song>;
        _albums = results[2] as List<AlbumInfo>;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final info = _info;
    final owned = g.collection.distinctSongsByArtist(widget.artistId);
    final groups = <String, List<AlbumInfo>>{};
    for (final a in _albums) {
      final k = switch (a.recordType) { 'single' => 'Singles', 'ep' => 'EPs', 'compile' => 'Compilations', _ => 'Albums' };
      groups.putIfAbsent(k, () => []).add(a);
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.name), actions: [
        IconButton(
          tooltip: g.isFavoriteArtist(widget.artistId) ? 'Remove from favourites' : 'Add to favourites',
          icon: Icon(g.isFavoriteArtist(widget.artistId) ? Icons.favorite : Icons.favorite_border,
              color: g.isFavoriteArtist(widget.artistId) ? kAccent : null),
          onPressed: () => g.toggleFavoriteArtist(widget.artistId, widget.name, _info?.picMd5 ?? ''),
        ),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load artist.\n$_error', textAlign: TextAlign.center))
              : CustomScrollView(slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Art(info?.picture(500) ?? '', size: 110, circle: true, decodeSize: 300),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(widget.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 4),
                            if (info != null) Text('${formatNumber(info.fans)} fans • ${info.albumCount} releases', style: const TextStyle(color: Colors.white60)),
                            const SizedBox(height: 4),
                            Text('You own $owned of their songs', style: const TextStyle(color: kAccent)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('Top tracks', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                  ),
                  SliverList.builder(
                    itemCount: _top.length.clamp(0, 15),
                    itemBuilder: (context, i) {
                      final s = _top[i];
                      final best = g.collection.bestCopyOf(s.id);
                      return ListTile(
                        leading: Art(s.cover(56), size: 44),
                        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: best == null
                            ? const Text('Not collected', style: TextStyle(color: Colors.white38))
                            : RarityLabel(best.rarity, shiny: best.shiny, fontSize: 11),
                        trailing: IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => g.audio.playQueue([for (final t in _top) t.id], start: i, name: 'Top tracks')),
                      );
                    },
                  ),
                  for (final e in groups.entries) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                        child: Text('${e.key} (${e.value.length})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, childAspectRatio: 0.72, crossAxisSpacing: 10, mainAxisSpacing: 10),
                        itemCount: e.value.length,
                        itemBuilder: (context, i) {
                          final a = e.value[i];
                          return InkWell(
                            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: a.id))),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              LayoutBuilder(builder: (context, box) => Art(a.cover(250), size: box.maxWidth, radius: 8)),
                              const SizedBox(height: 4),
                              Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              Text(a.year, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                            ]),
                          );
                        },
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ]),
    );
  }
}
