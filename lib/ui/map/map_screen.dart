import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:tunetrail_core/tunetrail_core.dart' show Edition;

import '../../build_flags.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/profile.dart';
import '../../game/game.dart';
import '../../game/genre_zones.dart';
import '../../game/spawns.dart';
import '../../map3d/palette.dart';
import '../../map3d/props3d.dart';
import '../../map3d/particles3d.dart';
import '../../map3d/camera.dart';
import '../../platform/pointer_lock.dart';
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
  double _lastBearing = 0, _lastDistance = 0, _lastPitch = 0;
  double _scaleStartDistance = 230;
  double? _joyX, _joyY;

  // Guided view ("Nearby" → show me the way).
  late final AnimationController _guide = AnimationController(vsync: this);
  double _gFromBearing = 0, _gToBearing = 0, _gFromDist = 230, _gOverDist = 600, _gFromPitch = Camera3D.basePitch;
  bool _gOverhead = false;
  List<(double, double, double, bool)> _prints = const [];
  String? _trailTarget;
  final ValueNotifier<double> _trailReveal = ValueNotifier(0);

  /// 0 → 1 while the trail vanishes print by print, start to end.
  late final AnimationController _trailVanish = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
    ..addListener(() => _groundDirty.value++)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _prints = const [];
        _trailVanish.value = 0;
      }
    });

  void _dismissTrail() {
    _trailTarget = null;
    if (_prints.isNotEmpty && !_trailVanish.isAnimating) _trailVanish.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _guide.addListener(_applyGuide);
    // Global handler: works no matter which widget has focus (desktop WASD).
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  Duration _lastFrame = Duration.zero;

  void _onTick(Duration d) {
    // Battery Saver: at most 60 map frames a second (high-refresh screens
    // would otherwise draw 90–144).
    if (mounted && GameScope.read(context).profile.batterySaver && d - _lastFrame < const Duration(microseconds: 16000)) return;
    _lastFrame = d;
    _pollMouseLook();
    _clock.value = d.inMicroseconds / 1e6;
    if (!mounted) return;
    final g = GameScope.read(context);
    // Turning the camera keeps a new idle from starting; walking ends one.
    final cameraBusy = DateTime.now().difference(_lastCameraInput) < const Duration(milliseconds: 1500) || _guide.isAnimating;
    _idle.update(_clock.value - _lastT, g.location.moving, busy: cameraBusy);
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
    if (g.location.moving) _targetFacing = g.location.heading;
    final df = ((_targetFacing - _facing + 540) % 360) - 180;
    _facing = (_facing + df * 0.2 + 360) % 360;
    if (g.mapData.version != _mapVersion || _cam.bearing != _lastBearing || _cam.distance != _lastDistance || _cam.pitch != _lastPitch) changed = true;
    _mapVersion = g.mapData.version;
    _lastBearing = _cam.bearing;
    _lastDistance = _cam.distance;
    _lastPitch = _cam.pitch;
    if (_guide.isAnimating) changed = true;
    if (_keyboardDriving && g.location.joystickMode) _applyKeys(g);
    // The footstep trail starts fading as soon as the camera has swung
    // back down behind the player.
    if (_prints.isNotEmpty && _trailTarget != null && !_guide.isAnimating) _dismissTrail();
    if (changed) _groundDirty.value++;
  }

  /// Drag-to-turn. A rightward swipe always turns the view the same way
  /// (the map rotates counter-clockwise), wherever on screen it happens.
  /// Vertical swipes also turn it: down on the right side of the player or
  /// up on the left side matches a rightward swipe.
  /// Pokémon GO-style turning: the camera follows the angle the finger
  /// sweeps around the character. Below the character a rightward swipe
  /// turns counter-clockwise, above it clockwise; to its right an upward
  /// swipe turns counter-clockwise, to its left clockwise — and everything
  /// in between blends continuously (it's one angular formula).
  void _rotateBy(Offset focal, Offset delta) {
    _cam.update();
    final pivot = Offset(_cam.cx, _cam.cy - 40); // the character's middle
    final r = focal - pivot;
    // Close to the character the angle is ill-defined; damp it.
    final r2 = math.max(r.distanceSquared, 90.0 * 90.0);
    final cross = r.dx * delta.dy - r.dy * delta.dx;
    _cam.bearing = (_cam.bearing - cross / r2 * 180 / math.pi * 1.15) % 360;
    _cameraTouched();
  }

  DateTime _lastCameraInput = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------------------------------------------------------- mouse look
  /// Desktop: Alt toggles a captured, hidden cursor; moving the mouse turns
  /// the camera like a PC game (no click-and-drag needed).
  bool _mouseLook = false;
  static bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  void _setMouseLook(bool on) {
    if (on == _mouseLook) return;
    setState(() => _mouseLook = on);
    _lookCenter = null;
    if (on) _initLookCenter();
  }

  /// Screen-pixel centre the cursor is held at while mouse-look is on.
  (int, int)? _lookCenter;
  Offset _lastHover = Offset.zero;

  void _initLookCenter() {
    final ctl = CursorControl.instance;
    final pos = ctl?.position();
    final box = context.findRenderObject() as RenderBox?;
    if (ctl == null || pos == null || box == null || !mounted) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final center = box.size.center(Offset.zero);
    // OS position of the widget centre, from where the pointer is now.
    final c = ((pos.$1 + (center.dx - _lastHover.dx) * dpr).round(), (pos.$2 + (center.dy - _lastHover.dy) * dpr).round());
    ctl.warp(c.$1, c.$2);
    _lookCenter = c;
  }

  /// Polled once per frame: how far the OS cursor moved from the held
  /// centre turns the camera, then it is put back. Using the OS position
  /// (not Flutter's hover deltas, which include the warp's own jump and
  /// arrive late) keeps turning smooth.
  void _pollMouseLook() {
    final c = _lookCenter;
    final ctl = CursorControl.instance;
    if (!_mouseLook || c == null || ctl == null) return;
    final p = ctl.position();
    if (p == null) return;
    final dx = (p.$1 - c.$1).toDouble(), dy = (p.$2 - c.$2).toDouble();
    if (dx == 0 && dy == 0) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    _cam.bearing = (_cam.bearing + dx / dpr * 0.22) % 360;
    // Mouse up tilts the view up (towards the horizon), down tilts it down.
    _cam.pitch = (_cam.pitch + dy / dpr * 0.08).clamp(28.0, 58.0);
    _cameraTouched();
    ctl.warp(c.$1, c.$2);
  }

  void _onHover(PointerHoverEvent e) {
    _lastHover = e.localPosition;
  }

  void _cameraTouched() => _lastCameraInput = DateTime.now();

  @override
  void dispose() {
    _ticker.dispose();
    _guide.dispose();
    _trailVanish.dispose();
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
    _trailVanish.value = 0;
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
      if (_mouseLook) _setMouseLook(false);
      return false;
    }
    if (_isDesktop && e is KeyDownEvent) {
      if (e.logicalKey == LogicalKeyboardKey.altLeft || e.logicalKey == LogicalKeyboardKey.altRight) {
        _setMouseLook(!_mouseLook);
        return true;
      }
      if (e.logicalKey == LogicalKeyboardKey.escape && _mouseLook) {
        _setMouseLook(false);
        return true;
      }
    }
    final g = GameScope.read(context);
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      if (e.logicalKey == LogicalKeyboardKey.keyQ) {
        _cam.bearing = (_cam.bearing - 8) % 360;
        _cameraTouched();
      }
      if (e.logicalKey == LogicalKeyboardKey.keyE) {
        _cam.bearing = (_cam.bearing + 8) % 360;
        _cameraTouched();
      }
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
    if (!g.inRange(s) && !g.isPurchased(s)) {
      final d = metersBetween(g.location.position, s.point).round();
      if (g.spawnPrice(s) == null) {
        g.toast('Too far — get within ${Game.catchRangeMeters.round()} m ($d m away)');
      } else {
        await _offerPurchase(g, s);
      }
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

    return MouseRegion(
      cursor: _mouseLook ? SystemMouseCursors.none : MouseCursor.defer,
      onHover: _onHover,
      child: Listener(
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
                  builder: (context, t, _) => CustomPaint(
                    painter: SkyPainter(camera: _cam, palette: theme.palette, decor: theme.sky, time: t),
                  ),
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
                    // The footstep trail lies on the ground, under buildings.
                    footsteps: () => _prints.isEmpty
                        ? null
                        : FootstepsPainter(camera: _cam, prints: _prints, reveal: _trailReveal.value, vanish: _trailVanish.value, opacity: 1, color: theme.accent),
                  ),
                ),
              ),
              // Low-poly 3D props standing on the ground (theme-specific).
              if (theme.props != PropSet.none)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<int>(
                      valueListenable: _groundDirty,
                      builder: (context, _, _) => CustomPaint(
                        painter: PropsPainter(camera: _cam, set: theme.props, fog: theme.palette.skyBottom),
                      ),
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
                      painter: Figure3DPainter(camera: _cam, look: look, time: t, idle: _idle, facing: _facing, accent: theme.accent, contrast: contrastColor(theme.palette)),
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
                    builder: (context, t, _) => CustomPaint(
                      // Snow, dust, embers and petals live in 3D around the
                      // player; the other effects are screen overlays.
                      painter: switch (p.reduceEffects ? null : _particleKind(theme.effect)) {
                        final k? => Particles3DPainter(camera: _cam, time: t, kind: k, vignette: theme.vignette),
                        null => MapEffectPainter(theme, t, reduce: p.reduceEffects),
                      },
                    ),
                  ),
                ),
              ),
              if (_mouseLook)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 96,
                  child: IgnorePointer(
                    child: Center(
                      child: Glass(
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        child: Text('Mouse look · move the mouse to turn · Alt or Esc to release', style: TextStyle(fontSize: 12)),
                      ),
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
      ),
    );
  }

  /// Out of range: buy the song with coins instead of walking there.
  Future<void> _offerPurchase(Game g, Spawn s) async {
    if (g.isPurchased(s)) return _tapSpawn(g, s);
    final price = g.spawnPrice(s);
    if (price == null) return;
    final d = metersBetween(g.location.position, s.point).round();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.song.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Text('${s.song.artistName} · ${s.rarity.label}\n\n$d m away — walk within ${Game.catchRangeMeters.round()} m to catch it, '
            'or buy it now for ${formatNumber(price)} coins.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Walk there')),
          FilledButton(onPressed: g.profile.coins < price ? null : () => Navigator.pop(ctx, true), child: Text('Buy · ${formatNumber(price)} coins')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      g.buySpawn(s);
    } catch (e) {
      g.toast('$e');
      return;
    }
    // Paid: now catch it (it can't get away).
    if (mounted) await _tapSpawn(g, s);
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
                  final price = g.spawnPrice(s);
                  final icon = Icon(
                    metersBetween(g.location.position, s.point) <= Game.catchRangeMeters ? Icons.center_focus_strong_outlined : Icons.near_me_outlined,
                    size: 18,
                    color: kTextTertiary,
                  );
                  // Shiny and edition spawns stay a mystery until you're there.
                  if (s.shiny || s.edition != Edition.standard) {
                    return ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(8), border: Border.all(color: kOutline)),
                        alignment: Alignment.center,
                        child: const Text('?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: kTextSecondary)),
                      ),
                      title: const Text('???', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('Something special · $d m', style: const TextStyle(fontSize: 12, color: kTextTertiary)),
                      trailing: icon,
                      onTap: () {
                        Navigator.pop(ctx);
                        _guideTo(g, s);
                      },
                    );
                  }
                  return CardRow(
                    song: s.song,
                    rarity: s.rarity,
                    shiny: s.shiny,
                    subtitle: '${s.song.artistName}${songGenreName(s.song).isEmpty ? '' : ' · ${songGenreName(s.song)}'} · $d m',
                    trailing: price == null
                        ? icon
                        : TextButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _offerPurchase(g, s);
                            },
                            child: Text('Buy · ${formatNumber(price)}'),
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

  static Particle3DKind? _particleKind(MapEffect e) => switch (e) {
        MapEffect.snow => Particle3DKind.snow,
        MapEffect.dust => Particle3DKind.dust,
        MapEffect.embers => Particle3DKind.embers,
        MapEffect.petals => Particle3DKind.petals,
        MapEffect.sweets => Particle3DKind.sweets,
        _ => null,
      };
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
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => _build(box.biggest));

  // Must use the same viewport size as the ground painter (the map area,
  // not the whole window) or markers drift against the ground as you move.
  Widget _build(Size size) {
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
                                zone.first.$1.genres.where((id) => id != 0).map(genreName).take(2).join(' · '),
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
                    if (kAdminBuild && p.debugEnabled)
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
                        Text(z.genres.where((id) => id != 0).map(genreName).join(', '), style: const TextStyle(fontSize: 12, color: Colors.white70)),
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
