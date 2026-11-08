import 'package:flutter/material.dart';

import '../../data/profile.dart';
import '../../game/store_catalog.dart';
import '../app.dart';
import '../widgets/cards.dart';
import '../widgets/stick_figure.dart';
import 'card_detail_screen.dart';
import 'favorite_artists_screen.dart';
import 'playlists_screen.dart';
import 'quests_screen.dart';
import 'scrapyard_screen.dart';
import 'settings_screen.dart';

const _palette = [
  0xFFE9E6FF,
  0xFF9A8CF0,
  0xFF00E5FF,
  0xFF18FFFF,
  0xFF64FFDA,
  0xFF69F0AE,
  0xFFB2FF59,
  0xFFEEFF41,
  0xFFFFFF00,
  0xFFFFD740,
  0xFFFFAB40,
  0xFFFF6E40,
  0xFFFF5252,
  0xFFFF4081,
  0xFFE040FB,
  0xFF7C4DFF,
  0xFF536DFE,
  0xFF448AFF,
  0xFFFFFFFF,
  0xFFBDBDBD,
];

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final look = FigureLook(color: Color(p.figureColor), hat: p.hat, shirt: p.shirt, pet: p.pet, backpack: p.backpack);
    final hsv = HSVColor.fromColor(Color(p.figureColor));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: AdaptivePanes(
        flex: const [5, 6, 5],
        panes: [
          [
            Center(child: StickFigure(look: look, size: 150)),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.edit, size: 16),
                label: Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                onPressed: () async {
                  final n = await promptText(context, 'Trainer name', 'Name', initial: p.name);
                  if (n != null && n.isNotEmpty) {
                    p.name = n.length > 24 ? n.substring(0, 24) : n;
                    p.changed();
                  }
                },
              ),
            ),
            Center(
              child: Text('Level ${p.level} • ${formatNumber(p.xp)} XP', style: const TextStyle(color: Colors.white60)),
            ),
            const SizedBox(height: 16),
            const Text('Figure colour (free)', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _palette)
                  GestureDetector(
                    onTap: () {
                      p.figureColor = c;
                      p.changed();
                    },
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(color: p.figureColor == c ? Colors.white : Colors.transparent, width: 3),
                      ),
                    ),
                  ),
              ],
            ),
            Row(
              children: [
                const Text('Hue'),
                Expanded(
                  child: Slider(
                    value: hsv.hue,
                    max: 360,
                    onChanged: (v) {
                      p.figureColor = HSVColor.fromAHSV(1, v, hsv.saturation.clamp(0.6, 1.0), hsv.value.clamp(0.8, 1.0)).toColor().toARGB32();
                      p.changed();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Equipped', style: TextStyle(fontWeight: FontWeight.w800)),
            Wrap(
              spacing: 8,
              children: [
                for (final e in {ProductKind.hat: p.hat, ProductKind.shirt: p.shirt, ProductKind.backpack: p.backpack, ProductKind.pet: p.pet}.entries)
                  if (e.value != null) InputChip(label: Text(productById(e.value!)?.name ?? e.value!), onDeleted: () => g.equip(e.key, null)),
                ActionChip(avatar: const Icon(Icons.checkroom, size: 16), label: const Text('Wardrobe & store'), onPressed: () => HomeShell.goTo(context, 3)),
              ],
            ),
          ],
          [
            if (!isWideLayout(context)) const SizedBox(height: 16),
            FavoriteArtistsTab(
              artists: p.favoriteArtists,
              onEdit: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FavoriteArtistsScreen())),
            ),
            const SizedBox(height: 12),
            _Stats(p: p, cards: g.collection.length, unique: g.collection.uniqueSongCount),
          ],
          [
            if (!isWideLayout(context)) const SizedBox(height: 12),
            _NavTile(icon: Icons.assignment, title: 'Quests', subtitle: 'Daily tasks, artist spotlights & milestones', page: const QuestsScreen()),
            _NavTile(icon: Icons.recycling_rounded, title: 'Scrapyard', subtitle: '${p.cardsScrapped} songs scrapped', page: const ScrapyardScreen()),
            _NavTile(icon: Icons.queue_music, title: 'Playlists', subtitle: '${p.playlists.length} playlists', page: const PlaylistsScreen()),
            _NavTile(
              icon: Icons.settings,
              title: 'Settings',
              subtitle: p.debugEnabled ? 'Debug menu enabled' : 'Audio, market server, debug',
              page: const SettingsScreen(),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.p, required this.cards, required this.unique});
  final PlayerProfile p;
  final int cards;
  final int unique;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Cards', formatNumber(cards)),
      ('Unique songs', formatNumber(unique)),
      ('Caught', formatNumber(p.totalCaught)),
      ('Shinies caught', formatNumber(p.shinyCaught)),
      ('Distance', '${(p.metersWalked / 1000).toStringAsFixed(1)} km'),
      ('Packs opened', formatNumber(p.packsOpened)),
      ('Sold', formatNumber(p.cardsSold)),
      ('Scrapped', formatNumber(p.cardsScrapped)),
      ('Trades', formatNumber(p.tradesCompleted)),
    ];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.6,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: [
        for (final (k, v) in items)
          Container(
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kOutline),
            ),
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  child: Text(v, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ),
                Text(
                  k,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10, color: Colors.white54),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.title, required this.subtitle, required this.page});
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
    ),
  );
}
