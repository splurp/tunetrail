import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import 'card_detail_screen.dart';
import 'collection_screen.dart';
import 'favorite_artists_screen.dart';
import 'listing_composer.dart';

class MarketScreen extends StatelessWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Market'),
          actions: [
            Padding(padding: const EdgeInsets.only(right: 12), child: CurrencyChip(icon: kCoinIcon, value: g.profile.coins, color: kCoinColor)),
          ],
          bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Browse'),
            Tab(text: 'My listings'),
            Tab(text: 'Trade offers'),
            Tab(text: 'Showcases'),
          ]),
        ),
        body: Column(children: [
          Container(
            width: double.infinity,
            color: kBg,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(g.market.label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ),
          const Expanded(child: TabBarView(children: [_Browse(), _MyListings(), _Offers(), _Showcases()])),
        ]),
      ),
    );
  }
}

// --------------------------------------------------------------- browse
class _Browse extends StatefulWidget {
  const _Browse();
  @override
  State<_Browse> createState() => _BrowseState();
}

class _BrowseState extends State<_Browse> {
  ListingQuery _q = const ListingQuery();
  List<Listing> _items = [];
  bool _loading = false;
  bool _more = true;
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    _items = [];
    _more = true;
    await _page();
  }

  Future<void> _page() async {
    if (_loading || !_more) return;
    final g = GameScope.read(context);
    setState(() => _loading = true);
    try {
      final q = ListingQuery(
        text: _q.text,
        rarities: _q.rarities,
        shinyOnly: _q.shinyOnly,
        tradesOnly: _q.tradesOnly,
        normalOnly: _q.normalOnly,
        genres: _q.genres,
        sort: _q.sort,
        offset: _items.length,
        limit: 50,
        excludeSellerId: g.profile.playerId,
      );
      final res = await g.market.browse(q);
      if (!mounted) return;
      setState(() {
        _items.addAll(res);
        _more = res.length == 50;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _set(ListingQuery q) {
    _q = q;
    _reload();
  }

  ListingQuery _copy({String? text, Set<int>? rarities, bool? shiny, bool? normal, Set<int>? genres, bool? trades, ListingSort? sort}) => ListingQuery(
        text: text ?? _q.text,
        rarities: rarities ?? _q.rarities,
        shinyOnly: shiny ?? _q.shinyOnly,
        normalOnly: normal ?? _q.normalOnly,
        genres: genres ?? _q.genres,
        tradesOnly: trades ?? _q.tradesOnly,
        sort: sort ?? _q.sort,
      );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: TextField(
          decoration: const InputDecoration(
            hintText: 'Search listings',
            prefixIcon: Icon(Icons.search, size: 20),
          ),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () => _set(_copy(text: v)));
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: FilterDropdown(
          activeCount: (_q.rarities.isEmpty ? 0 : 1) + (_q.shinyOnly || _q.normalOnly ? 1 : 0) + (_q.genres.isEmpty ? 0 : 1) + (_q.tradesOnly ? 1 : 0),
          summary: [
            if (_q.rarities.isNotEmpty) [for (final r in Rarity.values) if (_q.rarities.contains(r.index)) r.label].join(', '),
            if (_q.shinyOnly) 'Shiny',
            if (_q.normalOnly) 'Standard',
            if (_q.genres.isNotEmpty) _q.genres.length == 1 ? genreName(_q.genres.first) : '${_q.genres.length} genres',
            if (_q.tradesOnly) 'Trades',
          ].join(' · '),
          onReset: () => _set(ListingQuery(sort: _q.sort, text: _q.text)),
          sections: () => [
            FilterSection(
              title: 'Rarity',
              onClear: () => _set(_copy(rarities: {})),
              options: [
                for (final r in Rarity.values)
                  FilterOption(
                    label: r.label,
                    dot: rarityColor(r),
                    selected: _q.rarities.contains(r.index),
                    onTap: () {
                      final set = {..._q.rarities};
                      set.contains(r.index) ? set.remove(r.index) : set.add(r.index);
                      _set(_copy(rarities: set));
                    },
                  ),
              ],
            ),
            FilterSection(
              title: 'Variant',
              onClear: () => _set(_copy(shiny: false, normal: false)),
              options: [
                FilterOption(label: '✦ Shiny', selected: _q.shinyOnly, onTap: () => _set(_copy(shiny: !_q.shinyOnly, normal: false))),
                FilterOption(label: 'Standard', selected: _q.normalOnly, onTap: () => _set(_copy(normal: !_q.normalOnly, shiny: false))),
              ],
            ),
            FilterSection(
              title: 'Genre',
              onClear: () => _set(_copy(genres: {})),
              options: [
                for (final gd in kGenres)
                  FilterOption(
                    label: gd.name,
                    selected: _q.genres.contains(gd.id),
                    onTap: () {
                      final set = {..._q.genres};
                      set.contains(gd.id) ? set.remove(gd.id) : set.add(gd.id);
                      _set(_copy(genres: set));
                    },
                  ),
              ],
            ),
            FilterSection(
              title: 'Other',
              options: [FilterOption(label: 'Open to trades', selected: _q.tradesOnly, onTap: () => _set(_copy(trades: !_q.tradesOnly)))],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(children: [
          Text('${_items.length}${_more ? '+' : ''} listings', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
          const Spacer(),
          DropdownButton<ListingSort>(
            value: _q.sort,
            isDense: true,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: ListingSort.newest, child: Text('Newest')),
              DropdownMenuItem(value: ListingSort.priceLow, child: Text('Price ↑')),
              DropdownMenuItem(value: ListingSort.priceHigh, child: Text('Price ↓')),
              DropdownMenuItem(value: ListingSort.rarity, child: Text('Rarity')),
            ],
            onChanged: (s) => _set(_copy(sort: s)),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: _error != null && _items.isEmpty
              ? ListView(children: [Padding(padding: const EdgeInsets.all(32), child: Text('Market unavailable: $_error', textAlign: TextAlign.center))])
              : _items.isEmpty && !_loading
                  ? ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Text('No listings found.', textAlign: TextAlign.center))])
                  : ListView.builder(
                      itemCount: _items.length + (_more ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _items.length) {
                          WidgetsBinding.instance.addPostFrameCallback((_) => _page());
                          return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                        }
                        final l = _items[i];
                        return ListingTile(key: ValueKey(l.id), listing: l, onChanged: _reload);
                      },
                    ),
        ),
      ),
    ]);
  }
}

