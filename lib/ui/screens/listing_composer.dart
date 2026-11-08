import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../data/profile.dart';
import '../app.dart';
import '../widgets/cards.dart';
import 'collection_screen.dart';

/// Quick list after a catch (or from a card): one tap with the rarity
/// preset, or open the composer to set a price and note. Returns true if
/// the card was listed.
Future<bool> showQuickListSheet(BuildContext context, int uid) async {
  final g = GameScope.read(context);
  final card = g.collection.byUid(uid);
  if (card == null) return false;
  final preset = g.profile.quickListPreset(card.rarity);
  final price = preset.price * (card.shiny ? kShinyValueMultiplier : 1);
  final result = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SheetHandle(),
          const Text('Quick list', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          CardRow(song: card.song, rarity: card.rarity, shiny: card.shiny, edition: card.edition),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(14), border: Border.all(color: kOutline)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${card.rarity.label} preset${card.shiny ? ' (×$kShinyValueMultiplier shiny)' : ''}',
                  style: const TextStyle(fontSize: 12, color: kTextTertiary)),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(kCoinIcon, size: 16, color: kCoinColor),
                const SizedBox(width: 6),
                Text(formatNumber(price), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (preset.trades) const Text('Open to trades', style: TextStyle(fontSize: 12, color: kTextSecondary)),
              ]),
              if (preset.note.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('“${preset.note}”', style: const TextStyle(color: kTextSecondary, fontSize: 13)),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'preset'), child: Text('List now for ${formatNumber(price)}')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, 'custom'), child: const Text('Set price & note…')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'presets'), child: const Text('Edit quick-list presets')),
        ]),
      ),
    ),
  );
  if (!context.mounted) return false;
  switch (result) {
    case 'preset':
      try {
        await g.quickList(uid);
        g.toast('Listed ${card.song.title} for ${formatNumber(price)} coins');
        return true;
      } catch (e) {
        g.toast('$e');
        return false;
      }
    case 'custom':
      return await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ListingComposer(initialUids: [uid]))) ?? false;
    case 'presets':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickListPresetsScreen()));
      return false;
  }
  return false;
}

/// Create a market listing: a folder of up to 20 songs, each with its own
/// price, an automatic (or discounted) folder price, and a note.
class ListingComposer extends StatefulWidget {
  const ListingComposer({super.key, this.initialUids = const []});
  final List<int> initialUids;
  @override
  State<ListingComposer> createState() => _ListingComposerState();
}

class _ListingComposerState extends State<ListingComposer> {
  final List<int> _uids = [];
  final Map<int, TextEditingController> _prices = {};
  final _folder = TextEditingController();
  final _note = TextEditingController();
  bool _customFolder = false;
  bool _trades = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _add(widget.initialUids));
  }

  @override
  void dispose() {
    for (final c in _prices.values) {
      c.dispose();
    }
    _folder.dispose();
    _note.dispose();
    super.dispose();
  }

  void _add(List<int> uids) {
    final g = GameScope.read(context);
    setState(() {
      for (final u in uids) {
        if (_uids.length >= kMaxListingItems || _uids.contains(u)) continue;
        final c = g.collection.byUid(u);
        if (c == null) continue;
        _uids.add(u);
        final preset = g.profile.quickListPreset(c.rarity).price * (c.shiny ? kShinyValueMultiplier : 1);
        _prices[u] = TextEditingController(text: '$preset');
      }
      if (_uids.length == 1 && _note.text.isEmpty) {
        final c = g.collection.byUid(_uids.first);
        if (c != null) {
          final p = g.profile.quickListPreset(c.rarity);
          _note.text = p.note;
          _trades = p.trades;
        }
      }
    });
  }

  int _price(int uid) => int.tryParse(_prices[uid]?.text.trim() ?? '') ?? 0;
  int get _total => _uids.fold<int>(0, (a, u) => a + _price(u));
  int? get _folderPrice => _customFolder ? int.tryParse(_folder.text.trim()) : null;

  Future<void> _publish() async {
    final g = GameScope.read(context);
    if (_uids.isEmpty) return;
    if (_uids.any((u) => _price(u) < 1)) {
      g.toast('Give every song a price of at least 1 coin');
      return;
    }
    final fp = _folderPrice;
    if (_customFolder && _uids.length > 1 && (fp == null || fp < 1 || fp > _total)) {
      g.toast('Folder price must be between 1 and ${formatNumber(_total)}');
      return;
    }
    setState(() => _busy = true);
    try {
      await g.listCards({for (final u in _uids) u: _price(u)},
          folderPrice: _uids.length > 1 ? fp : null, note: _note.text.trim(), trades: _trades);
      g.toast(_uids.length == 1 ? 'Listed!' : 'Listed a folder of ${_uids.length} songs');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      g.toast('$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final cards = [for (final u in _uids) ?g.collection.byUid(u)];
    final total = _total;
    final folder = _folderPrice ?? total;
    final discount = total > 0 && _customFolder && _uids.length > 1 ? ((1 - folder / total) * 100).round() : 0;
    return Scaffold(
      appBar: AppBar(title: Text(_uids.length > 1 ? 'New folder listing' : 'New listing')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        SectionLabel('Songs  ${_uids.length}/$kMaxListingItems',
            trailing: _uids.length >= kMaxListingItems
                ? null
                : GestureDetector(
                    onTap: () async {
                      final picked = await pickCards(context,
                          title: 'Add songs (${kMaxListingItems - _uids.length} left)', max: kMaxListingItems - _uids.length, exclude: _uids.toSet());
                      if (picked != null) _add(picked);
                    },
                    child: const Text('+ Add songs', style: TextStyle(color: kAccent, fontSize: 13)),
                  )),
        if (cards.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Add up to 20 songs.', textAlign: TextAlign.center, style: TextStyle(color: kTextTertiary))),
        for (final c in cards)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: kOutline)),
            child: Row(children: [
              Expanded(child: CardRow(song: c.song, rarity: c.rarity, shiny: c.shiny, edition: c.edition, subtitle: '${c.song.artistName} · est. ${formatNumber(c.toPayload().fair)}')),
              SizedBox(
                width: 92,
                child: TextField(
                  controller: _prices[c.uid],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.right,
                  decoration: const InputDecoration(prefixIcon: Icon(kCoinIcon, size: 14, color: kCoinColor), prefixIconConstraints: BoxConstraints(minWidth: 26)),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: kTextTertiary),
                onPressed: () => setState(() {
                  _uids.remove(c.uid);
                  _prices.remove(c.uid)?.dispose();
                }),
              ),
            ]),
          ),
        if (_uids.length > 1) ...[
          const SectionLabel('Folder price'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: kOutline)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('Songs total', style: TextStyle(color: kTextSecondary)),
                const Spacer(),
                Text(formatNumber(total), style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Set a bundle price (discount)'),
                value: _customFolder,
                onChanged: (v) => setState(() {
                  _customFolder = v;
                  if (v && _folder.text.isEmpty) _folder.text = '${(total * 0.9).round()}';
                }),
              ),
              if (_customFolder)
                TextField(
                  controller: _folder,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: 'Folder price',
                    prefixIcon: const Icon(kCoinIcon, size: 16, color: kCoinColor),
                    suffixText: discount > 0 ? '−$discount%' : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 8),
              Text(
                _customFolder ? 'Buyers can take the whole folder for ${formatNumber(folder)} or buy songs one by one.' : 'Folder price is the sum of the songs (${formatNumber(total)}).',
                style: const TextStyle(fontSize: 12, color: kTextTertiary),
              ),
            ]),
          ),
        ],
        const SectionLabel('Note'),
        TextField(
          controller: _note,
          maxLength: kMaxListingNote,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(hintText: 'e.g. “Bundle deal — looking for shinies in trade”'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Accept trade offers'),
          subtitle: const Text('Players can offer songs and/or coins for the whole listing', style: TextStyle(fontSize: 12)),
          value: _trades,
          onChanged: (v) => setState(() => _trades = v),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy || _uids.isEmpty ? null : _publish,
          child: Text(_uids.length > 1 ? 'List folder for ${formatNumber(folder)}' : 'List for ${formatNumber(total)}'),
        ),
        const SizedBox(height: 6),
        const Text('Songs are held by the market until they sell or you cancel.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: kTextTertiary)),
      ]),
    );
  }
}

