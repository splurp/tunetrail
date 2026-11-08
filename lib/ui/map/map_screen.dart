import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../data/profile.dart';
import '../../game/game.dart';
import '../../game/spawns.dart';
import '../app.dart';
import '../screens/debug_screen.dart';
import '../screens/encounter_screen.dart';
import '../screens/quests_screen.dart';
import '../widgets/cards.dart';
import '../widgets/joystick.dart';
import '../widgets/stick_figure.dart';
import 'map_themes.dart';
import 'spawn_marker.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  final MapController _map = MapController();
  final ValueNotifier<double> _clock = ValueNotifier(0);
  late final Ticker _ticker;
  bool _ready = false;
  double _zoom = 17.6;
  final Set<LogicalKeyboardKey> _keys = {};
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      _clock.value = d.inMicroseconds / 1e6;
    })
      ..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final g = GameScope.of(context);
    g.location.removeListener(_follow);
    g.location.addListener(_follow);
  }

  void _follow() {
    if (!_ready || !mounted) return;
    final g = GameScope.read(context);
    _map.move(g.location.position, _map.camera.zoom);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onKey(KeyEvent e) {
    final g = GameScope.read(context);
    if (!g.location.joystickMode) return;
    if (e is KeyDownEvent) _keys.add(e.logicalKey);
    if (e is KeyUpEvent) _keys.remove(e.logicalKey);
    double x = 0, y = 0;
    if (_keys.contains(LogicalKeyboardKey.keyW) || _keys.contains(LogicalKeyboardKey.arrowUp)) y += 1;
    if (_keys.contains(LogicalKeyboardKey.keyS) || _keys.contains(LogicalKeyboardKey.arrowDown)) y -= 1;
    if (_keys.contains(LogicalKeyboardKey.keyD) || _keys.contains(LogicalKeyboardKey.arrowRight)) x += 1;
    if (_keys.contains(LogicalKeyboardKey.keyA) || _keys.contains(LogicalKeyboardKey.arrowLeft)) x -= 1;
    g.location.setJoystick(x, y);
  }

  Future<void> _tapSpawn(Game g, Spawn s) async {
    if (!g.inRange(s)) {
      final d = metersBetween(g.location.position, s.point).round();
      g.toast('Too far away — get within ${Game.catchRangeMeters.round()} m (currently $d m)');
      return;
    }
    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (_, a, _) => FadeTransition(opacity: a, child: EncounterScreen(spawn: s)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final theme = themeById(p.activeTheme);
    final look = FigureLook(color: Color(p.figureColor), hat: p.hat, shirt: p.shirt, pet: p.pet, backpack: p.backpack);
    final pos = g.location.position;
    final sorted = [...g.spawns]..sort((a, b) => a.rarity.index.compareTo(b.rarity.index));

    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: pos,
            initialZoom: _zoom,
            minZoom: 15,
            maxZoom: 19.5,
            backgroundColor: theme.background,
            onMapReady: () => _ready = true,
            onPositionChanged: (cam, _) => _zoom = cam.zoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom | InteractiveFlag.scrollWheelZoom | InteractiveFlag.rotate,
            ),
          ),
          children: [
            _themed(
              theme,
              TileLayer(
                urlTemplate: p.tileUrl.isNotEmpty ? p.tileUrl : theme.tiles,
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.tunetrail.tunetrail',
                maxNativeZoom: 19,
              ),
            ),
            ListenableBuilder(
              listenable: g.location,
              builder: (context, _) => CircleLayer(circles: [
              CircleMarker(
                point: g.location.position,
                radius: Game.catchRangeMeters,
                useRadiusInMeter: true,
                color: theme.accent.withValues(alpha: 0.08),
                borderColor: theme.accent.withValues(alpha: 0.5),
                borderStrokeWidth: 1.5,
              ),
            ]),
            ),
            ListenableBuilder(
              listenable: g.location,
              builder: (context, _) => MarkerLayer(
              rotate: true,
              markers: [
                for (final s in sorted)
                  Marker(
                    key: ValueKey(s.id),
                    point: s.point,
                    width: 100,
                    height: 100,
                    child: SpawnMarker(spawn: s, clock: _clock, inRange: g.inRange(s), onTap: () => _tapSpawn(g, s)),
                  ),
              ],
            ),
            ),
          ],
        ),
        // Theme overlay effect.
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: _clock,
                builder: (context, t, _) => CustomPaint(painter: MapEffectPainter(theme, t, reduce: p.reduceEffects)),
              ),
            ),
          ),
        ),
        // Player, always at the centre of the map.
        IgnorePointer(
          child: Center(
            child: Transform.translate(
              offset: const Offset(0, -50),
              child: ListenableBuilder(
                listenable: g.location,
                builder: (context, _) => StickFigure(look: look, walking: g.location.moving, size: 90),
              ),
            ),
          ),
        ),
        // HUD.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _TopBar(g: g),
              if (g.catalog.crawling && g.catalog.size < 300)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(child: _Pill(text: g.catalog.crawlStatus.isEmpty ? 'Loading songs…' : g.catalog.crawlStatus)),
                ),
              if (g.catalog.size == 0 && !g.catalog.crawling)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Center(child: _Pill(text: 'Offline — connect to the internet to find songs')),
                ),
              if (g.location.gpsError != null && !g.location.joystickMode)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(child: _Pill(text: '${g.location.gpsError}${p.debugEnabled ? '' : ' • enable Debug → Joystick to explore'}')),
                ),
              const Spacer(),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (g.location.joystickMode)
                  Joystick(onChanged: g.location.setJoystick)
                else
                  const SizedBox(width: 10),
                const Spacer(),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  if (p.debugEnabled)
                    _RoundButton(
                      icon: Icons.travel_explore,
                      tooltip: 'Teleport',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TeleportScreen())),
                    ),
                  _RoundButton(
                    icon: Icons.assignment,
                    tooltip: 'Quests',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuestsScreen())),
                  ),
                  _RoundButton(
                    icon: Icons.radar,
                    tooltip: 'Nearby songs',
                    badge: g.spawns.length,
                    onTap: () => _showNearby(g),
                  ),
                  _RoundButton(
                    icon: Icons.explore,
                    tooltip: 'Reset north',
                    onTap: () => _map.rotate(0),
                  ),
                ]),
              ]),
            ]),
          ),
        ),
        Positioned(
          right: 4,
          bottom: 2,
          child: Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 9, color: Colors.black.withValues(alpha: 0.6))),
        ),
      ]),
    );
  }

  /// Colour-grades the whole tile layer once (cheaper than per tile).
  Widget _themed(MapThemeDef theme, Widget tiles) =>
      theme.matrix == null ? tiles : ColorFiltered(colorFilter: ColorFilter.matrix(theme.matrix!), child: tiles);

  void _showNearby(Game g) {
    final list = [...g.spawns]
      ..sort((a, b) => metersBetween(g.location.position, a.point).compareTo(metersBetween(g.location.position, b.point)));
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF12141F),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('Nearby songs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No songs nearby — keep walking!')),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (_, i) {
                final s = list[i];
                final d = metersBetween(g.location.position, s.point).round();
                return CardRow(
                  song: s.song,
                  rarity: s.rarity,
                  shiny: s.shiny,
                  subtitle: '${s.song.artistName} • $d m away',
                  onTap: () {
                    Navigator.pop(ctx);
                    _tapSpawn(g, s);
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.g});
  final Game g;

  @override
  Widget build(BuildContext context) {
    final p = g.profile;
    final lvl = p.level;
    final from = PlayerProfile.xpForLevel(lvl), to = PlayerProfile.xpForLevel(lvl + 1);
    final frac = ((p.xp - from) / (to - from)).clamp(0.0, 1.0);
    return Row(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(22)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: Color(p.figureColor),
            child: Text('$lvl', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            ),
            const SizedBox(height: 3),
            SizedBox(
              width: 90,
              height: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(value: frac, backgroundColor: Colors.white12, color: Color(p.figureColor)),
              ),
            ),
          ]),
        ]),
      ),
      const Spacer(),
      CurrencyChip(icon: kCoinIcon, value: p.coins, color: kCoinColor),
      const SizedBox(width: 6),
      CurrencyChip(icon: kBitsIcon, value: p.bits, color: kBitsColor, onTap: () => HomeShell.goTo(context, 3)),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16)),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, required this.tooltip, this.badge});
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final int? badge;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.black.withValues(alpha: 0.7),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(alignment: Alignment.center, children: [
                  Icon(icon, color: Colors.white),
                  if (badge != null && badge! > 0)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(color: Colors.pinkAccent, borderRadius: BorderRadius.circular(8)),
                        child: Text('$badge', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      );
}
