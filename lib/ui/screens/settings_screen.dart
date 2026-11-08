import 'package:flutter/material.dart';

import '../../data/profile.dart';
import '../app.dart';
import 'card_detail_screen.dart';
import 'debug_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _server = TextEditingController(text: GameScope.read(context).profile.serverUrl);

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        const _Header('Audio'),
        ListTile(
          title: const Text('Preview volume'),
          subtitle: Slider(
            value: p.volume,
            onChanged: (v) {
              p.volume = v;
              g.audio.setVolume(v);
              p.changed();
            },
          ),
        ),
        SwitchListTile(
          title: const Text('Play song preview during encounters'),
          value: p.playOnEncounter,
          onChanged: (v) {
            p.playOnEncounter = v;
            p.changed();
          },
        ),
        const _Header('Graphics'),
        SwitchListTile(
          title: const Text('Reduce map effects'),
          subtitle: const Text('Disables theme particles (saves battery)'),
          value: p.reduceEffects,
          onChanged: (v) {
            p.reduceEffects = v;
            p.changed();
          },
        ),
        ListTile(
          title: const Text('Map tile server'),
          subtitle: Text(p.tileUrl.isEmpty ? 'OpenStreetMap (default)' : p.tileUrl, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final v = await promptText(context, 'Tile URL template', 'https://…/{z}/{x}/{y}.png (blank = OpenStreetMap)', initial: p.tileUrl);
            if (v != null) {
              p.tileUrl = v;
              p.changed();
            }
          },
        ),
        const _Header('Market'),
        RadioGroup<MarketMode>(
          groupValue: p.marketMode,
          onChanged: (m) => g.setMarketMode(m!, _server.text.trim()),
          child: const Column(children: [
            RadioListTile(value: MarketMode.local, title: Text('Local market'), subtitle: Text('Offline, with simulated NPC traders')),
            RadioListTile(value: MarketMode.online, title: Text('Online market server'), subtitle: Text('Trade with real players (see server/ in the repo)')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: TextField(controller: _server, decoration: const InputDecoration(labelText: 'Server URL', hintText: 'http://192.168.1.10:8080'))),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () async {
                await g.setMarketMode(MarketMode.online, _server.text.trim());
                g.toast('Market: ${g.market.label}');
              },
              child: const Text('Connect'),
            ),
          ]),
        ),
        const _Header('Developer'),
        SwitchListTile(
          title: const Text('Debug menu'),
          subtitle: const Text('Balances, free purchases, joystick, teleport, stress tests'),
          value: p.debugEnabled,
          onChanged: g.setDebug,
        ),
        if (p.debugEnabled)
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.orangeAccent),
            title: const Text('Open debug menu'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DebugScreen())),
          ),
        const _Header('About'),
        const ListTile(
          title: Text('Tunetrail — developer build'),
          subtitle: Text('Song data, artwork & previews: Deezer API. Maps: © OpenStreetMap contributors. Geocoding: Nominatim.'),
        ),
        ListTile(title: const Text('Player ID'), subtitle: SelectableText(p.playerId)),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text.toUpperCase(), style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1.2)),
      );
}
