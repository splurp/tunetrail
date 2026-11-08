import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'artist_screen.dart';

/// Pick any number of favourite artists. They're shown on your profile and
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
        SectionLabel('Your favourites  ${favs.length}'),
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

/// Collapsible "Favourite artists" tab: a header with the count that opens
/// into a scrollable list of every favourite.
class FavoriteArtistsTab extends StatefulWidget {
  const FavoriteArtistsTab({super.key, required this.artists, this.onEdit, this.initiallyOpen = false});
  final List<FavoriteArtist> artists;
  final VoidCallback? onEdit;
  final bool initiallyOpen;
  @override
  State<FavoriteArtistsTab> createState() => _FavoriteArtistsTabState();
}

class _FavoriteArtistsTabState extends State<FavoriteArtistsTab> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final a = widget.artists;
    return Container(
      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(16), border: Border.all(color: kOutline)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(children: [
              const Icon(Icons.favorite, size: 18, color: kAccent),
              const SizedBox(width: 10),
              const Text('Favourite artists', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${a.length}', style: const TextStyle(color: kTextTertiary)),
              const Spacer(),
              if (widget.onEdit != null) TextButton(onPressed: widget.onEdit, child: Text(a.isEmpty ? 'Add' : 'Edit')),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more, color: kTextSecondary),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : a.isEmpty
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Align(alignment: Alignment.centerLeft, child: Text('No favourites yet.', style: TextStyle(color: kTextTertiary))),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 6),
                    itemCount: a.length,
                    itemBuilder: (context, i) => ListTile(
                      dense: true,
                      leading: Art(artistPicUrl(a[i].picMd5), size: 36, circle: true),
                      title: Text(a[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right, size: 18, color: kTextTertiary),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: a[i].id, name: a[i].name))),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}
