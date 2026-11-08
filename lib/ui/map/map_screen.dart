import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/profile.dart';
import '../../game/game.dart';
import '../../game/genre_zones.dart';
import '../../game/spawns.dart';
import '../../map3d/camera.dart';
import '../../map3d/figure3d.dart';
import '../../map3d/footsteps_painter.dart';
import '../../map3d/router.dart';
import '../../map3d/sky_painter.dart';
import '../../map3d/ground_painter.dart';
import '../app.dart';
import '../screens/debug_screen.dart';
import '../screens/encounter_screen.dart';
import '../screens/quests_screen.dart';
import '../widgets/cards.dart';
import '../widgets/joystick.dart';
import '../widgets/stick_figure.dart';
import 'map_themes.dart';
import 'spawn_marker.dart';

/// The 3D world: the stylised map is the ground plane, the player's stick
/// figure walks on it at the centre, songs float above it.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final Camera3D _cam = Camera3D();
  final ValueNotifier<double> _clock = ValueNotifier(0);

  /// Fires when the ground needs re-projecting (camera/player/tiles moved).
  final ValueNotifier<int> _groundDirty = ValueNotifier(0);
  late final Ticker _ticker;
  final Set<LogicalKeyboardKey> _keys = {};
  bool _keyboardDriving = false;

  double _facing = 0, _targetFacing = 0;
  final IdleDirector _idle = IdleDirector();
  double _lastT = 0;
  double _wx = double.nan, _wy = double.nan;
  int _mapVersion = -1;
  double _lastBearing = 0, _lastDistance = 0;
  double _scaleStartDistance = 230;
  double? _joyX, _joyY;

  // Guided view ("Nearby" → show me the way).
  late final AnimationController _guide = AnimationController(vsync: this);
  double _gFromBearing = 0, _gToBearing = 0, _gFromDist = 230, _gOverDist = 600, _gFromPitch = Camera3D.basePitch;
  bool _gOverhead = false;
  List<(double, double, double, bool)> _prints = const [];
  String? _trailTarget;
  DateTime _trailUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<double> _trailReveal = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _guide.addListener(_applyGuide);
    // Global handler: works no matter which widget has focus (desktop WASD).
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _onTick(Duration d) {
    _clock.value = d.inMicroseconds / 1e6;
    if (!mounted) return;
    final g = GameScope.read(context);
    _idle.update(_clock.value - _lastT, g.location.moving);
    _lastT = _clock.value;
    final (tx, ty) = g.mapData.toWorld(g.location.position.latitude, g.location.position.longitude);
    var changed = false;
    if (_wx.isNaN || (tx - _wx).abs() > 400 || (ty - _wy).abs() > 400) {
      _wx = tx;
      _wy = ty;
      changed = true;
    } else {
      // Smoothly follow GPS/joystick updates.
      final nx = _wx + (tx - _wx) * 0.25, ny = _wy + (ty - _wy) * 0.25;
      if ((nx - _wx).abs() > 0.01 || (ny - _wy).abs() > 0.01) changed = true;
      _wx = nx;
      _wy = ny;
    }
    _cam.px = _wx;
    _cam.py = _wy;
    if (g.location.moving) {
      _targetFacing = g.location.heading;
    } else if (_idle.activity != IdleActivity.none && _idle.blend > 0) {
      // Turn to a three-quarter view towards the camera for idle activities.
      _targetFacing = (_cam.bearing + 180 + 28) % 360;
    }
    final df = ((_targetFacing - _facing + 540) % 360) - 180;
    _facing = (_facing + df * 0.2 + 360) % 360;
    if (g.mapData.version != _mapVersion || _cam.bearing != _lastBearing || _cam.distance != _lastDistance) changed = true;
    _mapVersion = g.mapData.version;
    _lastBearing = _cam.bearing;
    _lastDistance = _cam.distance;
    if (_guide.isAnimating) changed = true;
    if (_keyboardDriving && g.location.joystickMode) _applyKeys(g);
    // Clear the footstep trail once the player reaches the song or it expires.
    if (_prints.isNotEmpty) {
      final target = g.spawns.where((s) => s.id == _trailTarget).firstOrNull;
      if (target == null || metersBetween(g.location.position, target.point) <= Game.catchRangeMeters || DateTime.now().isAfter(_trailUntil)) {
        _prints = const [];
        _trailTarget = null;
      }
    }
    if (changed) _groundDirty.value++;
  }

  /// Rotates the view by how far the finger travels *around* the player, so
  /// horizontal and vertical swipes both turn it. The map follows the
  /// finger: swiping right (above the player) turns the view
  /// counter-clockwise.
  void _rotateBy(Offset focal, Offset delta) {
    _cam.update();
    final c = Offset(_cam.cx, _cam.cy);
    final cur = focal - c, prev = focal - delta - c;
    if (cur.distance < 48 || prev.distance < 48) {
      _cam.bearing = (_cam.bearing - delta.dx * 0.35) % 360;
      return;
    }
    var d = math.atan2(cur.dy, cur.dx) - math.atan2(prev.dy, prev.dx);
    if (d > math.pi) d -= 2 * math.pi;
    if (d < -math.pi) d += 2 * math.pi;
    _cam.bearing = (_cam.bearing - d * 180 / math.pi) % 360;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _guide.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  static double _lerpAngle(double a, double b, double t) {
    final d = ((b - a + 540) % 360) - 180;
    return (a + d * t + 360) % 360;
  }

  /// Applies the guide animation to the camera.
  void _applyGuide() {
    final t = _guide.value;
    if (!_gOverhead) {
      final e = Curves.easeInOutCubic.transform(t);
      _cam.bearing = _lerpAngle(_gFromBearing, _gToBearing, e);
      return;
    }
    // Timeline (0..1): zoom out 0–0.25, hold + trail 0.25–0.68, back 0.68–1.
    if (t < 0.25) {
      final e = Curves.easeInOutCubic.transform(t / 0.25);
      _cam.pitch = _gFromPitch + (76 - _gFromPitch) * e;
      _cam.distance = _gFromDist + (_gOverDist - _gFromDist) * e;
      _trailReveal.value = 0;
    } else if (t < 0.68) {
      _cam.pitch = 76;
      _cam.distance = _gOverDist;
      _trailReveal.value = ((t - 0.27) / 0.33).clamp(0.0, 1.0);
    } else {
      final e = Curves.easeInOutCubic.transform((t - 0.68) / 0.32);
      _cam.pitch = 76 + (Camera3D.basePitch - 76) * e;
      _cam.distance = _gOverDist + (230 - _gOverDist) * e;
      _cam.bearing = _lerpAngle(_gFromBearing, _gToBearing, e);
      _trailReveal.value = 1;
    }
  }

  /// Nearby → tap a song: face it if it's in range, otherwise zoom out,
  /// draw footsteps along the roads to it and zoom back in facing it.
  void _guideTo(Game g, Spawn s) {
    final (x, y) = g.mapData.toWorld(s.point.latitude, s.point.longitude);
    _cam.update();
    _gFromBearing = _cam.bearing;
    _gToBearing = _cam.bearingTo(x, y);
    _gFromDist = _cam.distance;
    _gFromPitch = _cam.pitch;
    _guide.stop();
    // Use real distance here (not the debug unlimited-range switch).
    if (metersBetween(g.location.position, s.point) <= Game.catchRangeMeters) {
      _gOverhead = false;
      _guide.duration = const Duration(milliseconds: 700);
      _guide.forward(from: 0);
      return;
    }
    final dist = math.sqrt((x - _cam.px) * (x - _cam.px) + (y - _cam.py) * (y - _cam.py));
    _gOverDist = (dist * 2.4).clamp(380.0, 1100.0);
    final route = RoadRouter(g.mapData).route(_cam.px, _cam.py, x, y);
    _prints = footprintsAlong(route);
    _trailTarget = s.id;
    _trailUntil = DateTime.now().add(const Duration(minutes: 3));
    _trailReveal.value = 0;
    _gOverhead = true;
    _guide.duration = const Duration(milliseconds: 4200);
    _guide.forward(from: 0);
  }

  void _setJoystick(Game g, double x, double y) {
    _joyX = x;
    _joyY = y;
    _cam.update();
    final (e, n) = _cam.screenToWorldDir(x, y);
    g.location.setJoystick(e, n);
  }

  /// Keys only drive the map while it's the visible tab, nothing is pushed
  /// on top of it, and no text field is being typed in.
  bool get _mapHasKeyboard {
    if (!mounted || HomeShell.currentTab.value != 0) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    return focused is! EditableText;
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) _keys.add(e.logicalKey);
    if (e is KeyUpEvent) _keys.remove(e.logicalKey);
    if (!_mapHasKeyboard) {
      if (_keyboardDriving) _releaseKeys();
      return false;
    }
    final g = GameScope.read(context);
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      if (e.logicalKey == LogicalKeyboardKey.keyQ) _cam.bearing = (_cam.bearing - 8) % 360;
      if (e.logicalKey == LogicalKeyboardKey.keyE) _cam.bearing = (_cam.bearing + 8) % 360;
    }
    if (!g.location.joystickMode) return false;
    _applyKeys(g);
    final movement = {
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    };
    return movement.contains(e.logicalKey);
  }

  (double, double) get _keyVector {
    double x = 0, y = 0;
    if (_keys.contains(LogicalKeyboardKey.keyW) || _keys.contains(LogicalKeyboardKey.arrowUp)) y += 1;
    if (_keys.contains(LogicalKeyboardKey.keyS) || _keys.contains(LogicalKeyboardKey.arrowDown)) y -= 1;
    if (_keys.contains(LogicalKeyboardKey.keyD) || _keys.contains(LogicalKeyboardKey.arrowRight)) x += 1;
    if (_keys.contains(LogicalKeyboardKey.keyA) || _keys.contains(LogicalKeyboardKey.arrowLeft)) x -= 1;
    return (x, y);
  }

  void _applyKeys(Game g) {
    final (x, y) = _keyVector;
    if (x == 0 && y == 0) {
      if (_keyboardDriving) _releaseKeys();
      return;
    }
    _keyboardDriving = true;
    final len = math.sqrt(x * x + y * y);
    _setJoystick(g, x / len, y / len);
  }

  void _releaseKeys() {
    _keyboardDriving = false;
    _joyX = _joyY = null;
    if (mounted) GameScope.read(context).location.setJoystick(0, 0);
  }

  Future<void> _tapSpawn(Game g, Spawn s) async {
    if (!g.inRange(s)) {
      final d = metersBetween(g.location.position, s.point).round();
      g.toast('Too far — get within ${Game.catchRangeMeters.round()} m ($d m away)');
      return;
    }
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: EncounterScreen(spawn: s),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = GameScope.of(context);
    final p = g.profile;
    final theme = themeById(p.activeTheme);
    final look = FigureLook(color: Color(p.figureColor), hat: p.hat, shirt: p.shirt, pet: p.pet, backpack: p.backpack);

    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          _cam.distance = (_cam.distance * (1 + e.scrollDelta.dy / 600)).clamp(120.0, 460.0);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) {
          _guide.stop();
          _cam.pitch = Camera3D.basePitch;
          _scaleStartDistance = _cam.distance.clamp(120.0, 460.0);
        },
        onScaleUpdate: (d) {
          if (d.pointerCount >= 2) {
            _cam.distance = (_scaleStartDistance / d.scale).clamp(120.0, 460.0);
          } else {
            _rotateBy(d.localFocalPoint, d.focalPointDelta);
          }
          if (_joyX != null) _setJoystick(g, _joyX!, _joyY!);
        },
        onDoubleTap: () => _cam.distance = 230,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Sky (world-anchored sun/stars/aurora) behind the ground.
            RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: _clock,
                builder: (context, t, _) => CustomPaint(painter: SkyPainter(camera: _cam, palette: theme.palette, decor: theme.sky, time: t)),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(
                painter: GroundPainter(
                  camera: _cam,
                  map: g.mapData,
                  palette: theme.palette,
                  catchRadius: Game.catchRangeMeters,
                  repaint: _groundDirty,
                ),
              ),
            ),
            // Footstep trail on the ground.
            IgnorePointer(
              child: ValueListenableBuilder<int>(
                valueListenable: _groundDirty,
                builder: (context, _, _) => CustomPaint(
                  painter: FootstepsPainter(camera: _cam, prints: _prints, reveal: _trailReveal.value, opacity: 1, color: theme.accent),
                ),
              ),
            ),
            // Songs behind the player, then the player, then songs in front.
            ValueListenableBuilder<double>(
              valueListenable: _clock,
              builder: (context, t, _) => _SpawnLayer(cam: _cam, game: g, clock: _clock, front: false, onTap: (s) => _tapSpawn(g, s)),
            ),
            IgnorePointer(
              child: RepaintBoundary(
                child: ValueListenableBuilder<double>(
                  valueListenable: _clock,
                  builder: (context, t, _) => CustomPaint(
                    painter: Figure3DPainter(camera: _cam, look: look, time: t, idle: _idle, facing: _facing, accent: theme.accent),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: _clock,
              builder: (context, t, _) => _SpawnLayer(cam: _cam, game: g, clock: _clock, front: true, onTap: (s) => _tapSpawn(g, s)),
            ),
            IgnorePointer(
              child: RepaintBoundary(
                child: ValueListenableBuilder<double>(
                  valueListenable: _clock,
                  builder: (context, t, _) => CustomPaint(painter: MapEffectPainter(theme, t, reduce: p.reduceEffects)),
                ),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _groundDirty,
              builder: (context, _, _) => _Hud(
                g: g,
                cam: _cam,
                onJoystick: (x, y) => _setJoystick(g, x, y),
                onJoystickEnd: () {
                  _joyX = _joyY = null;
                  g.location.setJoystick(0, 0);
                },
                onNearby: () => _showNearby(g),
                onCompass: () => _cam.bearing = 0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNearby(Game g) {
    final list = [...g.spawns]..sort((a, b) => metersBetween(g.location.position, a.point).compareTo(metersBetween(g.location.position, b.point)));
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Nearby', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Tap a song to face it, or to see the way there.', style: TextStyle(fontSize: 12, color: kTextTertiary)),
              ),
            ),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No songs nearby — keep walking.')),
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
                    subtitle: '${s.song.artistName} · ${genreName(s.song.genreId)} · $d m',
                    trailing: Icon(
                      metersBetween(g.location.position, s.point) <= Game.catchRangeMeters
                          ? Icons.center_focus_strong_outlined
                          : Icons.near_me_outlined,
                      size: 18,
                      color: kTextTertiary,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _guideTo(g, s);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Billboarded spawns, projected through the 3D camera each frame.
class _SpawnLayer extends StatelessWidget {
  const _SpawnLayer({required this.cam, required this.game, required this.clock, required this.front, required this.onTap});
  final Camera3D cam;
  final Game game;
  final ValueNotifier<double> clock;
  final bool front;
  final void Function(Spawn) onTap;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    cam
      ..size = size
      ..update();
    final items = <(double, Widget)>[];
    for (final s in game.spawns) {
      final (x, y) = game.mapData.toWorld(s.point.latitude, s.point.longitude);
      final ya = cam.alignY(x, y);
      if ((ya < 0) != front) continue;
      if (ya < cam.yNear || ya > cam.yFar * 0.75) continue;
      final ground = cam.project(x, y);
      if (ground == null) continue;
      final scale = (cam.scaleAt(x, y) / cam.scaleAt(cam.px, cam.py) * 0.8).clamp(0.5, 1.15);
      if (ground.dx < -80 || ground.dx > size.width + 80 || ground.dy < -80 || ground.dy > size.height + 120) continue;
      const box = 96.0;
      items.add((
        cam.depth(ya, 0),
        Positioned(
          key: ValueKey(s.id),
          left: ground.dx - box / 2,
          top: ground.dy - box,
          width: box,
          height: box,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.bottomCenter,
            child: SpawnMarker(spawn: s, clock: clock, inRange: game.inRange(s), onTap: () => onTap(s)),
          ),
        ),
      ));
    }
    items.sort((a, b) => b.$1.compareTo(a.$1));
    return Stack(clipBehavior: Clip.none, children: [for (final i in items) i.$2]);
  }
}

class _Hud extends StatelessWidget {
  const _Hud({
    required this.g,
    required this.cam,
    required this.onJoystick,
    required this.onJoystickEnd,
    required this.onNearby,
    required this.onCompass,
  });
  final Game g;
  final Camera3D cam;
  final void Function(double, double) onJoystick;
  final VoidCallback onJoystickEnd;
  final VoidCallback onNearby;
  final VoidCallback onCompass;

  @override
  Widget build(BuildContext context) {
    final p = g.profile;
    final lvl = p.level;
    final from = PlayerProfile.xpForLevel(lvl), to = PlayerProfile.xpForLevel(lvl + 1);
    final frac = ((p.xp - from) / (to - from)).clamp(0.0, 1.0);
    final zone = g.zoneHere.active;
    final status = g.catalog.size == 0
        ? (g.catalog.crawling ? 'Loading songs…' : 'Offline — connect to find songs')
        : (g.mapData.tiles.isEmpty && g.mapData.isLoading)
        ? 'Loading map…'
        : (g.location.gpsError != null && !g.location.joystickMode)
        ? '${g.location.gpsError}'
        : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Glass(
                  padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(value: frac, strokeWidth: 2, color: kAccent, backgroundColor: Colors.white10),
                            Text('$lvl', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                CurrencyChip(icon: kCoinIcon, value: p.coins, color: kCoinColor),
                const SizedBox(width: 6),
                CurrencyChip(icon: kBitsIcon, value: p.bits, color: kBitsColor, onTap: () => HomeShell.goTo(context, 3)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                GestureDetector(
                  onTap: () => showZonesSheet(context, g.zoneHere),
                  child: Glass(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: zone.isEmpty
                        ? const Text('No genre zone here', style: TextStyle(fontSize: 12, color: Colors.white54))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(zone.first.$1.icon, size: 15, color: kAccent),
                              const SizedBox(width: 6),
                              Text(zone.first.$1.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 6),
                              Text(
                                zone.first.$1.genres.map(genreName).take(2).join(' · '),
                                style: const TextStyle(fontSize: 12, color: Colors.white54),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: Glass(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Text(status, style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (g.location.joystickMode)
                  Joystick(onChanged: (x, y) => (x == 0 && y == 0) ? onJoystickEnd() : onJoystick(x, y))
                else
                  const SizedBox(),
                const Spacer(),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p.debugEnabled)
                      HudButton(
                        icon: Icons.travel_explore,
                        tooltip: 'Teleport',
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TeleportScreen())),
                      ),
                    HudButton(
                      icon: Icons.checklist_rounded,
                      tooltip: 'Quests',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuestsScreen())),
                    ),
                    HudButton(icon: Icons.radar, tooltip: 'Nearby', badge: g.spawns.length, onTap: onNearby),
                    HudButton(
                      tooltip: 'Reset view',
                      onTap: onCompass,
                      child: Transform.rotate(angle: -cam.bearing * math.pi / 180, child: const Icon(Icons.navigation_rounded, size: 20)),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Explains genre strength areas and shows what's boosted here.
void showZonesSheet(BuildContext context, ZoneReading here) {
  final active = {for (final (z, s) in here.active) z.id: s};
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          const SheetHandle(),
          const Text('Genre zones', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text(
            'Songs spawn more often in places that fit their sound. Zone boosts stack with time of day.',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 16),
          for (final z in kZones)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: active.containsKey(z.id) ? kAccent.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(z.icon, size: 18, color: active.containsKey(z.id) ? kAccent : Colors.white54),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(z.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            if (active.containsKey(z.id))
                              Text(
                                'here ×${(1 + ZoneReading.strength * active[z.id]!).toStringAsFixed(1)}',
                                style: const TextStyle(fontSize: 11, color: kAccent),
                              ),
                          ],
                        ),
                        Text(z.genres.map(genreName).join(', '), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                        Text(z.description, style: const TextStyle(fontSize: 12, color: Colors.white38)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
