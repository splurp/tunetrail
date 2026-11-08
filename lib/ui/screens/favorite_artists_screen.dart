import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'artist_screen.dart';

/// Pick up to 10 favourite artists. They're shown on your profile and
/// showcase, and their songs spawn 10× more often for you.
class FavoriteArtistsScreen extends StatefulWidget {
  const FavoriteArtistsScreen({super.key});
  @override
  State<FavoriteArtistsScreen> createState() => _FavoriteArtistsScreenState();
}

class _FavoriteArtistsScreenState extends State<FavoriteArtistsScreen> {
  final _q = TextEditingController();
  List<ArtistInfo> _results = [];
  bool _loading = false;
  final Set<int> _busy = {};

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    final g = GameScope.read(context);
    setState(() => _loading = true);
    try {
      final r = await g.api.searchArtists(q, limit: 20);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      g.toast('Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(int id, String name, String pic) async {
    final g = GameScope.read(context);
    setState(() => _busy.add(id));
    await g.toggleFavoriteArtist(id, name, pic);
    if (mounted) setState(() => _busy.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final favs = g.profile.favoriteArtists;
    return Scaffold(
      appBar: AppBar(title: const Text('Favourite artists')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        const Text('Shown on your profile for other players. Songs by your favourites spawn 10× more often for you.',
            style: TextStyle(color: kTextSecondary, fontSize: 13)),
        SectionLabel('Your favourites  ${favs.length}/$kMaxFavoriteArtists'),
        if (favs.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None yet — search below.', style: TextStyle(color: kTextTertiary))),
        for (final a in favs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Art(artistPicUrl(a.picMd5), size: 44, circle: true),
            title: Text(a.name),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: a.id, name: a.name))),
            trailing: IconButton(
              icon: _busy.contains(a.id) ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.favorite, color: kAccent),
              onPressed: () => _toggle(a.id, a.name, a.picMd5),
            ),
          ),
        const SectionLabel('Add artists'),
        TextField(
          controller: _q,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: 'Search artists',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _loading
                ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
          ),
        ),
        const SizedBox(height: 6),
        for (final a in _results)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Art(a.picture(), size: 44, circle: true),
            title: Text(a.name),
            subtitle: Text('${formatNumber(a.fans)} fans', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
            trailing: IconButton(
              icon: _busy.contains(a.id)
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(g.isFavoriteArtist(a.id) ? Icons.favorite : Icons.favorite_border, color: g.isFavoriteArtist(a.id) ? kAccent : kTextSecondary),
              onPressed: () => _toggle(a.id, a.name, a.picMd5),
            ),
          ),
      ]),
    );
  }
}

/// Horizontal row of favourite artist avatars.
class FavoriteArtistsRow extends StatelessWidget {
  const FavoriteArtistsRow({super.key, required this.artists, this.onAdd});
  final List<FavoriteArtist> artists;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final a in artists)
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: a.id, name: a.name))),
            child: SizedBox(
              width: 76,
              child: Column(children: [
                Art(artistPicUrl(a.picMd5), size: 58, circle: true),
                const SizedBox(height: 6),
                Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: kTextSecondary)),
              ]),
            ),
          ),
        if (onAdd != null)
          GestureDetector(
            onTap: onAdd,
            child: SizedBox(
              width: 76,
              child: Column(children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: kSurface2, border: Border.all(color: kOutline)),
                  child: const Icon(Icons.add, color: kTextSecondary),
                ),
                const SizedBox(height: 6),
                Text(artists.isEmpty ? 'Add' : 'Edit', style: const TextStyle(fontSize: 11, color: kTextSecondary)),
              ]),
            ),
          ),
      ]),
    );
  }
}
