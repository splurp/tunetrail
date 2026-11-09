import 'package:flutter/material.dart';

import '../../build_flags.dart';

import '../../game/audio_service.dart';

import '../../data/profile.dart';
import '../app.dart';
import 'card_detail_screen.dart';
import '../widgets/ui_kit.dart';
import '../../game/google_auth.dart';
import 'copyright_screen.dart';
import 'onboarding_screen.dart' show showChangeUsername;
import 'admin_reports_screen.dart';
import 'debug_screen.dart';
import 'listing_composer.dart';

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
      body: AdaptivePanes(padding: const EdgeInsets.symmetric(vertical: 8), panes: [
       [
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
          title: const Text('Sound effects'),
          subtitle: const Text('Catches, listings, quicksells, sales and trades'),
          value: p.soundEffects,
          onChanged: (v) {
            p.soundEffects = v;
            g.audio.sfxEnabled = v;
            p.changed();
            if (v) g.audio.playSfx(Sfx.catchSong);
          },
        ),
        SwitchListTile(
          title: const Text('Play song preview during encounters'),
          value: p.playOnEncounter,
          onChanged: (v) {
            p.playOnEncounter = v;
            p.changed();
          },
        ),
        SwitchListTile(
          title: const Text('Keep playing after a catch'),
          subtitle: const Text('Off: the preview stops once the song is caught'),
          value: p.keepPlayingAfterCatch,
          onChanged: (v) {
            p.keepPlayingAfterCatch = v;
            p.changed();
          },
        ),
        ListTile(
          title: Text('Catch ring timing  ${p.beatOffsetMs >= 0 ? '+' : ''}${p.beatOffsetMs} ms'),
          subtitle: Slider(
            min: -150,
            max: 150,
            divisions: 60,
            value: p.beatOffsetMs.toDouble().clamp(-150, 150),
            label: '${p.beatOffsetMs} ms',
            onChanged: (v) {
              p.beatOffsetMs = v.round();
              p.changed();
            },
          ),
          trailing: const Tooltip(message: 'If the ring lands before the beat you hear, move this right (later).', child: Icon(Icons.info_outline, size: 18)),
        ),
       ],
       [
        const _Header('Graphics'),
        SwitchListTile(
          title: const Text('Show buildings'),
          subtitle: const Text('Low-poly city buildings at their real heights (OpenStreetMap via OpenFreeMap), alongside the roads'),
          value: p.showBuildings,
          onChanged: g.setShowBuildings,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.battery_saver_outlined),
          title: const Text('Battery Saver'),
          subtitle: const Text('Limits the game to 60 FPS and turns off theme particles'),
          value: p.batterySaver,
          onChanged: (v) {
            p.batterySaver = v;
            p.changed();
          },
        ),
        if (kAdminBuild) ...[
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
        ListTile(
          title: const Text('Last.fm API key (song popularity)'),
          subtitle: Text(
            p.effectiveLastFmKey.isEmpty
                ? 'Not set: rarity uses Deezer popularity. Add a free key from last.fm/api for play-count based rarity.'
                : p.lastFmKey.isEmpty
                    ? 'Using the key built into this version'
                    : 'Custom key set',
          ),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final v = await promptText(context, 'Last.fm API key', 'Paste your API key', initial: p.lastFmKey);
            if (v != null) {
              g.setLastFmKey(v);
              g.toast(v.trim().isEmpty ? 'Last.fm key cleared' : 'Fetching play counts in the background…');
            }
          },
        ),
        ],
       ],
       [
        const _Header('Account'),
        if (p.authToken.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.verified_user, color: kAccent),
            title: Text(p.usernameSet ? 'Signed in as ${p.name}' : 'Signed in'),
            subtitle: const Text('Google account · your market activity follows you to any device'),
            trailing: TextButton(onPressed: () => g.signOut(), child: const Text('Sign out')),
          ),
        if (p.authToken.isNotEmpty || !g.onlineAccounts)
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: const Text('Username'),
            subtitle: Text(p.usernameSet ? '${p.name} · ${p.usernameChanges == 0 ? 'first change free' : 'change for 100 bits'}' : 'Not chosen yet'),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () => showChangeUsername(context),
          ),
        if (p.authToken.isEmpty)
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('Sign in with Google'),
            subtitle: Text(GoogleAuth.available
                ? 'Needed to trade on the online market'
                : 'Not configured in this build (see docs/multiplayer-setup.md) — playing as a guest'),
            enabled: GoogleAuth.available,
            onTap: () async {
              final err = await g.signInWithGoogle();
              g.toast(err ?? 'Signed in');
            },
          ),
        const _Header('Market'),
        ListTile(
          title: const Text('Quick-list presets'),
          subtitle: const Text('Price and trade note for each rarity'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickListPresetsScreen())),
        ),
        // Server and developer tools exist only in admin builds.
        if (kAdminBuild) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(child: TextField(controller: _server, decoration: const InputDecoration(labelText: 'Server URL (admin)'))),
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
            subtitle: Text(p.isAdmin || PlayerProfile.builtInServer.isEmpty ? 'Balances, free purchases, joystick, teleport, stress tests' : 'Only for admin accounts'),
            value: p.debugEnabled,
            onChanged: p.isAdmin || PlayerProfile.builtInServer.isEmpty ? g.setDebug : null,
          ),
          if (p.isAdmin)
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: kAccent),
              title: const Text('Player reports'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AdminReportsScreen())),
            ),
          if (p.debugEnabled)
            ListTile(
              leading: const Icon(Icons.bug_report, color: kAccent),
              title: const Text('Open debug menu'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DebugScreen())),
            ),
        ],
        const _Header('About'),
        ListTile(
          leading: const Icon(Icons.copyright),
          title: const Text('Copyright & DMCA'),
          subtitle: const Text('How music appears in the game · notices and opt-outs: $kCopyrightEmail'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CopyrightScreen())),
        ),
        const ListTile(
          title: Text('Tunetrail · $kAppVersion${kAdminBuild ? ' (admin build)' : ''}'),
          subtitle: Text('Song data, artwork & previews: Deezer and Apple. Maps: © OpenStreetMap contributors (OpenFreeMap, VersaTiles).'),
        ),
        ListTile(title: const Text('Player ID'), subtitle: SelectableText(p.playerId)),
        SizedBox(height: 24 + MediaQuery.viewPaddingOf(context).bottom),
       ],
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
        child: Text(text.toUpperCase(), style: const TextStyle(color: kTextTertiary, fontWeight: FontWeight.w600, fontSize: 11, letterSpacing: 1.2)),
      );
}
