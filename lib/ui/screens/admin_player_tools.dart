import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/models.dart';
import '../../game/market_service.dart';
import '../../game/profile_themes.dart';
import '../../game/store_catalog.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/net_image.dart';

/// Admin build, admin accounts only: give a player any shop item, coins or
/// bits, or put any song (any rarity or variant) next to them. The server
/// checks the admin list, logs it on their account and tells the player.
Future<void> showAdminPlayerTools(BuildContext context, String playerId, String name) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.9, child: _AdminTools(playerId: playerId, name: name)),
    );

class _AdminTools extends StatefulWidget {
  const _AdminTools({required this.playerId, required this.name});
  final String playerId, name;
  @override
  State<_AdminTools> createState() => _AdminToolsState();
}

enum _Variant { regular, shiny, canvas, sample, live }

class _AdminToolsState extends State<_AdminTools> {
  String? _item;
  final _coins = TextEditingController(), _bits = TextEditingController(), _q = TextEditingController();
  List<Song> _songs = [];
  Song? _song;
  Rarity? _rarity; // null = the song's own rarity
  _Variant _variant = _Variant.regular;
  bool _busy = false;
  List<dynamic> _log = [];
  final _xp = TextEditingController();
  Map<String, dynamic> _progress = const {};

  int _bonusCount(Bonus b) => Bonuses.fromJson(_progress['bonuses'] as Map<String, dynamic>?).of(b);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLog());
  }

  @override
  void dispose() {
    _xp.dispose();
    _coins.dispose();
    _bits.dispose();
    _q.dispose();
    super.dispose();
  }

  RemoteMarket? get _m {
    final m = GameScope.read(context).market;
    return m is RemoteMarket ? m : null;
  }

  String get _pid => Uri.encodeComponent(widget.playerId);

  Future<void> _loadLog() async {
    try {
      final l = await _m?.send('GET', '/admin/players/$_pid/log');
      if (mounted && l is List) setState(() => _log = l);
    } catch (_) {}
    try {
      final p = await _m?.send('GET', '/admin/players/$_pid/progress');
      if (mounted && p is Map<String, dynamic>) setState(() => _progress = p);
    } catch (_) {}
  }

  static String itemName(String id) {
    final p = productById(id);
    if (p != null) return p.name;
    for (final t in kProfileThemes) {
      if (t.id == id) return '${t.name} (profile theme)';
    }
    return id;
  }

  static String kindLabel(ShopKind k) => switch (k) {
        ShopKind.bits => 'Bits',
        ShopKind.theme => 'Map themes',
        ShopKind.hat => 'Hats',
        ShopKind.shirt => 'Shirts',
        ShopKind.pet => 'Pets',
        ShopKind.backpack => 'Backpacks',
        ShopKind.bundle => 'Bundles',
        ShopKind.profileTheme => 'Profile themes',
      };

  Future<void> _run(Future<String> Function(RemoteMarket m) f) async {
    final m = _m;
    final g = GameScope.read(context);
    if (m == null) return g.toast('Not connected to the server');
    setState(() => _busy = true);
    try {
      g.toast(await f(m));
      await _loadLog();
    } catch (e) {
      g.toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _grant() => _run((m) async {
        final j = await m.send('POST', '/admin/players/$_pid/grant', body: {
          'item': ?_item,
          if (_item != null) 'label': itemName(_item!).replaceAll(' (profile theme)', ' profile theme'),
          'coins': int.tryParse(_coins.text.trim()) ?? 0,
          'bits': int.tryParse(_bits.text.trim()) ?? 0,
        }) as Map<String, dynamic>;
        setState(() {
          _item = null;
          _coins.clear();
          _bits.clear();
        });
        return 'Gave ${widget.name}: ${j['given']}';
      });

  Future<void> _spawn() => _run((m) async {
        final s = _song!;
        await m.send('POST', '/admin/players/$_pid/spawn', body: {
          'song': s.toInfo().toJson(),
          'rarity': ?_rarity?.index,
          'shiny': _variant == _Variant.shiny,
          'ed': switch (_variant) {
            _Variant.canvas => Edition.canvas.index,
            _Variant.sample => Edition.sample.index,
            _Variant.live => Edition.live.index,
            _ => Edition.standard.index,
          },
        });
        return 'Placed ${s.title} next to ${widget.name} (it stays for an hour)';
      });

  Future<void> _giveXp(int sign) => _run((m) async {
        final n = int.tryParse(_xp.text.trim()) ?? 0;
        if (n <= 0) return 'Enter an amount of XP';
        await m.send('POST', '/admin/players/$_pid/xp', body: {'delta': n * sign});
        _xp.clear();
        return sign > 0 ? 'Gave ${widget.name} $n XP' : 'Took $n XP from ${widget.name}';
      });

  Future<void> _bonus(Bonus b, int delta) => _run((m) async {
        await m.send('POST', '/admin/players/$_pid/bonus', body: {'bonus': b.name, 'delta': delta});
        return delta > 0 ? 'Added a ${b.label} bonus to ${widget.name}' : 'Removed a ${b.label} bonus from ${widget.name}';
      });

  Future<void> _summonDj() => _run((m) async {
        final g = GameScope.read(context);
        final j = await m.send('POST', '/admin/players/$_pid/dj') as Map<String, dynamic>;
        final dj = j['dj'] as Map<String, dynamic>;
        // On the admin's own account it shows up on the map right away.
        if (widget.playerId == g.profile.playerId) g.refreshWorld();
        return '${dj['name']} turned up next to ${widget.name} (for half an hour)';
      });

  Future<void> _restore() => _run((m) async {
    final j = await m.send('POST', '/admin/players/$_pid/restore') as Map<String, dynamic>;
    final n = (j['restored'] as num?)?.toInt() ?? 0;
    return n == 0 ? 'Nothing to restore for ${widget.name}' : 'Restored $n cards to ${widget.name}';
  });

  Future<void> _minigames(int extra) => _run((m) async {
    await m.send('POST', '/admin/players/$_pid/minigames', body: {'extra': extra});
    return extra == 0 ? "Reset ${widget.name}'s minigame rounds for today" : 'Gave ${widget.name} $extra extra rounds today';
  });

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    try {
      final r = await GameScope.read(context).api.searchSongs(q, limit: 20);
      if (mounted) setState(() => _songs = r);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final byKind = <ShopKind, List<ShopItem>>{};
    for (final i in kShopItems) {
      (byKind[i.kind] ??= []).add(i);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      Text('Admin · ${widget.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const Text('Gifts and songs are logged on their account, and they get a notification.', style: TextStyle(fontSize: 12, color: kTextTertiary)),
      const SizedBox(height: 16),
      const SectionLabel('Give'),
      DropdownButtonFormField<String?>(
        initialValue: _item,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Item (free — e.g. paid outside the app stores)'),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('No item')),
          for (final e in byKind.entries)
            for (final i in e.value)
              DropdownMenuItem<String?>(
                value: i.id,
                child: Text('${kindLabel(e.key)} · ${itemName(i.id)}${i.kind == ShopKind.bits ? '' : ''}', overflow: TextOverflow.ellipsis),
              ),
        ],
        onChanged: (v) => setState(() => _item = v),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TextField(controller: _coins, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Coins'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _bits, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Bits'))),
      ]),
      const SizedBox(height: 10),
      Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: _busy ? null : _grant, icon: const Icon(Icons.card_giftcard), label: const Text('Give'))),
      const Divider(height: 32),
      const SectionLabel('Spawn a song next to them'),
      TextField(
        controller: _q,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(hintText: 'Search any song', prefixIcon: const Icon(Icons.search, size: 20), suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search)),
      ),
      for (final s in _songs.take(8))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Art(s.cover(120), size: 40, radius: 5),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(s.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: _song?.id == s.id ? const Icon(Icons.check_circle, color: kAccent) : null,
          onTap: () => setState(() => _song = s),
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<Rarity?>(
        initialValue: _rarity,
        decoration: const InputDecoration(labelText: 'Rarity'),
        items: [
          const DropdownMenuItem<Rarity?>(value: null, child: Text('The song\'s own rarity')),
          for (final r in Rarity.values) DropdownMenuItem<Rarity?>(value: r, child: Text(r.label)),
        ],
        onChanged: (v) => setState(() => _rarity = v),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 6, children: [
        for (final v in _Variant.values)
          ChoiceChip(
            label: Text(switch (v) {
              _Variant.regular => 'Regular',
              _Variant.shiny => 'Shiny',
              _Variant.canvas => 'Canvas',
              _Variant.sample => 'Sample',
              _Variant.live => 'Live',
            }),
            selected: _variant == v,
            onSelected: (_) => setState(() => _variant = v),
          ),
      ]),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _busy || _song == null ? null : _spawn,
          icon: const Icon(Icons.add_location_alt_outlined),
          label: Text(_song == null ? 'Pick a song' : 'Spawn ${_song!.title}', overflow: TextOverflow.ellipsis),
        ),
      ),
        const Divider(height: 32),
        const SectionLabel('XP and bonuses'),
        Text(
          _progress.isEmpty ? 'Not on the server economy yet' : 'Level ${_progress['level']} · ${_progress['xp']} XP',
          style: const TextStyle(fontSize: 12, color: kTextSecondary),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _xp, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'XP', isDense: true))),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _busy ? null : () => _giveXp(-1), child: const Text('Take')),
          const SizedBox(width: 8),
          FilledButton(onPressed: _busy ? null : () => _giveXp(1), child: const Text('Give')),
        ]),
        const SizedBox(height: 4),
        for (final b in Bonus.values)
          Row(children: [
            Expanded(child: Text('${b.label}  ×${_bonusCount(b)}', style: const TextStyle(fontSize: 13))),
            IconButton(tooltip: 'Remove one', onPressed: _busy || _bonusCount(b) <= 0 ? null : () => _bonus(b, -1), icon: const Icon(Icons.remove_circle_outline)),
            IconButton(tooltip: 'Add one', onPressed: _busy ? null : () => _bonus(b, 1), icon: const Icon(Icons.add_circle_outline)),
          ]),
        const Divider(height: 32),
        const SectionLabel('DJ battle'),
        const Text('A DJ turns up about 30 m from where this player last was, for half an hour. Only they see it; players nearby can join the battle.',
            style: TextStyle(fontSize: 12, color: kTextSecondary)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(onPressed: _busy ? null : _summonDj, icon: const Icon(Icons.album_outlined), label: const Text('Summon a DJ')),
        ),
        const Divider(height: 32),
        const SectionLabel('Minigames'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(onPressed: _busy ? null : () => _minigames(0), icon: const Icon(Icons.restart_alt), label: const Text("Reset today's rounds")),
            for (final n in const [3, 6, 12]) OutlinedButton(onPressed: _busy ? null : () => _minigames(n), child: Text('+$n rounds')),
          ],
        ),
        const Divider(height: 32),
        const SectionLabel('Cards from before the server switch'),
        const Text(
          'Adds back cards from their collection as it was before Beta v1.0.3 (cards they still have, or numbered cards someone else now holds, are skipped).',
          style: TextStyle(fontSize: 12, color: kTextSecondary),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(onPressed: _busy ? null : _restore, icon: const Icon(Icons.history), label: const Text('Restore cards')),
        ),
        if (_log.isNotEmpty) ...[
          const Divider(height: 32),
          const SectionLabel('Admin history'),
          for (final e in _log)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${DateTime.fromMillisecondsSinceEpoch((e as Map)['at'] as int).toLocal().toString().substring(0, 16)} · ${e['by']} ${e['what']}',
                style: const TextStyle(fontSize: 12, color: kTextSecondary),
              ),
            ),
      ],
    ]);
  }
}
