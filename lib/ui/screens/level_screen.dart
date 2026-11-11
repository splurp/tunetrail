import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart';

import '../../game/game.dart';
import '../app.dart';
import '../widgets/cards.dart';

IconData bonusIcon(Bonus b) => switch (b) {
      Bonus.scrap => Icons.recycling,
      Bonus.spawn => Icons.radar,
      Bonus.xp => Icons.trending_up,
      Bonus.rarity => Icons.auto_awesome,
    };

/// What a bonus adds up to right now ("+15% coins from scrapping").
String bonusEffect(Bonus b, int n) => switch (b) {
      Bonus.scrap => '+${5 * n}% coins from scrapping',
      Bonus.spawn => '+${5 * n}% songs spawning around you',
      Bonus.xp => '+${5 * n}% XP',
      Bonus.rarity => '+${5 * n}% Uncommon · +${4 * n}% Rare · +${3 * n}% Epic · +${2 * n}% Legendary · +$n% Shiny',
    };

/// Asks which bonus to take (one for every five levels). Returns once
/// there's nothing left to choose, or the player puts it off.
Future<void> showBonusChooser(BuildContext context) async {
  final g = GameScope.read(context);
  final nav = Navigator.of(context);
  while (nav.mounted && g.profile.bonuses.unspent(g.profile.level) > 0) {
    final left = g.profile.bonuses.unspent(g.profile.level);
    final pick = await showDialog<Bonus>(
      // ignore: use_build_context_synchronously
      context: nav.context,
      builder: (ctx) => AlertDialog(
        title: Text('Level ${g.profile.level} — choose a bonus'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Every $kLevelsPerBonus levels you pick a permanent bonus for your account${left > 1 ? ' ($left to choose)' : ''}.',
              style: const TextStyle(color: kTextSecondary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            for (final b in Bonus.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(bonusIcon(b), color: kAccent),
                title: Text(b.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(b.description, style: const TextStyle(fontSize: 12)),
                trailing: g.profile.bonuses.of(b) > 0 ? Text('×${g.profile.bonuses.of(b)}', style: const TextStyle(color: kTextSecondary)) : null,
                onTap: () => Navigator.pop(ctx, b),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later'))],
      ),
    );
    if (pick == null) return;
    try {
      await g.world.chooseBonus(pick);
      g.toast('${pick.label} bonus added');
    } catch (e) {
      g.toast('$e');
      return;
    }
  }
}

/// The player's level: XP to the next one, the bonuses they hold, and
/// choosing them again for bits.
class LevelScreen extends StatelessWidget {
  const LevelScreen({super.key});

  Future<void> _respec(BuildContext context, Game g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose your bonuses again?'),
        content: Text('Every bonus you chose is handed back so you can pick again. This costs $kRespecBits bits (you have ${formatNumber(g.profile.bits)}).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: g.profile.bits < kRespecBits ? null : () => Navigator.pop(ctx, true), child: const Text('Re-spec · $kRespecBits bits')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await g.world.respec();
    } catch (e) {
      g.toast('$e');
      return;
    }
    if (context.mounted) await showBonusChooser(context);
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final lvl = p.level;
    final need = xpToNextLevel(lvl), into = p.xp - xpForLevel(lvl);
    final b = p.bonuses;
    final unspent = b.unspent(lvl);
    final nextAt = (lvl ~/ kLevelsPerBonus + 1) * kLevelsPerBonus;
    return Scaffold(
      appBar: AppBar(title: const Text('Level')),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Row(children: [
            SizedBox(
              width: 92,
              height: 92,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(value: need == 0 ? 1 : (into / need).clamp(0.0, 1.0), strokeWidth: 6, color: kAccent, backgroundColor: Colors.white10),
                ),
                Text('$lvl', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${formatNumber(p.xp)} XP in total', style: const TextStyle(color: kTextSecondary)),
                const SizedBox(height: 4),
                Text(
                  need == 0 ? 'Top level reached' : '${formatNumber(need - into)} XP to level ${lvl + 1}  (${formatNumber(into)} / ${formatNumber(need)})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 24),
          const SectionLabel('Bonuses'),
          if (unspent > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FilledButton.icon(
                icon: const Icon(Icons.add_circle_outline),
                label: Text(unspent == 1 ? 'Choose a bonus' : 'Choose $unspent bonuses'),
                onPressed: () => showBonusChooser(context),
              ),
            )
          else if (lvl < kMaxLevel)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('Your next bonus comes at level $nextAt.', style: const TextStyle(color: kTextSecondary, fontSize: 13)),
            ),
          for (final k in Bonus.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(bonusIcon(k), color: b.of(k) > 0 ? kAccent : kTextTertiary),
              title: Text(k.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(b.of(k) > 0 ? bonusEffect(k, b.of(k)) : k.description, style: const TextStyle(fontSize: 12)),
              trailing: Text(b.of(k) > 0 ? '×${b.of(k)}' : '—', style: TextStyle(fontWeight: FontWeight.w700, color: b.of(k) > 0 ? Colors.white : kTextTertiary)),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Re-spec bonuses · $kRespecBits bits'),
              onPressed: b.chosenTotal == 0 || !g.serverEconomy ? null : () => _respec(context, g),
            ),
          ),
          const SizedBox(height: 24),
          const SectionLabel('Earning XP'),
          for (final line in const [
            '+5 XP for Commons',
            '+10 XP for Uncommons',
            '+20 XP for Rares',
            '+50 XP for Epics',
            '+100 XP for Legendaries',
            'Shinies: 5× the XP of their rarity',
            '+1,000 XP for Canvas editions',
            '+2,000 XP for Sample and Live editions',
            '+$kTradeXp XP for each completed trade',
            '+5 XP for each bit won in minigames',
            '+$kDjBattleXp XP for winning a DJ battle',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(line, style: const TextStyle(color: kTextSecondary, fontSize: 13)),
            ),
        ]),
      ),
    );
  }
}