/// An expandable market listing. Collapsed it shows a cover mosaic, the
/// seller, note and folder price; expanded it lists every song with its own
/// price and buy button, plus "buy all" and "offer trade".
class ListingTile extends StatefulWidget {
  const ListingTile({super.key, required this.listing, required this.onChanged, this.mine = false});
  final Listing listing;
  final VoidCallback onChanged;
  final bool mine;
  @override
  State<ListingTile> createState() => _ListingTileState();
}

class _ListingTileState extends State<ListingTile> {
  bool _open = false;
  bool _busy = false;

  Future<void> _run(Future<void> Function() f, String ok) async {
    final g = GameScope.read(context);
    setState(() => _busy = true);
    try {
      await f();
      g.toast(ok);
    } catch (e) {
      g.toast('$e');
    }
    if (mounted) setState(() => _busy = false);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final l = widget.listing;
    final single = l.items.length == 1;
    final first = Song.fromPayload(l.card);
    final title = single ? first.title : '${l.items.length} songs';
    final artists = {for (final c in l.cards) c.artistName}.take(3).join(', ');
    final best = l.cards.reduce((a, b) => (b.rarity.index * 2 + (b.shiny ? 1 : 0)) > (a.rarity.index * 2 + (a.shiny ? 1 : 0)) ? b : a);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(16), border: Border.all(color: _open ? kAccent.withValues(alpha: 0.4) : kOutline)),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              _Mosaic(cards: l.cards.take(4).toList(), folder: !single),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (!single) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.folder_outlined, size: 16, color: kTextSecondary)),
                    Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                  Text(single ? first.artistName : artists, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: kTextSecondary)),
                  const SizedBox(height: 3),
                  Row(children: [
                    RarityLabel(best.rarity, shiny: best.shiny, fontSize: 11),
                    if (!single) const Text('  best', style: TextStyle(fontSize: 11, color: kTextTertiary)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(widget.mine ? (l.acceptsTrades ? 'trades on' : '') : 'by ${l.sellerName}${l.acceptsTrades ? ' · trades' : ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: kTextTertiary)),
                    ),
                  ]),
                  if (l.note.isNotEmpty && !_open)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('“${l.note}”', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: kTextSecondary, fontStyle: FontStyle.italic)),
                    ),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(formatNumber(l.folderPrice), style: const TextStyle(fontWeight: FontWeight.w700, color: kTextPrimary)),
                if (l.discount > 0)
                  Text(formatNumber(l.itemsTotal), style: const TextStyle(fontSize: 11, color: kTextTertiary, decoration: TextDecoration.lineThrough)),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: kTextTertiary),
              ]),
            ]),
          ),
        ),
        if (_open) ...[
          const Divider(height: 1),
          if (l.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.sticky_note_2_outlined, size: 16, color: kTextTertiary),
                const SizedBox(width: 8),
                Expanded(child: Text(l.note, style: const TextStyle(color: kTextSecondary, fontSize: 13))),
              ]),
            ),
          for (final it in l.items)
            CardRow(
              song: Song.fromPayload(it.card),
              rarity: it.card.rarity,
              shiny: it.card.shiny,
              onTap: () => g.audio.playOne(it.card.songId),
              trailing: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: widget.mine
                    ? (single
                        ? Text(formatNumber(it.price), style: const TextStyle(fontWeight: FontWeight.w600))
                        : TextButton(
                            onPressed: _busy ? null : () => _run(() => g.withdrawFromListing(l, it.card.uid), 'Removed from listing'),
                            child: Text('${formatNumber(it.price)} · Remove'),
                          ))
                    : (single
                        ? Text(formatNumber(it.price), style: const TextStyle(fontWeight: FontWeight.w600))
                        : OutlinedButton(
                            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 34)),
                            onPressed: _busy || g.profile.coins < it.price ? null : () => _run(() => g.buyListingItem(l, it), 'Bought ${it.card.title}'),
                            child: Text(formatNumber(it.price)),
                          )),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: widget.mine
                ? Row(children: [
                    Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _run(() => g.cancelListing(l), 'Listing cancelled — songs returned'), child: const Text('Cancel listing'))),
                  ])
                : Row(children: [
                    if (l.acceptsTrades) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          label: const Text('Trade'),
                          onPressed: _busy
                              ? null
                              : () async {
                                  final sent = await composeOffer(context, l);
                                  if (sent == true) widget.onChanged();
                                },
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _busy || g.profile.coins < l.folderPrice
                            ? null
                            : () => _run(() => g.buyListing(l), single ? 'You bought ${l.card.title}!' : 'You bought ${l.items.length} songs!'),
                        child: Text(g.profile.coins < l.folderPrice
                            ? 'Need ${formatNumber(l.folderPrice)}'
                            : single
                                ? 'Buy · ${formatNumber(l.folderPrice)}'
                                : 'Buy all ${l.items.length} · ${formatNumber(l.folderPrice)}'),
                      ),
                    ),
                  ]),
          ),
        ],
      ]),
    );
  }
}