/// Settings → Quick-list presets: a price and note per rarity.
class QuickListPresetsScreen extends StatefulWidget {
  const QuickListPresetsScreen({super.key});
  @override
  State<QuickListPresetsScreen> createState() => _QuickListPresetsScreenState();
}

class _QuickListPresetsScreenState extends State<QuickListPresetsScreen> {
  late final PlayerProfile _p = GameScope.read(context).profile;
  late final List<TextEditingController> _price = [for (final q in _p.quickListPresets) TextEditingController(text: '${q.price}')];
  late final List<TextEditingController> _note = [for (final q in _p.quickListPresets) TextEditingController(text: q.note)];

  @override
  void dispose() {
    for (final c in [..._price, ..._note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    for (var i = 0; i < 5; i++) {
      _p.quickListPresets[i].price = (int.tryParse(_price[i].text) ?? 1).clamp(1, 100000000);
      _p.quickListPresets[i].note = _note[i].text.trim();
    }
    _p.changed();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, _) => _save(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Quick-list presets')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text('Used by “Quick list” after a catch. Shiny songs list at ×5 the preset price.', style: TextStyle(color: kTextSecondary, fontSize: 13)),
          ),
          for (final r in Rarity.values)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: kOutline)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  RarityDot(r, size: 9),
                  const SizedBox(width: 8),
                  Text(r.label, style: TextStyle(fontWeight: FontWeight.w600, color: rarityColor(r))),
                  const Spacer(),
                  const Text('Trades', style: TextStyle(fontSize: 12, color: kTextSecondary)),
                  Switch(
                    value: _p.quickListPresets[r.index].trades,
                    onChanged: (v) => setState(() => _p.quickListPresets[r.index].trades = v),
                  ),
                ]),
                const SizedBox(height: 6),
                TextField(
                  controller: _price[r.index],
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Price', prefixIcon: Icon(kCoinIcon, size: 16, color: kCoinColor)),
                ),
                const SizedBox(height: 8),
                TextField(controller: _note[r.index], maxLength: kMaxListingNote, decoration: const InputDecoration(labelText: 'Trade note (optional)')),
              ]),
            ),
          FilledButton(
            onPressed: () {
              _save();
              GameScope.read(context).toast('Presets saved');
              Navigator.pop(context);
            },
            child: const Text('Save presets'),
          ),
        ]),
      ),
    );
  }
}

/// Convenience to open the composer for an owned card.
Future<bool> openComposer(BuildContext context, List<int> uids) async =>
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ListingComposer(initialUids: uids))) ?? false;
