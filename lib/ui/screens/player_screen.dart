import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../build_flags.dart';
import '../../game/market_service.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/profile_banner.dart';
import '../widgets/showcase_strip.dart';
import '../widgets/figure_portrait.dart';
import '../widgets/stick_figure.dart';
import 'admin_player_tools.dart';
import 'collection_screen.dart';
import 'favorite_artists_screen.dart';

import 'messages_screen.dart';
import 'report_dialogs.dart';

/// Another player's public profile: their showcase, favourite artists and
/// collection. Pick songs from the collection to make an offer, or send
/// them a message.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playerId});
  final String playerId;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  PublicProfile? _p;
  String? _error;
  final _search = TextEditingController();
  Timer? _debounce;
  final List<CardPayload> _cards = [];
  int _total = 0;
  bool _loadingCards = false;
  bool _more = true;
  final Map<int, CardPayload> _picked = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _reloadCards();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await GameScope.read(context).market.player(widget.playerId);
      if (mounted) {
        setState(() {
          _p = p;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _togglePick(CardPayload c) {
    final g = GameScope.read(context);
    setState(() {
      if (_picked.containsKey(c.uid)) {
        _picked.remove(c.uid);
      } else if (_picked.length < kMaxListingItems) {
        _picked[c.uid] = c;
      } else {
        g.toast('Up to $kMaxListingItems songs per offer');
      }
    });
  }

  /// Admin build, admin account, a real player: admin card tools.
  bool _admin(PublicProfile p) => kAdminBuild && GameScope.read(context).profile.isAdmin && !p.isBot;

  /// Admin: takes [c] out of the player's collection (no notice, no refund).
  Future<void> _removeCard(PublicProfile p, CardPayload c) async {
    final g = GameScope.read(context);
    final serial = c.edition.serialized && c.serial > 0 ? ' ${c.edition.label} #${c.serial}' : '';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this card?'),
        content: Text(
          '${c.title}$serial is taken out of ${p.name}\'s collection. They aren\'t told and get nothing back.'
          '${serial.isEmpty ? '' : ' Its number is freed so it can be found again.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final m = g.market;
    if (m is! RemoteMarket) return g.toast('Not connected to the server');
    try {
      await m.send('POST', '/admin/players/${Uri.encodeComponent(p.id)}/cards/${c.uid}/remove');
      if (!mounted) return;
      setState(() {
        _cards.removeWhere((x) => x.uid == c.uid);
        _picked.remove(c.uid);
        if (_total > 0) _total--;
      });
      g.toast('Removed ${c.title} from ${p.name}');
      unawaited(_load());
    } catch (err) {
      g.toast('$err');
    }
  }

  /// Under a card's full view: offer for it (with any ticked songs).
  Widget _fullViewActions(BuildContext ctx, PublicProfile p, CardPayload c) {
    final others = _picked.values.where((x) => x.uid != c.uid).length;
    final me = p.id == GameScope.read(context).profile.playerId;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        if (!me) ...[
          FilledButton.icon(
            icon: const Icon(Icons.local_offer_outlined),
            label: Text(others == 0 ? 'Make an offer' : 'Make an offer (with $others ticked)'),
            onPressed: () async {
              Navigator.pop(ctx);
              final wanted = {..._picked, c.uid: c}.values.toList();
              final sent = await composeDirectOffer(context, p, wanted);
              if (sent == true && mounted) setState(_picked.clear);
            },
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _togglePick(c);
            },
            child: Text(_picked.containsKey(c.uid) ? 'Untick' : 'Tick for a bigger offer'),
          ),
        ],
        if (_admin(p))
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Remove from player (admin)'),
            onPressed: () {
              Navigator.pop(ctx);
              _removeCard(p, c);
            },
          ),
      ],
    );
  }

  Future<void> _reloadCards() async {
    _cards.clear();
    _more = true;
    await _page();
  }

  Future<void> _page() async {
    if (_loadingCards || !_more) return;
    setState(() => _loadingCards = true);
    try {
      final res = await GameScope.read(context).market.playerCollection(widget.playerId, text: _search.text, offset: _cards.length, limit: 60);
      if (!mounted) return;
      setState(() {
        _cards.addAll(res.cards);
        _total = res.total;
        _more = res.cards.length == 60;
      });
    } catch (e) {
      if (mounted) GameScope.read(context).toast('$e');
    } finally {
      if (mounted) setState(() => _loadingCards = false);
    }
  }

  Future<void> _block(bool on) async {
    final g = GameScope.read(context);
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Block ${_p!.name}?'),
          content: const Text('Neither of you will be able to message the other or send direct offers. Open offers between you are returned.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Block')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await g.market.setBlocked(widget.playerId, on);
      g.toast(on ? 'Blocked' : 'Unblocked');
      await _load();
    } catch (e) {
      g.toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = _p;
    final me = widget.playerId == g.profile.playerId;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final joined = p.joinedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(p.joinedAt) : null;
    final stats = [
      ('Songs', formatNumber(p.cardCount)),
      if (p.stats['unique'] != null) ('Unique', formatNumber(p.stats['unique']!.toInt())),
      if (p.stats['caught'] != null) ('Caught', formatNumber(p.stats['caught']!.toInt())),
      if (p.stats['shinies'] != null) ('Shinies', formatNumber(p.stats['shinies']!.toInt())),
      if (p.stats['km'] != null) ('Walked', '${p.stats['km']} km'),
      if (p.stats['trades'] != null) ('Trades', formatNumber(p.stats['trades']!.toInt())),
    ];
    return ProfileThemePage(
      themeId: p.theme,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            // Admin build, admin accounts: gifts and song spawns.
            if (kAdminBuild && GameScope.of(context).profile.isAdmin && !p.isBot)
              IconButton(tooltip: 'Admin tools', icon: const Icon(Icons.admin_panel_settings_outlined), onPressed: () => showAdminPlayerTools(context, p.id, p.name)),
            if (!me && !p.isBot)
              PopupMenuButton<String>(
                onSelected: (v) => v == 'report' ? showPlayerReport(context, p.id, p.name) : _block(v == 'block'),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'report', child: Text('Report')),
                  PopupMenuItem(value: p.blockedByMe ? 'unblock' : 'block', child: Text(p.blockedByMe ? 'Unblock' : 'Block')),
                ],
              ),
          ],
        ),
        bottomNavigationBar: _picked.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      TextButton(onPressed: () => setState(_picked.clear), child: const Text('Clear')),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          icon: const Icon(Icons.swap_horiz),
                          label: Text('Make an offer for ${_picked.length} song${_picked.length == 1 ? '' : 's'}'),
                          onPressed: () async {
                            final sent = await composeDirectOffer(context, p, _picked.values.toList());
                            if (sent == true && mounted) setState(_picked.clear);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) _page();
            return false;
          },
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: ContentWidth(
                  maxWidth: 1000,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ProfileBanner(
                          themeId: p.theme,
                          name: p.name,
                          subtitle: ['Level ${p.level}', if (p.isBot) 'NPC trader', if (joined != null) 'joined ${joined.month}/${joined.year}'].join(' · '),
                          portrait: p.isBot ? null : FigurePortrait(look: FigureLook.fromJson(p.look), diameter: 112, name: p.name),
                        ),
                        if (p.coins != null || p.bits != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                if (p.coins != null) CurrencyChip(icon: kCoinIcon, value: p.coins!, color: kCoinColor),
                                if (p.bits != null) CurrencyChip(icon: kBitsIcon, value: p.bits!, color: kBitsColor),
                              ],
                            ),
                          ),
                        const SizedBox(height: 10),
                        if (!me && !p.isBot)
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                                  label: const Text('Message'),
                                  onPressed: p.blockedByMe
                                      ? null
                                      : () => Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) => ChatScreen(otherId: p.id, otherName: p.name, otherTheme: p.theme),
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        if (p.blockedByMe)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                const Icon(Icons.block, size: 16, color: kTextTertiary),
                                const SizedBox(width: 6),
                                const Expanded(
                                  child: Text('You blocked this player.', style: TextStyle(color: kTextTertiary)),
                                ),
                                TextButton(onPressed: () => _block(false), child: const Text('Unblock')),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (k, v) in stats)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: kSurface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: kOutline),
                                ),
                                child: Column(
                                  children: [
                                    Text(v, style: const TextStyle(fontWeight: FontWeight.w800)),
                                    Text(k, style: const TextStyle(fontSize: 10, color: kTextTertiary)),
                                  ],
                                ),
                              ),
                          ],
                        ),
                        if (p.editionShowcase.isNotEmpty) ...[
                          const SectionLabel('Showcase'),
                          LayoutBuilder(
                            builder: (context, box) => ShowcaseStrip(cards: p.editionShowcase, cardWidth: ((box.maxWidth - 20) / 3).clamp(100.0, 200.0)),
                          ),
                        ],
                        if (p.favoriteArtists.isNotEmpty) ...[const SizedBox(height: 14), FavoriteArtistsTab(artists: p.favoriteArtists)],
                        // (The market showcase is shown on the market only.)
                        SectionLabel('Collection  ${formatNumber(_total)}'),
                        if (!me)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Tap a song to see it in full and make an offer. Tick songs (or hold them) to offer for several at once.',
                              style: TextStyle(fontSize: 12, color: kTextTertiary),
                            ),
                          ),
                        TextField(
                          controller: _search,
                          decoration: const InputDecoration(hintText: 'Search their songs, artists, albums', prefixIcon: Icon(Icons.search, size: 20)),
                          onChanged: (_) {
                            _debounce?.cancel();
                            _debounce = Timer(const Duration(milliseconds: 350), _reloadCards);
                          },
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: 14 + ((MediaQuery.sizeOf(context).width - 1000) / 2).clamp(0.0, double.infinity)),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, childAspectRatio: 0.64, crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: _cards.length,
                  itemBuilder: (context, i) {
                    final c = _cards[i];
                    final on = _picked.containsKey(c.uid);
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: CardTile(
                            song: Song.fromPayload(c),
                            rarity: c.rarity,
                            shiny: c.shiny,
                            edition: c.edition,
                            serial: c.serial,
                            onTap: () => showCardFullView(context, c, actions: _admin(p) || !(me || p.isBot) ? (ctx) => _fullViewActions(ctx, p, c) : null),
                            onLongPress: me || p.isBot ? null : () => _togglePick(c),
                          ),
                        ),
                        if (!me && !p.isBot)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: on ? 'Take out of the offer' : 'Add to an offer',
                              icon: on
                                  ? const Icon(Icons.check_circle, color: kAccent, size: 22)
                                  : const Icon(Icons.radio_button_unchecked, color: Colors.white70, size: 22, shadows: [Shadow(blurRadius: 4)]),
                              onPressed: () => _togglePick(c),
                            ),
                          ),
                        if (on)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: kAccent, width: 3),
                                  color: kAccent.withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: _loadingCards
                        ? const CircularProgressIndicator()
                        : _cards.isEmpty
                        ? Text(_search.text.isEmpty ? 'No songs to show yet.' : 'No matches.', style: const TextStyle(color: kTextTertiary))
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
              if (p.isBot)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Text(
                      'NPC traders only trade through their market listings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kTextTertiary, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Offer some of your songs and/or coins for [wanted] songs from [to]'s
/// collection.
Future<bool?> composeDirectOffer(BuildContext context, PublicProfile to, List<CardPayload> wanted) async {
  final g = GameScope.read(context);
  if (to.isBot) {
    g.toast('NPC traders only trade through their market listings');
    return false;
  }
  var uids = <int>[];
  final coinsCtl = TextEditingController(text: '0');
  final noteCtl = TextEditingController();
  final want = wanted.fold<int>(0, (a, c) => a + c.fair);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        final mine = [for (final u in uids) ?g.collection.byUid(u)];
        final value = mine.fold<int>(0, (a, c) => a + c.toPayload().fair);
        return AlertDialog(
          title: Text('Offer to ${to.name}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You want ${wanted.length} song${wanted.length == 1 ? '' : 's'} (est. ${formatNumber(want)}):', style: const TextStyle(color: kTextSecondary)),
                  for (final c in wanted.take(5)) Text('• ${c.title} — ${c.artistName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  if (wanted.length > 5) Text('…and ${wanted.length - 5} more', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: Text('You offer ${mine.length} song${mine.length == 1 ? '' : 's'}${mine.isEmpty ? '' : ' (est. ${formatNumber(value)})'}')),
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(mine.isEmpty ? 'Add songs' : 'Change'),
                        onPressed: () async {
                          final picked = await pickCards(ctx, title: 'Pick up to $kMaxListingItems songs to offer', max: kMaxListingItems);
                          if (picked != null) setD(() => uids = picked);
                        },
                      ),
                    ],
                  ),
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
                  const Text('Your songs and coins are held until they answer. If they decline, everything comes back.', style: TextStyle(fontSize: 12, color: kTextTertiary)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send offer')),
          ],
        );
      },
    ),
  );
  if (ok != true) return false;
  try {
    await g.makeDirectOffer(to.id, to.name, wanted, uids, int.tryParse(coinsCtl.text.trim()) ?? 0, note: noteCtl.text.trim());
    g.toast('Offer sent to ${to.name}');
    return true;
  } catch (e) {
    g.toast('$e');
    return false;
  }
}
