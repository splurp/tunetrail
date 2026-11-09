import 'package:flutter/material.dart';

import 'package:tunetrail_core/tunetrail_core.dart' show Edition;

import '../../data/collection.dart';
import '../../data/profile.dart';
import '../../data/samples.dart';
import '../../game/store_catalog.dart';
import '../app.dart';
import '../widgets/figure_preview.dart';
import '../widgets/profile_banner.dart';
import '../widgets/cards.dart';
import '../widgets/stick_figure.dart';
import 'card_detail_screen.dart';
import 'collection_screen.dart';
import 'favorite_artists_screen.dart';
import 'messages_screen.dart';
import 'onboarding_screen.dart' show showChangeUsername;
import 'player_screen.dart';
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
            ProfileBanner(
              themeId: p.profileTheme,
              name: p.name,
              subtitle: 'Level ${p.level} • ${formatNumber(p.xp)} XP',
              actions: [
                _BannerButton(icon: Icons.edit, tooltip: 'Change username', onTap: () => showChangeUsername(context)),
                const SizedBox(width: 6),
                _BannerButton(
                  icon: Icons.palette_outlined,
                  tooltip: 'Profile theme',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProfileThemePicker())),
                ),
                const SizedBox(width: 6),
                _BannerButton(
                  icon: Icons.visibility_outlined,
                  tooltip: 'See my profile as others do',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(playerId: p.playerId))),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(child: Figure3DPreview(look: look, size: 190)),
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
            const _EditionShowcase(),
            const SizedBox(height: 16),
            FavoriteArtistsTab(
              artists: p.favoriteArtists,
              onEdit: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FavoriteArtistsScreen())),
            ),
            const SizedBox(height: 12),
            _Stats(p: p, cards: g.collection.length, unique: g.collection.uniqueSongCount),
          ],
          [
            if (!isWideLayout(context)) const SizedBox(height: 12),
            _NavTile(icon: Icons.chat_bubble_outline, title: 'Messages', subtitle: 'Chats with other players', page: const ConversationsScreen()),
            _NavTile(icon: Icons.palette_outlined, title: 'Profile theme', subtitle: 'How your profile looks to others', page: const ProfileThemePicker()),
            _NavTile(icon: Icons.assignment, title: 'Quests', subtitle: 'Daily tasks, artist spotlights & milestones', page: const QuestsScreen()),
            _NavTile(icon: Icons.recycling_rounded, title: 'Scrapyard', subtitle: '${p.cardsScrapped} songs scrapped', page: const ScrapyardScreen()),
            _NavTile(icon: Icons.queue_music, title: 'Playlists', subtitle: '${p.playlists.length} playlists', page: const PlaylistsScreen()),
            _NavTile(icon: Icons.settings, title: 'Settings', subtitle: p.debugEnabled ? 'Debug menu enabled' : 'Audio, market server, debug', page: const SettingsScreen()),
          ],
        ],
      ),
    );
  }
}

class _BannerButton extends StatelessWidget {
  const _BannerButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Padding(padding: const EdgeInsets.all(7), child: Icon(icon, size: 18, color: Colors.white))),
        ),
      );
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

/// Up to three Canvas / Sample cards the player shows off on their profile.
/// Tap one for the full card; the corner button plays it in place.
class _EditionShowcase extends StatelessWidget {
  const _EditionShowcase();

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    // Drop cards that were sold or scrapped since.
    final cards = [for (final uid in p.editionShowcase) ?g.collection.byUid(uid)];
    Future<void> add() async {
      final picked = await pickCards(
        context,
        title: 'Showcase a Canvas, Sample or Live card',
        exclude: p.editionShowcase.toSet(),
        query: const CollectionQuery(editionMask: 0xE),
      );
      if (picked == null || picked.isEmpty) return;
      final c = g.collection.byUid(picked.first);
      if (c == null || c.edition == Edition.standard) {
        g.toast('Only Canvas, Sample and Live editions can be showcased here');
        return;
      }
      p.editionShowcase = [...p.editionShowcase.where((u) => g.collection.byUid(u) != null), c.uid].take(3).toList();
      p.changed();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Showcase', style: TextStyle(fontWeight: FontWeight.w800)),
        const Spacer(),
        Text('Canvas, Sample & Live', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
      ]),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, box) {
        const gap = 8.0;
        final w = (box.maxWidth - gap * 2) / 3;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            SizedBox(
              width: w,
              child: i < cards.length
                  ? _ShowcaseCard(
                      card: cards[i],
                      width: w,
                      onRemove: () {
                        p.editionShowcase = [...p.editionShowcase]..remove(cards[i].uid);
                        p.changed();
                      },
                    )
                  : GestureDetector(
                      onTap: add,
                      child: Container(
                        height: w * 1.48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(w * 0.07),
                          border: Border.all(color: Colors.white24),
                          color: Colors.white.withValues(alpha: 0.03),
                        ),
                        child: const Icon(Icons.add, color: Colors.white38),
                      ),
                    ),
            ),
          ],
        ]);
      }),
    ]);
  }
}

class _ShowcaseCard extends StatelessWidget {
  const _ShowcaseCard({required this.card, required this.width, required this.onRemove});
  final OwnedCard card;
  final double width;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final sample = card.edition == Edition.sample ? SampleLibrary.of(card.song.id) : null;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CardDetailScreen(uid: card.uid))),
      onLongPress: onRemove,
      child: Stack(children: [
        SongCardView(song: card.song, rarity: card.rarity, shiny: card.shiny, edition: card.edition, serial: card.serial, width: width),
        Positioned(
          right: 4,
          bottom: 4,
          child: ListenableBuilder(
            listenable: Listenable.merge([g.audio, g.samples]),
            builder: (context, _) {
              final playing = sample != null
                  ? g.samples.value.songId == card.song.id && g.samples.value.active
                  : g.audio.playing && g.audio.current?.id == card.song.id;
              return Material(
                color: Colors.black.withValues(alpha: 0.6),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    if (playing) {
                      sample != null ? g.samples.stop() : g.audio.stop();
                    } else if (sample != null) {
                      g.samples.play(sample);
                    } else {
                      g.audio.playOne(card.song.id);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18, color: Colors.white),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