class _Mosaic extends StatelessWidget {
  const _Mosaic({required this.cards, required this.folder});
  final List<CardPayload> cards;
  final bool folder;
  @override
  Widget build(BuildContext context) {
    const size = 56.0;
    if (!folder || cards.length < 2) {
      return Glint(enabled: cards.first.shiny, strength: 0.4, child: Art(Song.fromPayload(cards.first).cover(250), size: size, radius: 10));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: Wrap(children: [
          for (var i = 0; i < 4; i++)
            i < cards.length ? Art(Song.fromPayload(cards[i]).cover(56), size: size / 2, radius: 0) : Container(width: size / 2, height: size / 2, color: kSurface2),
        ]),
      ),
    );
  }
}

/// Offer cards and/or coins (with a note) for a whole trade-enabled listing.
Future<bool?> composeOffer(BuildContext context, Listing l) async {
  final g = GameScope.read(context);
  final uids = await pickCards(context, title: 'Pick up to 20 songs to offer', max: kMaxListingItems);
  if (uids == null || !context.mounted) return false;
  final coinsCtl = TextEditingController(text: '0');
  final noteCtl = TextEditingController();
  final cards = [for (final u in uids) ?g.collection.byUid(u)];
  final value = cards.fold<int>(0, (a, c) => a + c.toPayload().fair);
  final want = l.cards.fold<int>(0, (a, c) => a + c.fair);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Trade offer'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('For ${l.items.length == 1 ? l.card.title : 'all ${l.items.length} songs'} from ${l.sellerName} (est. ${formatNumber(want)})'),
          const SizedBox(height: 8),
          Text('You offer ${cards.length} song(s), est. ${formatNumber(value)}', style: const TextStyle(color: kTextSecondary)),
          const SizedBox(height: 8),
          TextField(controller: coinsCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '+ coins')),
          const SizedBox(height: 8),
          TextField(controller: noteCtl, maxLength: kMaxListingNote, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
          const Text('Offered items are held in escrow until the seller responds.', style: TextStyle(fontSize: 12, color: kTextTertiary)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send offer')),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await g.makeOffer(l, uids, int.tryParse(coinsCtl.text) ?? 0, note: noteCtl.text.trim());
    g.toast('Offer sent to ${l.sellerName}');
    return true;
  } catch (e) {
    g.toast('$e');
    return false;
  }
}

