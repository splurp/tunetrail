import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/edition_views.dart';
import '../widgets/net_image.dart';

/// Canvas Checker: look up any song and see whether its Canvas edition has
/// been found anywhere, which serial numbers exist, and what its canvas is
/// (a music video, or the cover art).
class CanvasCheckerScreen extends StatefulWidget {
  const CanvasCheckerScreen({super.key});
  @override
  State<CanvasCheckerScreen> createState() => _CanvasCheckerScreenState();
}

class _CanvasCheckerScreenState extends State<CanvasCheckerScreen> {
  final _q = TextEditingController();
  List<Song> _results = [];
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
      appBar: AppBar(title: const Text('Canvas Checker')),
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
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Text(
              'Every song has at most ${Edition.canvas.maxSerials} Canvas copies in the whole game, numbered in the order they are found.',
              style: const TextStyle(fontSize: 12, color: kTextTertiary),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: kTextSecondary))),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, i) => _Row(song: _results[i]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({required this.song});
  final Song song;
  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  int? _left;
  bool? _video;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_left != null) return;
    final g = GameScope.read(context);
    g.market.serialsLeft(widget.song.id, Edition.canvas).then((n) {
      if (mounted) setState(() => _left = n);
    }).catchError((_) {});
    final known = g.movies.hasMovie(widget.song.id);
    if (known != null) {
      _video = known;
    } else {
      g.movies.clipFor(widget.song).then((c) {
        if (mounted) setState(() => _video = c != null);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.song;
    final left = _left;
    final found = left == null ? null : Edition.canvas.maxSerials - left;
    final status = found == null
        ? 'Checking…'
        : found == 0
        ? 'Not found yet · all ${Edition.canvas.maxSerials} still out there'
        : 'Found: ${found == 1 ? '#1' : '#1–#$found'} · $left left';
    final kind = _video == null ? '' : (_video! ? ' · Music video' : ' · Cover art');
    return ListTile(
      leading: Art(s.cover(120), size: 48, radius: 6),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${s.artistName}\n$status$kind', maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: Icon(Icons.movie_filter_outlined, color: found != null && found > 0 ? editionColor(Edition.canvas) : kTextTertiary),
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SongCardView(song: s, rarity: GameScope.read(context).catalog.rarityOf(s), shiny: false, edition: Edition.canvas, width: 280),
            const SizedBox(height: 12),
            Text(status, style: const TextStyle(color: Colors.white)),
            Text(_video == null ? '' : (_video! ? 'Its canvas is the music video' : 'No music video — its canvas is the cover art'),
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
