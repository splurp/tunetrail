import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../build_flags.dart';

import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import '../widgets/showcase_strip.dart';
import '../../game/game.dart';
import 'auctions.dart';
import 'canvas_checker_screen.dart';
import 'card_detail_screen.dart';
import 'collection_screen.dart';
import 'listing_composer.dart';
import 'messages_screen.dart';
import 'player_screen.dart';
import 'report_dialogs.dart';

class MarketScreen extends StatelessWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Market'),
          actions: [
            BadgeIcon(
              tooltip: 'Offers',
              icon: Icons.swap_horiz_rounded,
              count: g.newOffers,
              onTap: () {
                g.newOffers.value = 0;
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OffersScreen()));
              },
            ),
            BadgeIcon(
              tooltip: 'Messages',
              icon: Icons.chat_bubble_outline,
              count: g.unreadMessages,
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConversationsScreen())),
            ),
            BadgeIcon(
              tooltip: 'My listings',
              icon: Icons.receipt_long_outlined,
              count: g.newSales,
              onTap: () {
                g.newSales.value = 0;
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MyListingsScreen()));
              },
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: CurrencyChip(icon: kCoinIcon, value: g.profile.coins, color: kCoinColor),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Browse'),
              Tab(text: 'Players'),
              Tab(text: 'Showcases'),
            ],
          ),
        ),
        body: ContentWidth(
          maxWidth: 1000,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                color: kBg,
                padding: const EdgeInsets.only(left: 14, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: kAdminBuild
                          ? Text(
                              g.market.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11, color: Colors.white54),
                            )
                          : const SizedBox(),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.movie_filter_outlined, size: 18),
                      label: const Text('Edition Checker'),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CanvasCheckerScreen())),
                    ),
                  ],
                ),
              ),
              const Expanded(child: TabBarView(children: [_Browse(), _Players(), _Showcases()])),
            ],
          ),
        ),
      ),
    );
  }
}

/// An app-bar icon with a red count badge (new messages, offers, sales).
class BadgeIcon extends StatelessWidget {
  const BadgeIcon({super.key, required this.icon, required this.tooltip, required this.count, required this.onTap});
  final IconData icon;
  final String tooltip;
  final ValueListenable<int> count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: count,
    builder: (context, n, _) => IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Badge(
        isLabelVisible: n > 0,
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        label: Text(n > 99 ? '99+' : '$n'),
        child: Icon(icon),
      ),
    ),
  );
}

/// The player's listings (bump, cancel, list more).
class MyListingsScreen extends StatelessWidget {
  const MyListingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My listings')),
    body: const ContentWidth(maxWidth: 1000, child: _MyListings()),
  );
}