// ---------------------------------------------------------- my listings
class _MyListings extends StatefulWidget {
  const _MyListings();
  @override
  State<_MyListings> createState() => _MyListingsState();
}

class _MyListingsState extends State<_MyListings> {
  Future<List<Listing>>? _f;

  void _load() => setState(() => _f = GameScope.read(context).market.myListings());

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    _f ??= g.market.myListings();
    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: FutureBuilder<List<Listing>>(
        future: _f,
        builder: (context, snap) {
          final list = snap.data ?? const [];
          return ListView(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('List songs (up to 20 per folder)'),
                onPressed: () async {
                  final picked = await pickCards(context, title: 'Pick up to 20 songs to list', max: kMaxListingItems);
                  if (picked != null && picked.isNotEmpty && context.mounted) {
                    await openComposer(context, picked);
                    _load();
                  }
                },
              ),
            ),
            if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
            if (snap.hasError) Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}')),
            if (list.isEmpty && snap.connectionState == ConnectionState.done)
              const Padding(padding: EdgeInsets.all(24), child: Text('You have no active listings.', textAlign: TextAlign.center, style: TextStyle(color: kTextTertiary))),
            for (final l in list) ListingTile(key: ValueKey(l.id), listing: l, mine: true, onChanged: _load),
          ]);
        },
      ),
    );
  }
}

// --------------------------------------------------------------- offers
class _Offers extends StatefulWidget {
  const _Offers();
  @override
  State<_Offers> createState() => _OffersState();
}

