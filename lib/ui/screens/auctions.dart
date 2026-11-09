import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';
import '../widgets/showcase_strip.dart';
import 'collection_screen.dart';
import 'player_screen.dart';
import 'report_dialogs.dart';

String auctionTimeLeft(int endsAt) {
  final d = Duration(milliseconds: endsAt - DateTime.now().millisecondsSinceEpoch);
  if (d.isNegative) return 'ending…';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m left';
  if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s left';
  return '${d.inSeconds}s left';
}

/// Rebuilds every second (auction countdowns).
class _Ticking extends StatefulWidget {
  const _Ticking({required this.builder});
  final WidgetBuilder builder;
  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  @override
  void initState() {
    super.initState();
    _t;
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// One auction in the market: current bid, time left, Bid / Buy It Now.
class AuctionTile extends StatefulWidget {
  const AuctionTile({super.key, required this.auction, required this.onChanged});
  final Auction auction;
  final VoidCallback onChanged;
  @override
  State<AuctionTile> createState() => _AuctionTileState();
}

class _AuctionTileState extends State<AuctionTile> {
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

  Future<void> _bid() async {
    final g = GameScope.read(context);
    final a = widget.auction;
    final ctl = TextEditingController(text: '${a.minBid}');
    final amount = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Bid on ${a.label}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              a.highBidderId == null ? 'Starting price: ${formatNumber(a.startPrice)} coins' : 'Current bid: ${formatNumber(a.highBid)} coins',
              style: const TextStyle(color: kTextSecondary),
            ),
            Text('Your bid must be at least ${formatNumber(a.minBid)} coins.', style: const TextStyle(color: kTextSecondary)),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Your bid (coins)'),
            ),
            const SizedBox(height: 6),
            Text(
              'Your coins are held until you\'re outbid (then they come back) or you win. You have ${formatNumber(g.profile.coins)}.',
              style: const TextStyle(fontSize: 12, color: kTextTertiary),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text.trim())), child: const Text('Place bid')),
        ],
      ),
    );
    if (amount == null) return;
    await _run(() => g.placeBid(a, amount), 'Bid placed: ${formatNumber(amount)} coins');
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final a = widget.auction;
    final me = g.profile.playerId;
    final mine = a.sellerId == me;
    final winning = a.highBidderId == me;
    final first = a.cards.first;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: winning ? const Color(0xFF69F0AE).withValues(alpha: 0.6) : (_open ? kAccent.withValues(alpha: 0.4) : kOutline)),
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
                  Stack(
                    children: [
                      Art(Song.fromPayload(first).cover(250), size: 56, radius: 10),
                      Positioned(
                        left: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(6)),
                          child: const Icon(Icons.gavel_rounded, size: 12, color: Colors.black),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          a.cards.length == 1 ? first.artistName : {for (final c in a.cards) c.artistName}.take(3).join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: kTextSecondary),
                        ),
                        const SizedBox(height: 2),
                        _Ticking(
                          builder: (_) => Text(
                            '${auctionTimeLeft(a.endsAt)} · ${a.bids} bid${a.bids == 1 ? '' : 's'}${mine ? '' : ' · by ${a.sellerName}'}${winning ? ' · you\'re winning' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: winning ? const Color(0xFF69F0AE) : kTextTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(a.highBidderId == null ? 'Start' : 'Bid', style: const TextStyle(fontSize: 10, color: kTextTertiary)),
                      CoinPrice(a.highBidderId == null ? a.startPrice : a.highBid),
                      if (a.buyNowOpen) Text('Buy now ${formatNumber(a.buyNow!)}', style: const TextStyle(fontSize: 10, color: kTextTertiary)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            const Divider(height: 1),
            if (a.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(a.note, style: const TextStyle(color: kTextSecondary)),
              ),
            for (final c in a.cards)
              CardRow(
                song: Song.fromPayload(c),
                rarity: c.rarity,
                shiny: c.shiny,
                edition: c.edition,
                serial: c.serial,
                onTap: () => showCardFullView(context, c),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: mine
                  ? Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy || a.highBidderId != null ? null : () => _run(() => g.cancelAuction(a), 'Auction cancelled — songs returned'),
                            child: Text(a.highBidderId != null ? 'Has bids — can\'t cancel' : 'Cancel auction'),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton(
                          tooltip: 'Report a song',
                          icon: const Icon(Icons.flag_outlined, size: 20, color: kTextTertiary),
                          onPressed: () => showSongReport(context, a.cards.first),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(playerId: a.sellerId))),
                          child: const Text('Seller'),
                        ),
                        const Spacer(),
                        if (a.buyNowOpen) ...[
                          OutlinedButton(
                            onPressed: _busy || g.profile.coins < a.buyNow! ? null : () => _run(() => g.buyAuctionNow(a), 'You bought ${a.label}!'),
                            child: Text('Buy now · ${formatNumber(a.buyNow!)}'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        FilledButton.icon(
                          icon: const Icon(Icons.gavel_rounded, size: 18),
                          label: Text(winning ? 'Winning' : 'Bid'),
                          onPressed: _busy || winning ? null : _bid,
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

/// Start an auction for songs from the collection.
class AuctionComposer extends StatefulWidget {
  const AuctionComposer({super.key, required this.uids});
  final List<int> uids;
  @override
  State<AuctionComposer> createState() => _AuctionComposerState();
}

class _AuctionComposerState extends State<AuctionComposer> {
  final _start = TextEditingController();
  final _inc = TextEditingController(text: '$kMinBidIncrement');
  final _buyNow = TextEditingController();
  final _note = TextEditingController();
  Duration _length = const Duration(hours: 24);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final g = GameScope.read(context);
    final fair = [for (final u in widget.uids) ?g.collection.byUid(u)].fold<int>(0, (a, c) => a + c.toPayload().fair);
    _start.text = '${(fair * 0.5).round().clamp(1, 1 << 30)}';
  }

  Future<void> _submit() async {
    final g = GameScope.read(context);
    final start = int.tryParse(_start.text.trim());
    final inc = int.tryParse(_inc.text.trim());
    final buy = _buyNow.text.trim().isEmpty ? null : int.tryParse(_buyNow.text.trim());
    if (start == null || start < 1) return setState(() => _error = 'Set a starting price');
    if (inc == null || inc < kMinBidIncrement) return setState(() => _error = 'The bid increment is at least $kMinBidIncrement coins');
    if (_buyNow.text.trim().isNotEmpty && (buy == null || buy <= start)) return setState(() => _error = 'Buy It Now must be more than the starting price');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await g.createAuction(widget.uids, startPrice: start, increment: inc, buyNow: buy, duration: _length, note: _note.text.trim());
      g.toast('Auction started');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final cards = [for (final u in widget.uids) ?g.collection.byUid(u)];
    InputDecoration coins(String label, {String? helper}) => InputDecoration(
      labelText: label,
      helperText: helper,
      prefixIcon: const Icon(kCoinIcon, size: 18, color: kCoinColor),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Start an auction')),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final c in cards) CardRow(song: c.song, rarity: c.rarity, shiny: c.shiny, edition: c.edition, serial: c.serial),
            const SizedBox(height: 12),
            TextField(
              controller: _start,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: coins('Starting price'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inc,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: coins('Minimum bid increment', helper: 'At least $kMinBidIncrement coins'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _buyNow,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: coins('Buy It Now price (optional)', helper: 'Anyone can buy instantly at this price until bids reach it'),
            ),
            const SizedBox(height: 16),
            const Text('Length', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final d in kAuctionDurations)
                  ChoiceChip(label: Text('${d.inHours} h'), selected: _length == d, onSelected: (_) => setState(() => _length = d)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Bids in the last 5 minutes add 30 seconds, so everyone gets a chance to answer a late bid.',
              style: TextStyle(fontSize: 12, color: kTextTertiary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              maxLength: kMaxListingNote,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFE5737A))),
              ),
            FilledButton.icon(
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.gavel_rounded),
              label: const Text('Start auction'),
              onPressed: _busy ? null : _submit,
            ),
            const SizedBox(height: 6),
            const Text(
              'The songs are held until the auction ends. With no bids they come back to you; you can cancel while nobody has bid.',
              style: TextStyle(fontSize: 12, color: kTextTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks songs and opens the auction composer. Returns true if started.
Future<bool> startAuction(BuildContext context) async {
  final picked = await pickCards(context, title: 'Pick up to $kMaxListingItems songs to auction', max: kMaxListingItems);
  if (picked == null || picked.isEmpty || !context.mounted) return false;
  return await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => AuctionComposer(uids: picked))) ?? false;
}
