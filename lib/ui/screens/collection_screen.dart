import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/collection.dart';
import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'card_detail_screen.dart';
import 'scrapyard_screen.dart';

class CollectionScreen extends StatelessWidget {
  const CollectionScreen({super.key});
  @override
  Widget build(BuildContext context) => const CollectionBrowser();
}

/// Full-screen card picker (trades, showcases, playlists).
Future<List<int>?> pickCards(BuildContext context, {required String title, int max = 1, Set<int> exclude = const {}}) {
  return Navigator.of(context).push<List<int>>(MaterialPageRoute(
    builder: (_) => CollectionBrowser(pickTitle: title, pickMax: max, exclude: exclude),
  ));
}

/// Virtualised, filterable, sortable view of the whole collection.
///
/// Only the rows on screen are ever materialised, so 100,000+ cards scroll
/// as smoothly as 100. Filtering/sorting runs on packed integer keys (see
/// [CollectionStore.query]).
class CollectionBrowser extends StatefulWidget {
  const CollectionBrowser({super.key, this.pickTitle, this.pickMax = 1, this.exclude = const {}});
  final String? pickTitle;
  final int pickMax;
  final Set<int> exclude;

  bool get picking => pickTitle != null;

  @override
  State<CollectionBrowser> createState() => _CollectionBrowserState();
}

class _CollectionBrowserState extends State<CollectionBrowser> {
  CollectionQuery _q = const CollectionQuery();
  Int32List _rows = Int32List(0);
  int _rowsVersion = -1;
  CollectionQuery? _rowsQuery;
  bool _grid = true;
  final _search = TextEditingController();
  Timer? _debounce;
  final Set<int> _picked = {};
  final _scroll = ScrollController();

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int get _activeFilters =>
      (_q.rarityMask == 0x1F ? 0 : 1) +
      (_q.shinyOnly || _q.normalOnly || _q.editionMask != 0x7 ? 1 : 0) +
      (_q.genres.isEmpty ? 0 : 1) +
      (_q.favoritesOnly ? 1 : 0);

  String get _filterSummary {
    final parts = <String>[
      if (_q.rarityMask != 0x1F) [for (final r in Rarity.values) if ((_q.rarityMask >> r.index) & 1 == 1) r.label].join(', '),
      if (_q.shinyOnly) 'Shiny',
      if (_q.normalOnly) 'Not shiny',
      if (_q.editionMask != 0x7) [for (final e in Edition.values) if ((_q.editionMask >> e.index) & 1 == 1) e.label].join(', '),
      if (_q.genres.isNotEmpty) _q.genres.length == 1 ? genreName(_q.genres.first) : '${_q.genres.length} genres',
      if (_q.favoritesOnly) 'Favourites',
    ];
    return parts.join(' · ');
  }

