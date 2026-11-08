import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'card_detail_screen.dart';
import 'collection_screen.dart';

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
            color: const Color(0xFF12141F),
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

  ListingQuery _copy({String? text, Set<int>? rarities, bool? shiny, bool? trades, ListingSort? sort}) => ListingQuery(
        text: text ?? _q.text,
        rarities: rarities ?? _q.rarities,
        shinyOnly: shiny ?? _q.shinyOnly,
        tradesOnly: trades ?? _q.tradesOnly,
        sort: sort ?? _q.sort,
      );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: TextField(
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search listings',
            prefixIcon: const Icon(Icons.search),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
          ),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () => _set(_copy(text: v)));
          },
        ),
      ),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10), children: [
          for (final r in Rarity.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(r.label),
                showCheckmark: false,
                side: BorderSide(color: rarityColor(r)),
                selectedColor: rarityColor(r).withValues(alpha: 0.35),
                selected: _q.rarities.contains(r.index),
                onSelected: (v) {
                  final s = {..._q.rarities};
                  v ? s.add(r.index) : s.remove(r.index);
                  _set(_copy(rarities: s));
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(label: const Text('✦ Shiny'), selected: _q.shinyOnly, onSelected: (v) => _set(_copy(shiny: v))),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(label: const Text('Open to trades'), selected: _q.tradesOnly, onSelected: (v) => _set(_copy(trades: v))),
          ),
          DropdownButton<ListingSort>(
            value: _q.sort,
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
                        final s = Song.fromPayload(l.card);
                        return CardRow(
                          song: s,
                          rarity: l.card.rarity,
                          shiny: l.card.shiny,
                          subtitle: '${s.artistName} • by ${l.sellerName}${l.acceptsTrades ? ' • trades ok' : ''}',
                          trailing: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(formatNumber(l.price), style: const TextStyle(color: kCoinColor, fontWeight: FontWeight.w800)),
                          ),
                          onTap: () async {
                            final changed = await showListingSheet(context, l);
                            if (changed == true) _reload();
                          },
                        );
                      },
                    ),
        ),
      ),
    ]);
  }
}

/// Listing details with buy / offer-trade actions. Returns true if the
/// market changed.
Future<bool?> showListingSheet(BuildContext context, Listing l) {
  final g = GameScope.read(context);
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF12141F),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SongCardView(song: Song.fromPayload(l.card), rarity: l.card.rarity, shiny: l.card.shiny, width: 220),
          const SizedBox(height: 12),
          Text('Sold by ${l.sellerName}', style: const TextStyle(color: Colors.white60)),
          Text('Est. value ${formatNumber(l.card.fair)} coins', style: const TextStyle(fontSize: 12, color: Colors.white38)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(kCoinIcon),
              label: Text('Buy for ${formatNumber(l.price)} coins'),
              onPressed: g.profile.coins < l.price
                  ? null
                  : () async {
                      try {
                        await g.buyListing(l);
                        g.toast('You bought ${l.card.title}!');
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        g.toast('$e');
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      }
                    },
            ),
          ),
          if (g.profile.coins < l.price) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Not enough coins', style: TextStyle(color: Colors.redAccent))),
          if (l.acceptsTrades) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Offer a trade'),
                onPressed: () async {
                  final sent = await _composeOffer(ctx, l);
                  if (sent == true && ctx.mounted) Navigator.pop(ctx, true);
                },
              ),
            ),
          ],
        ]),
      ),
    ),
  );
}

Future<bool?> _composeOffer(BuildContext context, Listing l) async {
  final g = GameScope.read(context);
  final uids = await pickCards(context, title: 'Pick up to 10 cards to offer', max: 10);
  if (uids == null || !context.mounted) return false;
  final coinsCtl = TextEditingController(text: '0');
  final cards = [for (final u in uids) ?g.collection.byUid(u)];
  final value = cards.fold<int>(0, (a, c) => a + c.toPayload().fair);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Trade offer'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('For: ${l.card.title} (${l.card.rarity.label}${l.card.shiny ? ' Shiny' : ''}) — est. ${l.card.fair}'),
        const SizedBox(height: 8),
        Text('You offer ${cards.length} card(s), est. $value coins of value'),
        TextField(controller: coinsCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '+ coins')),
        const SizedBox(height: 6),
        const Text('Offered items are held in escrow until the seller responds.', style: TextStyle(fontSize: 12, color: Colors.white54)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send offer')),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await g.makeOffer(l, uids, int.tryParse(coinsCtl.text) ?? 0);
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
                label: const Text('List a card for sale'),
                onPressed: () async {
                  final picked = await pickCards(context, title: 'Pick a card to sell');
                  if (picked != null && picked.isNotEmpty && context.mounted) {
                    await showListDialog(context, picked.first);
                    _load();
                  }
                },
              ),
            ),
            if (snap.connectionState == ConnectionState.waiting) const Center(child: CircularProgressIndicator()),
            if (snap.hasError) Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}')),
            if (list.isEmpty && snap.connectionState == ConnectionState.done)
              const Padding(padding: EdgeInsets.all(24), child: Text('You have no active listings.', textAlign: TextAlign.center)),
            for (final l in list)
              CardRow(
                song: Song.fromPayload(l.card),
                rarity: l.card.rarity,
                shiny: l.card.shiny,
                subtitle: '${formatNumber(l.price)} coins${l.acceptsTrades ? ' • accepting trades' : ''}',
                trailing: TextButton(
                  onPressed: () async {
                    try {
                      await g.cancelListing(l);
                      g.toast('Listing cancelled — card returned');
                    } catch (e) {
                      g.toast('$e');
                    }
                    _load();
                  },
                  child: const Text('Cancel'),
                ),
              ),
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
          Text(incoming ? '${o.fromName} wants your ${o.requestedCard.title}' : 'Your offer for ${o.requestedCard.title}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final c in o.offeredCards)
            CardRow(song: Song.fromPayload(c), rarity: c.rarity, shiny: c.shiny),
          if (o.offeredCoins > 0) Padding(padding: const EdgeInsets.all(6), child: Text('+ ${formatNumber(o.offeredCoins)} coins', style: const TextStyle(color: kCoinColor))),
          Text('Offer value ≈ ${formatNumber(o.offeredValue)} • your card ≈ ${formatNumber(o.requestedCard.fair)}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
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
                        const Icon(Icons.favorite, size: 16, color: Colors.pinkAccent),
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
        Text('by ${s.playerName}', style: const TextStyle(color: Colors.white60)),
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