/// Trade offers sent and received.
class OffersScreen extends StatelessWidget {
  const OffersScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offers')),
    body: const ContentWidth(maxWidth: 1000, child: _Offers()),
  );
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
  List<Auction> _auctions = [];
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
    _auctions = [];
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
        editions: _q.editions,
        serials: _q.serials,
        genres: _q.genres,
        sort: _q.sort,
        auctionsOnly: _q.auctionsOnly,
        offset: _items.length,
        limit: 50,
        excludeSellerId: g.profile.playerId,
      );
      // Live auctions come first (all of them on the first page).
      final first = _items.isEmpty && _auctions.isEmpty;
      final auctions = first
          ? await g.market.browseAuctions(
              ListingQuery(
                text: q.text,
                rarities: q.rarities,
                shinyOnly: q.shinyOnly,
                editions: q.editions,
                serials: q.serials,
                genres: q.genres,
                limit: 200,
                excludeSellerId: g.profile.playerId,
              ),
            )
          : const <Auction>[];
      final res = _q.auctionsOnly ? const <Listing>[] : await g.market.browse(q);
      if (!mounted) return;
      setState(() {
        if (first) _auctions = auctions;
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

  ListingQuery _copy({
    String? text,
    Set<int>? rarities,
    bool? shiny,
    bool? normal,
    Set<int>? editions,
    Set<int>? serials,
    Set<int>? genres,
    bool? trades,
    bool? auctions,
    ListingSort? sort,
  }) => ListingQuery(
    text: text ?? _q.text,
    rarities: rarities ?? _q.rarities,
    shinyOnly: shiny ?? _q.shinyOnly,
    normalOnly: normal ?? _q.normalOnly,
    editions: editions ?? _q.editions,
    serials: serials ?? _q.serials,
    genres: genres ?? _q.genres,
    tradesOnly: trades ?? _q.tradesOnly,
    auctionsOnly: auctions ?? _q.auctionsOnly,
    sort: sort ?? _q.sort,
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search listings', prefixIcon: Icon(Icons.search, size: 20)),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => _set(_copy(text: v)));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: FilterDropdown(
            activeCount:
                (_q.rarities.isEmpty ? 0 : 1) +
                (_q.shinyOnly || _q.normalOnly || _q.editions.isNotEmpty ? 1 : 0) +
                (_q.serials.isEmpty ? 0 : 1) +
                (_q.genres.isEmpty ? 0 : 1) +
                (_q.tradesOnly ? 1 : 0) +
                (_q.auctionsOnly ? 1 : 0),
            summary: [
              if (_q.rarities.isNotEmpty)
                [
                  for (final r in Rarity.values)
                    if (_q.rarities.contains(r.index)) r.label,
                ].join(', '),
              if (_q.shinyOnly) 'Shiny',
              if (_q.editions.isNotEmpty)
                [
                  for (final e in Edition.displayOrder)
                    if (_q.editions.contains(e.index)) e.label,
                ].join(', '),
              if (_q.serials.isNotEmpty) 'Serial ${(_q.serials.toList()..sort()).map((n) => '#$n').join(' ')}',
              if (_q.genres.isNotEmpty) _q.genres.length == 1 ? genreName(_q.genres.first) : '${_q.genres.length} genres',
              if (_q.tradesOnly) 'Trades',
              if (_q.auctionsOnly) 'Auctions',
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
                onClear: () => _set(_copy(shiny: false, normal: false, editions: {})),
                options: [
                  FilterOption(
                    label: '✦ Shiny',
                    selected: _q.shinyOnly,
                    onTap: () => _set(_copy(shiny: !_q.shinyOnly, normal: false)),
                  ),
                  for (final e in Edition.displayOrder)
                    FilterOption(
                      label: e.label,
                      selected: _q.editions.contains(e.index),
                      onTap: () {
                        final s = {..._q.editions};
                        s.contains(e.index) ? s.remove(e.index) : s.add(e.index);
                        _set(_copy(editions: s));
                      },
                    ),
                ],
              ),
              FilterSection(
                title: 'Serial number',
                onClear: () => _set(_copy(serials: {})),
                options: [
                  for (var n = 1; n <= Edition.canvas.maxSerials; n++)
                    FilterOption(
                      label: '#$n',
                      selected: _q.serials.contains(n),
                      onTap: () {
                        final s = {..._q.serials};
                        s.contains(n) ? s.remove(n) : s.add(n);
                        // Serials only exist on edition cards.
                        _set(
                          _copy(
                            serials: s,
                            editions: s.isNotEmpty && _q.editions.isEmpty ? {Edition.canvas.index, Edition.sample.index, Edition.live.index} : null,
                          ),
                        );
                      },
                    ),
                ],
              ),
              FilterSection(
                title: 'Genre',
                onClear: () => _set(_copy(genres: {})),
                options: [
                  for (final gd in kDisplayGenres)
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
                options: [
                  FilterOption(
                    label: 'Auctions only',
                    selected: _q.auctionsOnly,
                    onTap: () => _set(_copy(auctions: !_q.auctionsOnly)),
                  ),
                  FilterOption(
                    label: 'Open to trades',
                    selected: _q.tradesOnly,
                    onTap: () => _set(_copy(trades: !_q.tradesOnly)),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Text(
                _q.auctionsOnly
                    ? '${_auctions.length} auctions'
                    : '${_auctions.isEmpty ? '' : '${_auctions.length} auctions · '}${_items.length}${_more ? '+' : ''} listings',
                style: const TextStyle(fontSize: 12, color: kTextTertiary),
              ),
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
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: _error != null && _items.isEmpty
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('Market unavailable: $_error', textAlign: TextAlign.center),
                      ),
                    ],
                  )
                : _items.isEmpty && _auctions.isEmpty && !_loading
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(_q.auctionsOnly ? 'No auctions right now.' : 'No listings found.', textAlign: TextAlign.center),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: _auctions.length + _items.length + (_more && !_q.auctionsOnly ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i < _auctions.length) {
                        final a = _auctions[i];
                        return AuctionTile(key: ValueKey(a.id), auction: a, onChanged: _reload);
                      }
                      i -= _auctions.length;
                      if (i >= _items.length) {
                        WidgetsBinding.instance.addPostFrameCallback((_) => _page());
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final l = _items[i];
                      return ListingTile(key: ValueKey(l.id), listing: l, onChanged: _reload);
                    },
                  ),
          ),
        ),
      ],
    );
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
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _open ? kAccent.withValues(alpha: 0.4) : kOutline),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _Mosaic(cards: l.cards.take(4).toList(), folder: !single),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (!single)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(Icons.folder_outlined, size: 16, color: kTextSecondary),
                              ),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          single ? first.artistName : artists,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: kTextSecondary),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            RarityLabel(best.rarity, shiny: best.shiny, fontSize: 11),
                            if (!single) const Text('  best', style: TextStyle(fontSize: 11, color: kTextTertiary)),
                            const SizedBox(width: 8),
                            Flexible(
                              child: GestureDetector(
                                onTap: widget.mine ? null : () => openPlayer(context, l.sellerId),
                                child: Text(
                                  widget.mine ? (l.acceptsTrades ? 'trades on' : '') : 'by ${l.sellerName}${l.acceptsTrades ? ' · trades' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: kTextTertiary,
                                    decoration: widget.mine ? null : TextDecoration.underline,
                                    decorationColor: kTextTertiary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (l.note.isNotEmpty && !_open)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              '“${l.note}”',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: kTextSecondary, fontStyle: FontStyle.italic),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      CoinPrice(l.folderPrice),
                      if (l.discount > 0)
                        Text(
                          formatNumber(l.itemsTotal),
                          style: const TextStyle(fontSize: 11, color: kTextTertiary, decoration: TextDecoration.lineThrough),
                        ),
                      Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: kTextTertiary),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            const Divider(height: 1),
            if (l.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.sticky_note_2_outlined, size: 16, color: kTextTertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l.note, style: const TextStyle(color: kTextSecondary, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            for (final it in l.items)
              CardRow(
                song: Song.fromPayload(it.card),
                rarity: it.card.rarity,
                shiny: it.card.shiny,
                edition: it.card.edition,
                serial: it.card.serial,
                onTap: () => g.audio.playOne(it.card.songId),
                trailing: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: widget.mine
                      ? (single
                            ? CoinPrice(it.price, style: const TextStyle(fontWeight: FontWeight.w600))
                            : TextButton(
                                onPressed: _busy ? null : () => _run(() => g.withdrawFromListing(l, it.card.uid), 'Removed from listing'),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CoinPrice(it.price, style: const TextStyle(fontWeight: FontWeight.w600)),
                                    const Text(' · Remove'),
                                  ],
                                ),
                              ))
                      : (single
                            ? CoinPrice(it.price, style: const TextStyle(fontWeight: FontWeight.w600))
                            : OutlinedButton(
                                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 34)),
                                onPressed: _busy || g.profile.coins < it.price ? null : () => _run(() => g.buyListingItem(l, it), 'Bought ${it.card.title}'),
                                child: CoinPrice(it.price, style: const TextStyle(fontWeight: FontWeight.w600)),
                              )),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: widget.mine
                  ? Column(
                      children: [
                        Builder(
                          builder: (context) {
                            final now = DateTime.now().millisecondsSinceEpoch;
                            final left = Duration(milliseconds: l.expiresAt - now);
                            final canBump = now >= l.nextBumpAt;
                            final wait = Duration(milliseconds: l.nextBumpAt - now);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                'Expires in ${left.inDays > 0 ? '${left.inDays}d ${left.inHours % 24}h' : '${left.inHours}h ${left.inMinutes % 60}m'}'
                                '${canBump ? '' : ' · bump again in ${wait.inHours > 0 ? '${wait.inHours}h ${wait.inMinutes % 60}m' : '${wait.inMinutes + 1}m'}'}',
                                style: const TextStyle(fontSize: 12, color: kTextTertiary),
                              ),
                            );
                          },
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.tonalIcon(
                                icon: const Icon(Icons.vertical_align_top, size: 18),
                                label: const Text('Bump to top'),
                                onPressed: _busy || DateTime.now().millisecondsSinceEpoch < l.nextBumpAt
                                    ? null
                                    : () => _run(() => g.market.bumpListing(l.id), 'Bumped to the top of the market'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _busy ? null : () => _run(() => g.cancelListing(l), 'Listing cancelled — songs returned'),
                                child: const Text('Cancel listing'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton(
                          tooltip: 'Report a song',
                          icon: const Icon(Icons.flag_outlined, size: 20, color: kTextTertiary),
                          onPressed: () async {
                            final c = l.items.length == 1
                                ? l.card
                                : await showDialog<CardPayload>(
                                    context: context,
                                    builder: (ctx) => SimpleDialog(
                                      title: const Text('Which song?'),
                                      children: [
                                        for (final it in l.items)
                                          SimpleDialogOption(
                                            onPressed: () => Navigator.pop(ctx, it.card),
                                            child: Text('${it.card.title} — ${it.card.artistName}'),
                                          ),
                                      ],
                                    ),
                                  );
                            if (c != null && context.mounted) await showSongReport(context, c);
                          },
                        ),
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
                          child: FilledButton.icon(
                            icon: const Icon(kCoinIcon, size: 16),
                            onPressed: _busy || g.profile.coins < l.folderPrice
                                ? null
                                : () => _run(() => g.buyListing(l), single ? 'You bought ${l.card.title}!' : 'You bought ${l.items.length} songs!'),
                            label: Text(
                              g.profile.coins < l.folderPrice
                                  ? 'Need ${formatNumber(l.folderPrice)}'
                                  : single
                                  ? 'Buy · ${formatNumber(l.folderPrice)}'
                                  : 'Buy all ${l.items.length} · ${formatNumber(l.folderPrice)}',
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ],
      ),
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
      return Glint(
        enabled: cards.first.shiny,
        strength: 0.4,
        child: Art(Song.fromPayload(cards.first).cover(250), size: size, radius: 10),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: Wrap(
          children: [
            for (var i = 0; i < 4; i++)
              i < cards.length
                  ? Art(Song.fromPayload(cards[i]).cover(56), size: size / 2, radius: 0)
                  : Container(width: size / 2, height: size / 2, color: kSurface2),
          ],
        ),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('For ${l.items.length == 1 ? l.card.title : 'all ${l.items.length} songs'} from ${l.sellerName} (est. ${formatNumber(want)})'),
            const SizedBox(height: 8),
            Text('You offer ${cards.length} song(s), est. ${formatNumber(value)}', style: const TextStyle(color: kTextSecondary)),
            const SizedBox(height: 8),
            TextField(
              controller: coinsCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '+ coins'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtl,
              maxLength: kMaxListingNote,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const Text('Offered items are held in escrow until the seller responds.', style: TextStyle(fontSize: 12, color: kTextTertiary)),
          ],
        ),
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

// -------------------------------------------------------------- players
void openPlayer(BuildContext context, String id) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(playerId: id)));

/// Search players by username.
class _Players extends StatefulWidget {
  const _Players();
  @override
  State<_Players> createState() => _PlayersState();
}

class _PlayersState extends State<_Players> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<PlayerSummary> _results = [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final seq = ++_seq;
      if (q.trim().isEmpty) {
        return setState(() {
          _results = const [];
          _error = null;
        });
      }
      setState(() => _loading = true);
      try {
        final r = await GameScope.read(context).market.searchPlayers(q.trim());
        if (mounted && seq == _seq) {
          setState(() {
            _results = r;
            _error = null;
          });
        }
      } catch (e) {
        if (mounted && seq == _seq) setState(() => _error = '$e');
      } finally {
        if (mounted && seq == _seq) setState(() => _loading = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _q,
          onChanged: _search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search players by username',
            prefixIcon: const Icon(Icons.person_search_outlined, size: 20),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 8),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        if (_q.text.trim().isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Find a player to see their profile and collection, make an offer on their songs, or send them a message.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextTertiary),
            ),
          )
        else if (!_loading && _results.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'No players found.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextTertiary),
            ),
          ),
        for (final p in _results)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: ThemeAvatar(themeId: p.theme, name: p.name),
              title: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text('Level ${p.level} · ${formatNumber(p.cards)} songs', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPlayer(context, p.id),
            ),
          ),
      ],
    );
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
  Future<List<Auction>>? _a;

  void _load() => setState(() {
    _f = GameScope.read(context).market.myListings();
    _a = GameScope.read(context).market.myAuctions();
  });

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    _f ??= g.market.myListings();
    _a ??= g.market.myAuctions();
    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: FutureBuilder<List<Listing>>(
        future: _f,
        builder: (context, snap) {
          final list = snap.data ?? const [];
          return ListView(
            children: [
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
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.gavel_rounded),
                  label: const Text('Start an auction'),
                  onPressed: () async {
                    if (await startAuction(context)) _load();
                  },
                ),
              ),
              FutureBuilder<List<Auction>>(
                future: _a,
                builder: (context, as) {
                  final mine = [
                    for (final a in as.data ?? const <Auction>[])
                      if (a.sellerId == g.profile.playerId) a,
                  ];
                  final bidding = [
                    for (final a in as.data ?? const <Auction>[])
                      if (a.highBidderId == g.profile.playerId) a,
                  ];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (mine.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Text('My auctions', style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      for (final a in mine) AuctionTile(key: ValueKey(a.id), auction: a, onChanged: _load),
                      if (bidding.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Text('Winning bids', style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      for (final a in bidding) AuctionTile(key: ValueKey('b${a.id}'), auction: a, onChanged: _load),
                      if (mine.isNotEmpty || bidding.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Text('Listings', style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                    ],
                  );
                },
              ),
              if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
              if (snap.hasError) Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}')),
              if (list.isEmpty && snap.connectionState == ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'You have no active listings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextTertiary),
                  ),
                ),
              for (final l in list) ListingTile(key: ValueKey(l.id), listing: l, mine: true, onChanged: _load),
            ],
          );
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
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
              const Text('Incoming', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (incoming.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No offers yet. Players can make offers on your trade-enabled listings, or on any song in your collection from your profile.',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
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
              if (outgoing.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No pending offers.', style: TextStyle(color: Colors.white54)),
                ),
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
            ],
          );
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => openPlayer(context, incoming ? o.fromId : o.toId),
              child: Text(
                incoming ? '${o.fromName} wants your ${o.requestedLabel}' : 'Your offer for ${o.requestedLabel}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (o.direct)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  incoming ? 'From your collection — accepting hands these songs over:' : 'From their collection:',
                  style: const TextStyle(fontSize: 12, color: kTextTertiary),
                ),
              ),
            if (o.direct)
              for (final c in o.requestedCards.take(6))
                Text(
                  '• ${c.title} — ${c.artistName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: kTextSecondary),
                ),
            if (o.direct && o.requestedCards.length > 6)
              Text('…and ${o.requestedCards.length - 6} more', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
            if (o.direct) const SizedBox(height: 4),
            if (o.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('“${o.note}”', style: const TextStyle(color: kTextSecondary, fontSize: 13)),
              ),
            const SizedBox(height: 6),
            for (final c in o.offeredCards) CardRow(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny, edition: c.edition, serial: c.serial),
            if (o.offeredCoins > 0)
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text('+ ${formatNumber(o.offeredCoins)} coins', style: const TextStyle(color: kCoinColor)),
              ),
            Text(
              'Offer value ≈ ${formatNumber(o.offeredValue)} · requested ≈ ${formatNumber(o.requestedValue)}',
              style: const TextStyle(fontSize: 12, color: kTextTertiary),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onDecline, child: Text(incoming ? 'Decline' : 'Cancel offer')),
                if (incoming) FilledButton(onPressed: onAccept, child: const Text('Accept')),
              ],
            ),
          ],
        ),
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
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(g.profile.showcasePublished ? 'Edit my showcase' : 'Put up a showcase · ${Game.showcaseCost} bits'),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ShowcaseEditor()));
                  _load();
                },
              ),
              const SizedBox(height: 8),
              if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
              if (snap.connectionState == ConnectionState.done && list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No showcases yet — be the first!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextTertiary),
                  ),
                ),
              for (final s in list)
                Card(
                  margin: const EdgeInsets.only(top: 10),
                  child: InkWell(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShowcaseView(showcase: s))),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                ),
                              ),
                              const Icon(Icons.favorite, size: 16, color: kAccent),
                              const SizedBox(width: 4),
                              Text('${s.likes}'),
                            ],
                          ),
                          GestureDetector(
                            onTap: () => openPlayer(context, s.playerId),
                            child: Text(
                              '${s.playerName} · ${s.cards.length} cards · ${_ago(s.updatedAt)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                                decoration: TextDecoration.underline,
                                decorationColor: Colors.white24,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          ShowcaseStrip(cards: s.cards, cardWidth: 130, live: false),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

String _ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inHours < 1) return '${d.inMinutes.clamp(1, 59)}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class ShowcaseView extends StatelessWidget {
  const ShowcaseView({super.key, required this.showcase});
  final Showcase showcase;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final s = showcase;
    final w = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
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
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          GestureDetector(
            onTap: () => openPlayer(context, s.playerId),
            child: Text(
              'by ${s.playerName}',
              style: const TextStyle(color: kTextSecondary, decoration: TextDecoration.underline, decorationColor: kTextSecondary),
            ),
          ),
          const SizedBox(height: 12),
          ShowcaseStrip(cards: s.cards, cardWidth: (w * 0.42).clamp(170.0, 260.0)),
          const Text('Tap a card to see it in full · ▶ plays it', style: TextStyle(fontSize: 12, color: kTextTertiary)),
        ],
      ),
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

  Future<void> _run(Future<void> Function() f, String done) async {
    final g = GameScope.read(context);
    setState(() => _busy = true);
    try {
      await f();
      g.toast(done);
    } catch (e) {
      g.toast('$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final cards = [for (final u in p.showcaseCards) ?g.collection.byUid(u)];
    return Scaffold(
      appBar: AppBar(title: const Text('My showcase')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text(
            'Show off up to 10 cards on the market\'s Showcases page. Putting a showcase up (or replacing it) costs '
            '${Game.showcaseCost} bits; you can have one at a time.',
            style: TextStyle(color: kTextSecondary),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Showcase title'),
            onChanged: (v) {
              p.showcaseTitle = v;
              p.changed();
            },
          ),
          Row(
            children: [
              Text('Cards (${cards.length}/$kMaxShowcaseCards)', style: const TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add'),
                onPressed: cards.length >= kMaxShowcaseCards
                    ? null
                    : () async {
                        final picked = await pickCards(
                          context,
                          title: 'Pick showcase cards',
                          max: kMaxShowcaseCards - cards.length,
                          exclude: p.showcaseCards.toSet(),
                        );
                        if (picked != null) {
                          p.showcaseCards = [...p.showcaseCards.where((u) => g.collection.byUid(u) != null), ...picked].take(kMaxShowcaseCards).toList();
                          p.changed();
                        }
                      },
              ),
            ],
          ),
          SizedBox(
            height: 170,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final c = cards[i];
                return SizedBox(
                  width: 106,
                  child: CardTile(
                    song: c.song,
                    rarity: c.rarity,
                    shiny: c.shiny,
                    edition: c.edition,
                    serial: c.serial,
                    onLongPress: () {
                      p.showcaseCards = [...p.showcaseCards]..remove(c.uid);
                      p.changed();
                    },
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: c.uid))),
                  ),
                );
              },
            ),
          ),
          if (cards.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Long-press a card to remove it', style: TextStyle(fontSize: 11, color: Colors.white38)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.publish),
            label: Text('${p.showcasePublished ? 'Replace my showcase' : 'Put up my showcase'} · ${Game.showcaseCost} bits'),
            onPressed: _busy || cards.isEmpty || p.bits < Game.showcaseCost ? null : () => _run(g.publishShowcase, 'Showcase is up!'),
          ),
          if (p.bits < Game.showcaseCost)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'You have ${p.bits} bits.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kTextTertiary),
              ),
            ),
          if (p.showcasePublished) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _busy ? null : () => _run(g.removeShowcase, 'Showcase taken down'), child: const Text('Take my showcase down')),
          ],
        ],
      ),
    );
  }
}
