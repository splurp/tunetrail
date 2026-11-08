import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../game/store_catalog.dart';
import '../app.dart';
import '../widgets/cards.dart';

/// Developer tools: balances, free purchases, movement overrides and
/// stress tests.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});
  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  late final _coins = TextEditingController(text: '${GameScope.read(context).profile.coins}');
  late final _bits = TextEditingController(text: '${GameScope.read(context).profile.bits}');
  bool _generating = false;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Debug menu')),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        const _H('Balances'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: TextField(controller: _coins, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Coins', prefixIcon: Icon(kCoinIcon, color: kCoinColor)))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _bits, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Bits', prefixIcon: Icon(kBitsIcon, color: kBitsColor)))),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () {
                g.debugSetBalances(coins: int.tryParse(_coins.text), bits: int.tryParse(_bits.text));
                g.toast('Balances set');
              },
              child: const Text('Set'),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, children: [
            for (final v in [1000, 100000, 10000000])
              ActionChip(
                label: Text('${formatNumber(v)} each'),
                onPressed: () {
                  g.debugSetBalances(coins: v, bits: v);
                  _coins.text = '$v';
                  _bits.text = '$v';
                },
              ),
          ]),
        ),
        const _H('Purchases'),
        SwitchListTile(
          title: const Text('Free real-money purchases'),
          subtitle: const Text('Bits, map themes and cosmetics are granted without charging'),
          value: p.freePurchases,
          onChanged: (v) {
            p.freePurchases = v;
            p.changed();
          },
        ),
        ListTile(
          title: const Text('Unlock every store item now'),
          trailing: const Icon(Icons.lock_open),
          onTap: () {
            for (final it in kAllProducts) {
              if (it.kind != ProductKind.bits) p.owned.add(it.id);
            }
            p.changed();
            g.toast('All themes & cosmetics unlocked');
          },
        ),
        ListTile(
          title: const Text('Reset store unlocks'),
          trailing: const Icon(Icons.lock),
          onTap: () {
            p.owned = {'theme_classic'};
            p.activeTheme = 'theme_classic';
            p.hat = p.shirt = p.pet = p.backpack = null;
            p.changed();
          },
        ),
        const _H('Movement'),
        SwitchListTile(
          title: const Text('Joystick movement'),
          subtitle: const Text('Move anywhere without walking (also WASD / arrow keys on PC)'),
          value: p.joystickEnabled,
          onChanged: g.setJoystick,
        ),
        ListTile(
          title: Text('Joystick speed ×${p.speedMultiplier.toStringAsFixed(0)}'),
          subtitle: Slider(value: p.speedMultiplier, min: 1, max: 50, divisions: 49, onChanged: (v) {
            g.setSpeed(v);
            setState(() {});
          }),
        ),
        SwitchListTile(
          title: const Text('Unlimited catch range'),
          value: p.unlimitedRange,
          onChanged: (v) {
            p.unlimitedRange = v;
            p.changed();
          },
        ),
        ListTile(
          leading: const Icon(Icons.travel_explore),
          title: const Text('Teleport to a location…'),
          subtitle: Text('Now: ${g.location.position.latitude.toStringAsFixed(5)}, ${g.location.position.longitude.toStringAsFixed(5)}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TeleportScreen())),
        ),
        ListTile(leading: const Icon(Icons.refresh), title: const Text('Respawn nearby songs'), onTap: g.debugRespawn),
        const _H('Collection stress test'),
        ListTile(
          title: Text('${formatNumber(g.collection.length)} cards • ${formatNumber(g.catalog.size)} songs in catalog'),
          subtitle: Text(g.catalog.crawling ? 'Catalog crawl running: ${g.catalog.crawlStatus}' : 'Catalog idle'),
          trailing: g.catalog.crawling ? null : TextButton(onPressed: () => g.catalog.crawl(targetSongs: 200000), child: const Text('Crawl more')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final n in [1000, 10000, 100000])
              FilledButton.tonal(
                onPressed: _generating
                    ? null
                    : () async {
                        setState(() => _generating = true);
                        final sw = Stopwatch()..start();
                        final added = await g.debugGenerateCards(n);
                        if (mounted) setState(() => _generating = false);
                        g.toast(added == 0 ? 'Catalog is empty — wait for songs to load' : 'Added ${formatNumber(added)} cards in ${sw.elapsedMilliseconds} ms');
                      },
                child: Text('+${formatNumber(n)} cards'),
              ),
            OutlinedButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear collection?'),
                    content: const Text('Deletes every card you own.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                    ],
                  ),
                );
                if (ok == true) g.debugClearCollection();
              },
              child: const Text('Clear collection'),
            ),
          ]),
        ),
        if (_generating) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _H extends StatelessWidget {
  const _H(this.t);
  final String t;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(t.toUpperCase(), style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1.2)),
      );
}

/// Search any real-world place (OpenStreetMap Nominatim) and jump there.
class TeleportScreen extends StatefulWidget {
  const TeleportScreen({super.key});
  @override
  State<TeleportScreen> createState() => _TeleportScreenState();
}

class _TeleportScreenState extends State<TeleportScreen> {
  final _q = TextEditingController();
  List<(String, LatLng)> _results = [];
  bool _loading = false;
  String? _error;

  static const _presets = [
    ('Times Square, New York', LatLng(40.7580, -73.9855)),
    ('Abbey Road, London', LatLng(51.5320, -0.1778)),
    ('Shibuya Crossing, Tokyo', LatLng(35.6595, 139.7005)),
    ('Eiffel Tower, Paris', LatLng(48.8584, 2.2945)),
    ('Sydney Opera House', LatLng(-33.8568, 151.2153)),
    ('Hollywood Blvd, Los Angeles', LatLng(34.1016, -118.3267)),
    ('Beale Street, Memphis', LatLng(35.1395, -90.0526)),
    ('Copacabana, Rio de Janeiro', LatLng(-22.9711, -43.1822)),
  ];

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {'q': q, 'format': 'jsonv2', 'limit': '15'});
      final res = await http.get(uri, headers: {'User-Agent': 'Tunetrail/0.1 (developer build)'}).timeout(const Duration(seconds: 15));
      final list = jsonDecode(res.body) as List;
      setState(() {
        _results = [
          for (final r in list.cast<Map<String, dynamic>>())
            (r['display_name'] as String? ?? '?', LatLng(double.parse(r['lat'] as String), double.parse(r['lon'] as String))),
        ];
        if (_results.isEmpty) _error = 'No places found';
      });
    } catch (e) {
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _go(String name, LatLng p) {
    final g = GameScope.read(context);
    g.teleport(p);
    g.toast('Teleported to ${name.split(',').first}');
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Teleport')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        TextField(
          controller: _q,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: 'Search a city, street, landmark…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        for (final (name, p) in _results)
          ListTile(leading: const Icon(Icons.place), title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () => _go(name, p)),
        const Padding(padding: EdgeInsets.fromLTRB(4, 16, 4, 4), child: Text('Quick destinations', style: TextStyle(fontWeight: FontWeight.w800))),
        for (final (name, p) in _presets)
          ListTile(leading: const Icon(Icons.flight_takeoff), title: Text(name), onTap: () => _go(name, p)),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('Search by OpenStreetMap Nominatim', style: TextStyle(fontSize: 11, color: Colors.white38)),
        ),
      ]),
    );
  }
}
