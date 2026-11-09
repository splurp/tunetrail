import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../data/samples.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/edition_views.dart';
import '../widgets/net_image.dart';

/// Edition Checker: look up any song and see whether its Canvas, Sample or
/// Live edition has been found anywhere, which serial numbers exist, and
/// what it shows (music video or cover art; the sampled record; live
/// footage).
class CanvasCheckerScreen extends StatefulWidget {
  const CanvasCheckerScreen({super.key});
  @override
  State<CanvasCheckerScreen> createState() => _CanvasCheckerScreenState();
}

class _CanvasCheckerScreenState extends State<CanvasCheckerScreen> {
  final _q = TextEditingController();
  List<Song> _results = [];
  Edition _edition = Edition.canvas;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    final g = GameScope.read(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await g.api.searchTracks(q, limit: 30);
      if (!mounted) return;
      setState(() {
        _results = r;
        _error = r.isEmpty ? 'No songs found' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed — check your connection');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edition Checker')),
      body: ContentWidth(
        maxWidth: 800,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: _q,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search any song',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _loading
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: SegmentedButton<Edition>(
              segments: [
                for (final e in const [Edition.canvas, Edition.sample, Edition.live])
                  ButtonSegment(value: e, label: Text(e.label), icon: Icon(editionIcon(e), size: 18)),
              ],
              selected: {_edition},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _edition = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text(
              switch (_edition) {
                Edition.sample => 'Sample editions exist only for songs built on a famous sample — at most ${Edition.sample.maxSerials} copies each, numbered in the order they are found.',
                Edition.live => 'Live editions exist only for songs with live-performance footage — at most ${Edition.live.maxSerials} copies each, numbered in the order they are found.',
                _ => 'Every song has at most ${Edition.canvas.maxSerials} Canvas copies in the whole game, numbered in the order they are found.',
              },
              style: const TextStyle(fontSize: 12, color: kTextTertiary),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: kTextSecondary))),
          Expanded(
            child: Builder(builder: (context) {
              // Before a search, the Sample tab lists every song that has one.
              final list = _results.isEmpty && _edition == Edition.sample ? [for (final x in SampleLibrary.all) x.song] : _results;
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => _Row(key: ValueKey('${list[i].id}-${_edition.name}'), song: list[i], edition: _edition),
              );
            }),
          ),
        ]),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({super.key, required this.song, required this.edition});
  final Song song;
  final Edition edition;
  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  int? _left;

  /// Canvas: has a music video. Live: has live footage. Sample: in the
  /// sample library.
  bool? _media;

  Edition get _e => widget.edition;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_left != null || _media != null) return;
    final g = GameScope.read(context);
    final s = widget.song;
    if (_e == Edition.sample) {
      _media = SampleLibrary.has(s.id);
      if (_media == false) return; // no Sample edition can exist
    }
    g.market.serialsLeft(s.id, _e).then((n) {
      if (mounted) setState(() => _left = n);
    }).catchError((_) {});
    if (_e == Edition.sample) return;
    final live = _e == Edition.live;
    final known = live ? g.movies.hasLive(s.id) : g.movies.hasMovie(s.id);
    if (known != null) {
      _media = known;
    } else {
      (live ? g.movies.liveClipFor(s) : g.movies.clipFor(s)).then((c) {
        if (mounted) setState(() => _media = c != null);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.song;
    final e = _e;
    final impossible = (e == Edition.sample || e == Edition.live) && _media == false;
    final left = _left;
    final found = left == null ? null : e.maxSerials - left;
    final status = impossible
        ? (e == Edition.sample ? 'No Sample edition for this song' : 'No live footage — no Live edition can drop')
        : found == null
        ? 'Checking…'
        : found == 0
        ? 'Not found yet · all ${e.maxSerials} still out there'
        : 'Found: ${found == 1 ? '#1' : '#1–#$found'} · $left left';
    final sample = e == Edition.sample ? SampleLibrary.of(s.id) : null;
    final kind = switch (e) {
      Edition.canvas => _media == null ? '' : (_media! ? ' · Music video' : ' · Cover art'),
      Edition.sample => sample == null ? '' : ' · Samples ${sample.source.title}',
      Edition.live => _media == true ? ' · Live footage' : '',
      Edition.standard => '',
    };
    return ListTile(
      leading: Art(s.cover(120), size: 48, radius: 6),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${s.artistName}\n$status$kind', maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: Icon(editionIcon(e), color: found != null && found > 0 ? editionColor(e) : kTextTertiary),
      onTap: impossible
          ? null
          : () => showDialog<void>(
                context: context,
                builder: (ctx) => Dialog(
                  backgroundColor: Colors.transparent,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SongCardView(song: s, rarity: GameScope.read(context).catalog.rarityOf(s), shiny: false, edition: e, width: 280),
                    const SizedBox(height: 12),
                    Text(status, style: const TextStyle(color: Colors.white)),
                    if (e == Edition.canvas && _media != null)
                      Text(_media! ? 'Its canvas is the music video' : 'No music video — its canvas is the cover art', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
                ),
              ),
    );
  }
}