  void _setQuery(CollectionQuery q) {
    setState(() => _q = q);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Int32List _rowsFor(CollectionStore c) {
    if (_rowsVersion != c.version || !identical(_rowsQuery, _q)) {
      _rows = c.query(_q);
      if (widget.exclude.isNotEmpty) {
        _rows = Int32List.fromList([
          for (final i in _rows)
            if (!widget.exclude.contains(c.uidAt(i))) i
        ]);
      }
      _rowsVersion = c.version;
      _rowsQuery = _q;
    }
    return _rows;
  }

  void _open(CollectionStore c, int index) {
    final card = c.at(index);
    if (widget.picking) {
      setState(() {
        if (!_picked.remove(card.uid)) {
          if (widget.pickMax == 1) _picked.clear();
          if (_picked.length < widget.pickMax) _picked.add(card.uid);
        }
      });
      if (widget.pickMax == 1 && _picked.isNotEmpty) Navigator.pop(context, _picked.toList());
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: card.uid)));
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final c = g.collection;
    final rows = _rowsFor(c);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickTitle ?? 'Collection'),
        actions: [
          if (!widget.picking)
            IconButton(
              tooltip: 'Scrapyard',
              icon: const Icon(Icons.recycling_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ScrapyardScreen())),
            ),
          IconButton(
            tooltip: _q.uniqueSongs ? 'Showing best copy of each song' : 'Showing every copy',
            icon: Icon(_q.uniqueSongs ? Icons.filter_1 : Icons.filter_none),
            onPressed: () => _setQuery(_q.copyWith(uniqueSongs: !_q.uniqueSongs)),
          ),
          IconButton(
            tooltip: _grid ? 'List view' : 'Grid view',
            icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          if (widget.picking && widget.pickMax > 1)
            TextButton(
              onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
              child: Text('Done (${_picked.length})'),
            ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Search songs, artists, albums',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _setQuery(_q.copyWith(text: ''));
                      }),
            ),
            onChanged: (v) {
              setState(() {});
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 180), () => _setQuery(_q.copyWith(text: v)));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
          child: FilterDropdown(
            activeCount: _activeFilters,
            summary: _filterSummary,
            onReset: () => _setQuery(_q.copyWith(rarityMask: 0x1F, shinyOnly: false, normalOnly: false, favoritesOnly: false, genres: const {}, editionMask: 0x7)),
            sections: () => [
              FilterSection(
                title: 'Rarity',
                onClear: () => _setQuery(_q.copyWith(rarityMask: 0x1F)),
                options: [
                  for (final r in Rarity.values)
                    FilterOption(
                      label: '${r.label}  ${formatNumber(c.rarityCounts[r.index])}',
                      dot: rarityColor(r),
                      selected: _q.rarityMask != 0x1F && (_q.rarityMask >> r.index) & 1 == 1,
                      onTap: () {
                        var m = _q.rarityMask == 0x1F ? 0 : _q.rarityMask;
                        m ^= 1 << r.index;
                        _setQuery(_q.copyWith(rarityMask: m == 0 ? 0x1F : m));
                      },
                    ),
                ],
              ),
              FilterSection(
                title: 'Variant',
                onClear: () => _setQuery(_q.copyWith(shinyOnly: false, normalOnly: false, editionMask: 0x7)),
                options: [
                  FilterOption(
                    label: '✦ Shiny  ${formatNumber(c.shinyCount)}',
                    selected: _q.shinyOnly,
                    onTap: () => _setQuery(_q.copyWith(shinyOnly: !_q.shinyOnly, normalOnly: false)),
                  ),
                  FilterOption(
                    label: 'Not shiny',
                    selected: _q.normalOnly,
                    onTap: () => _setQuery(_q.copyWith(normalOnly: !_q.normalOnly, shinyOnly: false)),
                  ),
                  for (final e in Edition.values)
                    FilterOption(
                      label: '${e.label}  ${formatNumber(c.editionCounts[e.index])}',
                      selected: _q.editionMask != 0x7 && (_q.editionMask >> e.index) & 1 == 1,
                      onTap: () {
                        var m = _q.editionMask == 0x7 ? 0 : _q.editionMask;
                        m ^= 1 << e.index;
                        _setQuery(_q.copyWith(editionMask: m == 0 ? 0x7 : m));
                      },
                    ),
                ],
              ),
              FilterSection(
                title: 'Genre',
                onClear: () => _setQuery(_q.copyWith(genres: const {})),
                options: [
                  for (final gd in kGenres)
                    FilterOption(
                      label: gd.name,
                      selected: _q.genres.contains(gd.id),
                      onTap: () {
                        final set = {..._q.genres};
                        set.contains(gd.id) ? set.remove(gd.id) : set.add(gd.id);
                        _setQuery(_q.copyWith(genres: set));
                      },
                    ),
                ],
              ),
              FilterSection(
                title: 'Other',
                options: [
                  FilterOption(label: 'Favourites', selected: _q.favoritesOnly, onTap: () => _setQuery(_q.copyWith(favoritesOnly: !_q.favoritesOnly))),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
          child: Row(children: [
            Expanded(
              child: Text(
                '${formatNumber(rows.length)} shown • ${formatNumber(c.length)} cards • ${formatNumber(c.uniqueSongCount)} unique'
                ' • ${(c.lastQueryMicros / 1000).toStringAsFixed(1)} ms',
                style: const TextStyle(fontSize: 11.5, color: kTextTertiary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownButton<CollectionSort>(
              value: _q.sort,
              isDense: true,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: CollectionSort.dateAcquired, child: Text('Date collected')),
                DropdownMenuItem(value: CollectionSort.title, child: Text('Song name')),
                DropdownMenuItem(value: CollectionSort.artist, child: Text('Artist')),
                DropdownMenuItem(value: CollectionSort.album, child: Text('Album')),
                DropdownMenuItem(value: CollectionSort.rarity, child: Text('Rarity')),
                DropdownMenuItem(value: CollectionSort.popularity, child: Text('Popularity')),
              ],
              onChanged: (s) {
                if (s == null) return;
                final natural = s == CollectionSort.title || s == CollectionSort.artist || s == CollectionSort.album;
                _setQuery(_q.copyWith(sort: s, descending: !natural));
              },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(_q.descending ? Icons.arrow_downward : Icons.arrow_upward, size: 18),
              onPressed: () => _setQuery(_q.copyWith(descending: !_q.descending)),
            ),
          ]),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      c.length == 0 ? 'No songs yet.\nHead to the map and catch some!' : 'No cards match these filters.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  interactive: true,
                  thumbVisibility: rows.length > 200,
                  thickness: 8,
                  child: _grid ? _buildGrid(c, rows) : _buildList(c, rows),
                ),
        ),
      ]),
    );
  }

  Widget _buildGrid(CollectionStore c, Int32List rows) => GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.66,
        ),
        itemCount: rows.length,
        addAutomaticKeepAlives: false,
        itemBuilder: (context, i) {
          final card = c.at(rows[i]);
          return CardTile(
            key: ValueKey(card.uid),
            song: card.song,
            rarity: card.rarity,
            shiny: card.shiny,
            edition: card.edition,
            favorite: card.favorite,
            selected: _picked.contains(card.uid),
            badge: _q.uniqueSongs && c.copiesOf(card.song.id) > 1 ? '×${c.copiesOf(card.song.id)}' : null,
            onTap: () => _open(c, rows[i]),
          );
        },
      );

  Widget _buildList(CollectionStore c, Int32List rows) => ListView.builder(
        controller: _scroll,
        itemExtent: 58,
        itemCount: rows.length,
        addAutomaticKeepAlives: false,
        itemBuilder: (context, i) {
          final card = c.at(rows[i]);
          return CardRow(
            key: ValueKey(card.uid),
            song: card.song,
            rarity: card.rarity,
            shiny: card.shiny,
            edition: card.edition,
            selected: _picked.contains(card.uid),
            onTap: () => _open(c, rows[i]),
          );
        },
      );
}