class _OffersState extends State<_Offers> {
  Future<List<TradeOffer>>? _f;
  void _load() => setState(() => _f = GameScope.read(context).market.offers());

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    _f ??= g.market.offers();
    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: FutureBuilder<List<TradeOffer>>(
        future: _f,
        builder: (context, snap) {
          final list = snap.data ?? const [];
          final incoming = list.where((o) => o.toId == g.profile.playerId).toList();
          final outgoing = list.where((o) => o.fromId == g.profile.playerId).toList();
          return ListView(padding: const EdgeInsets.all(12), children: [
            if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
            const Text('Incoming', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            if (incoming.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No offers on your listings yet. Enable "Accept trade offers" when listing.', style: TextStyle(color: Colors.white54))),
            for (final o in incoming)
              _OfferCard(
                o: o,
                incoming: true,
                onAccept: () async {
                  try {
                    await g.acceptOffer(o);
                    g.toast('Trade complete!');
                  } catch (e) {
                    g.toast('$e');
                  }
                  _load();
                },
                onDecline: () async {
                  await g.declineOffer(o);
                  _load();
                },
              ),
            const SizedBox(height: 16),
            const Text('Sent', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            if (outgoing.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No pending offers.', style: TextStyle(color: Colors.white54))),
            for (final o in outgoing)
              _OfferCard(
                o: o,
                incoming: false,
                onDecline: () async {
                  await g.declineOffer(o);
                  g.toast('Offer cancelled — items returned');
                  _load();
                },
              ),
          ]);
        },
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.o, required this.incoming, this.onAccept, required this.onDecline});
  final TradeOffer o;
  final bool incoming;
  final VoidCallback? onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(incoming ? '${o.fromName} wants your ${o.requestedLabel}' : 'Your offer for ${o.requestedLabel}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (o.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('“${o.note}”', style: const TextStyle(color: kTextSecondary, fontSize: 13))),
          const SizedBox(height: 6),
          for (final c in o.offeredCards)
            CardRow(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny),
          if (o.offeredCoins > 0) Padding(padding: const EdgeInsets.all(6), child: Text('+ ${formatNumber(o.offeredCoins)} coins', style: const TextStyle(color: kCoinColor))),
          Text('Offer value ≈ ${formatNumber(o.offeredValue)} · requested ≈ ${formatNumber(o.requestedValue)}', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: onDecline, child: Text(incoming ? 'Decline' : 'Cancel offer')),
            if (incoming) FilledButton(onPressed: onAccept, child: const Text('Accept')),
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ showcases
class _Showcases extends StatefulWidget {
  const _Showcases();
  @override
  State<_Showcases> createState() => _ShowcasesState();
}

class _ShowcasesState extends State<_Showcases> {
  Future<List<Showcase>>? _f;
  void _load() => setState(() => _f = GameScope.read(context).market.showcases());

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    _f ??= g.market.showcases();
    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: FutureBuilder<List<Showcase>>(
        future: _f,
        builder: (context, snap) {
          final list = snap.data ?? const [];
          return ListView(padding: const EdgeInsets.all(12), children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.edit),
              label: const Text('Edit & publish my showcase'),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ShowcaseEditor()));
                _load();
              },
            ),
            const SizedBox(height: 8),
            if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
            for (final s in list)
              Card(
                margin: const EdgeInsets.only(top: 10),
                child: InkWell(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShowcaseView(showcase: s))),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(s.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
                        const Icon(Icons.favorite, size: 16, color: kAccent),
                        const SizedBox(width: 4),
                        Text('${s.likes}'),
                      ]),
                      Text('${s.playerName} • ${s.cards.length} cards • ${s.playlists.length} playlists', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 120,
                        child: ListView(scrollDirection: Axis.horizontal, children: [
                          for (final c in s.cards.take(8))
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: SizedBox(width: 78, child: CardTile(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny)),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class ShowcaseView extends StatelessWidget {
  const ShowcaseView({super.key, required this.showcase});
  final Showcase showcase;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final s = showcase;
    return Scaffold(
      appBar: AppBar(title: Text(s.title), actions: [
        IconButton(
          icon: const Icon(Icons.favorite_border),
          onPressed: () async {
            try {
              final n = await g.market.likeShowcase(s.playerId);
              g.toast('Liked! ($n)');
            } catch (e) {
              g.toast('$e');
            }
          },
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text('by ${s.playerName}', style: const TextStyle(color: kTextSecondary)),
        if (s.favoriteArtists.isNotEmpty) ...[
          const SizedBox(height: 12),
          FavoriteArtistsTab(artists: s.favoriteArtists),
        ],
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, childAspectRatio: 0.64, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemCount: s.cards.length,
          itemBuilder: (_, i) {
            final c = s.cards[i];
            return CardTile(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny, onTap: () => g.audio.playOne(c.songId));
          },
        ),
        for (final p in s.playlists) ...[
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text(p.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
            IconButton(
              icon: const Icon(Icons.play_circle),
              onPressed: () {
                for (final c in p.cards) {
                  g.catalog.ensureFromPayload(c);
                }
                g.audio.playQueue([for (final c in p.cards) c.songId], name: '${s.playerName}: ${p.name}');
              },
            ),
          ]),
          for (final c in p.cards) CardRow(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny),
        ],
      ]),
    );
  }
}

class ShowcaseEditor extends StatefulWidget {
  const ShowcaseEditor({super.key});
  @override
  State<ShowcaseEditor> createState() => _ShowcaseEditorState();
}

class _ShowcaseEditorState extends State<ShowcaseEditor> {
  late final TextEditingController _title = TextEditingController(text: GameScope.read(context).profile.showcaseTitle);
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final cards = [for (final u in p.showcaseCards) ?g.collection.byUid(u)];
    return Scaffold(
      appBar: AppBar(title: const Text('My showcase')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Showcase title'),
          onChanged: (v) {
            p.showcaseTitle = v;
            p.changed();
          },
        ),
        const SizedBox(height: 14),
        Row(children: [
          Text('Featured cards (${cards.length}/24)', style: const TextStyle(fontWeight: FontWeight.w800)),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add'),
            onPressed: () async {
              final picked = await pickCards(context, title: 'Pick showcase cards', max: 24 - cards.length, exclude: p.showcaseCards.toSet());
              if (picked != null) {
                p.showcaseCards.addAll(picked);
                p.changed();
              }
            },
          ),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in cards)
            SizedBox(
              width: 92,
              height: 144,
              child: CardTile(
                song: c.song,
                rarity: c.rarity,
                shiny: c.shiny,
                onLongPress: () {
                  p.showcaseCards.remove(c.uid);
                  p.changed();
                },
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: c.uid))),
              ),
            ),
        ]),
        if (cards.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Long-press a card to remove it', style: TextStyle(fontSize: 11, color: Colors.white38))),
        const SizedBox(height: 16),
        const Text('Featured playlists', style: TextStyle(fontWeight: FontWeight.w800)),
        if (p.playlists.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Create playlists from the Profile tab.', style: TextStyle(color: Colors.white54))),
        for (final pl in p.playlists)
          CheckboxListTile(
            value: p.showcasePlaylists.contains(pl.id),
            title: Text(pl.name),
            subtitle: Text('${pl.cardUids.length} songs'),
            onChanged: (v) {
              v == true ? p.showcasePlaylists.add(pl.id) : p.showcasePlaylists.remove(pl.id);
              p.changed();
            },
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.publish),
          label: const Text('Publish showcase'),
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    await g.publishShowcase();
                    g.toast('Showcase published!');
                  } catch (e) {
                    g.toast('$e');
                  }
                  if (mounted) setState(() => _busy = false);
                },
        ),
      ]),
    );
  }
}
